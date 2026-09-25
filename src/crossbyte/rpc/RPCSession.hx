package crossbyte.rpc;

// Not built for any JavaScript target (Node included, which has no threads): a session is bound to a NetConnection, which spans transports a page does not have.

import crossbyte.net.Reason;
import crossbyte.utils.Logger;
import crossbyte.core.CrossByte;
import crossbyte.utils.Bucket;
import crossbyte.utils.Hash;
import crossbyte.sys.System;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCCommands;
import crossbyte.net.NetConnection;
import crossbyte.events.EventDispatcher;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.rpc._internal.RPCRuntimeCodec;
import haxe.ds.IntMap;
#if neko
import sys.thread.Mutex;
#elseif (cpp || hl || java || cs)
import haxe.atomic.AtomicInt;
#end

@:access(crossbyte.rpc.RPCHandler)
@:access(crossbyte.rpc.RPCCommands)
/**
 * Binds an `RPCCommands` client surface and an optional `RPCHandler` to a live connection.
 *
 * `RPCSession` owns the wire-level framing hookup for request/response traffic,
 * forwards inbound calls to a handler, routes responses back to pending client
 * calls, and optionally maintains a heartbeat using the built-in `ping` path.
 */
class RPCSession<C:RPCCommands = Dynamic, D = Dynamic> extends EventDispatcher {
	/** Default interval between heartbeat pings in milliseconds. */
	public static inline final DEFAULT_HEARTBEAT_INTERVAL:Int = 45000;
	/** Default timeout window before a peer is considered dead, in milliseconds. */
	public static inline final DEFAULT_HEARTBEAT_TIMEOUT:Int = 90000;
	/** Default jitter bucket used to spread heartbeat start phases, in milliseconds. */
	public static inline final DEFAULT_HEARTBEAT_JITTER:Int = 5000;
	@:noCompletion private static final HEARTBEAT_SALT:Int = __getSalt();

	/** Process-local session identifier. */
	public final sessionId:Int = __getSessionId();
	/** Underlying transport connection used by this session. */
	public var connection(get, never):NetConnection;
	/** Optional server-side handler for inbound RPC calls. */
	public var handler(get, set):RPCHandler;
	/** Optional client-side command surface for outbound RPC calls and responses. */
	public var commands(get, set):C;
	/** Heartbeat interval in milliseconds. */
	public var heartbeatInterval(get, set):Int;
	/** Heartbeat timeout in milliseconds. */
	public var heartbeatTimeout(get, set):Int;
	/** Arbitrary user data attached to the session. */
	public var data:D;

	@:noCompletion private var __connection:NetConnection;
	@:noCompletion private var __handler:RPCHandler;
	@:noCompletion private var __commands:C;
	@:noCompletion private var __heartbeatTimerHandle:Int = 0;
	@:noCompletion private var __heartbeatInterval:Int = DEFAULT_HEARTBEAT_INTERVAL;
	@:noCompletion private var __heartbeatTimeout:Int = DEFAULT_HEARTBEAT_TIMEOUT;
	@:noCompletion private var __heartbeatPhase:Int;
	@:noCompletion private var __active:Bool = false;
	@:noCompletion private var __hasHeartbeat:Bool = false;
	@:noCompletion private var __timeoutSec:Float = 0.0;
	@:noCompletion private var __intervalSec:Float = 0.0;
	@:noCompletion private var __runtimeHandlers:Null<IntMap<Array<Dynamic>->Dynamic>> = null;
	@:noCompletion private var __runtimeRequestIdSeed:Int = 0;
	@:noCompletion private var __runtimePendingResponseId:Int = 0;
	@:noCompletion private var __runtimePendingResponse:RPCResponse<Dynamic> = null;
	@:noCompletion private var __runtimePendingResponses:Null<IntMap<RPCResponse<Dynamic>>> = null;

	#if neko
	@:noCompletion private static var __sidCounter:Int = 0;
	@:noCompletion private static var __sidLock:Null<Mutex> = new Mutex();
	#elseif (cpp || hl || java || cs)
	@:noCompletion private static var __sidCounter:AtomicInt = new AtomicInt(0);
	#else
	@:noCompletion private static var __sidCounter:Int = 0;
	#end

	@:noCompletion private static inline function __getSalt():Int {
		// TODO: load from persistant file if exists
		var id:String = System.getDeviceId();

		if (id != null) {
			id = StringTools.trim(id);
		}

		if (id == null || id.length == 0) {
			id = "crossbyte-rpc";
		}

		return Hash.fnv1a32String(id.toLowerCase());
	}

	@:noCompletion private static inline function __getSessionId():Int {
		#if (neko)
		__sidLock.acquire();
		var id:Int = ++__sidCounter;
		__sidLock.release();
		return id;
		#elseif (cpp || hl || java || cs)
		return __sidCounter.add(1);
		#else
		return ++__sidCounter;
		#end
	}

	@:noCompletion private inline function set_heartbeatInterval(value:Int):Int {
		return __heartbeatInterval = value;
	}

	@:noCompletion private inline function get_heartbeatInterval():Int {
		return __heartbeatInterval;
	}

	@:noCompletion private inline function set_heartbeatTimeout(value:Int):Int {
		return __heartbeatTimeout = value;
	}

	@:noCompletion private inline function get_heartbeatTimeout():Int {
		return __heartbeatTimeout;
	}

	@:noCompletion private inline function set_commands(commands:C):C {
		if (__active && !__hasHeartbeat) {
			__resumeHeartbeat();
		}
		var same:Bool = (commands == __commands);

		#if debug
		if (!same && commands != null) {
			var bound = commands.__nc;
			if (bound != null && bound != __connection) {
				throw "Cannot bind RPCCommands: already bound to a different RPCSession.";
			}
		}
		#end

		if (!same) {
			var old = __commands;
			__commands = commands;

			if (old != null && old.__nc == __connection) {
				old.__nc = null;
			}
			if (commands != null) {
				commands.__nc = __connection;
			} else if (__hasHeartbeat) {
				__stopHeartbeat();
			}
			if (__handler != null) {
				__handler.this_commands = commands;
			}
			__syncOnDataBinding();
		}

		return __commands;
	}

	@:noCompletion private inline function set_handler(handler:RPCHandler):RPCHandler {
		if (__handler != null && handler != __handler) {
			__handler.this_connection = null;
			__handler.this_commands = null;
			__handler.this_session = null;
		}
		__handler = handler;
		if (handler != null) {
			handler.this_connection = this.connection;
			handler.this_commands = __commands;
			handler.this_session = cast this;
		}
		__syncOnDataBinding();

		return handler;
	}

	@:noCompletion private inline function get_connection():NetConnection {
		return __connection;
	}

	@:noCompletion private inline function get_handler():RPCHandler {
		return __handler;
	}

	@:noCompletion private inline function get_commands():C {
		return __commands;
	}

	public function new(connection:NetConnection, ?commands:C, ?handler:RPCHandler) {
		super();
		__connection = connection;
		this.commands = commands;
		this.handler = handler;
	}

	/**
	 * Told of whatever a handler threw that its caller will not hear about:
	 * anything but an `RPCError` from a request, whose caller is told only
	 * `RPCError.INTERNAL_MESSAGE`, and anything at all from a one-way call,
	 * which nobody is waiting on. For either lane: `method` is the compiled
	 * handler's method name, or `null` for a runtime handler, which has only
	 * its `op`.
	 *
	 * The connection has stayed up. A handler failing is not the peer sending
	 * something unreadable, and it used to be treated as if it were: the
	 * connection closed and every call still waiting on it failed.
	 *
	 * Logs by default. Replace it to count failures, raise an alert or keep
	 * the stack. Whatever it throws is ignored, so a report failing cannot
	 * close the connection either.
	 */
	/**
	 * Asked before each inbound call on the runtime lane -- to a handler
	 * added with `register`, or to an op with none -- before its arguments are
	 * read: the op, the request's id (0 for a one-way call) and the bytes its
	 * arguments take. Return `null` to let it run, or an `RPCError` to refuse
	 * it: a request is answered with the error's message, and a one-way call
	 * is dropped. A refusal is not reported.
	 *
	 * What `RPCHandler.beforeCall` is for a compiled handler, which overrides
	 * it; a runtime handler has no class to override it in, so it is set
	 * here. Left `null`, as it starts, it costs a runtime call one check.
	 * What it throws counts as the call failing: the caller is answered with
	 * `RPCError.INTERNAL_MESSAGE` and `onHandlerError` is told.
	 */
	public var beforeRuntimeCall:Null<(op:Int, requestId:Int, payloadSize:Int) -> Null<RPCError>> = null;

	/**
	 * Told after each runtime call `beforeRuntimeCall` let through and a
	 * registered handler ran, once its answer, if it has one, has been sent:
	 * `error` is `null` when the handler returned, and what it threw when it
	 * did not. What `RPCHandler.afterCall` is for a compiled handler. What it
	 * throws goes to `onHandlerError` and changes nothing else.
	 */
	public var afterRuntimeCall:Null<(op:Int, requestId:Int, error:Dynamic) -> Void> = null;

	public dynamic function onHandlerError(op:Int, method:Null<String>, error:Dynamic):Void {
		Logger.error('RPC handler ' + (method != null ? method : 'for op $op') + ' threw: ' + Std.string(error));
	}

	/**
	 * Registers a runtime RPC handler for the given operation code.
	 *
	 * Runtime handlers receive decoded arguments as an array of dynamic values. If
	 * the incoming frame expects a response, the return value is encoded and sent
	 * back to the caller. One-way runtime calls ignore the return value.
	 */
	public function register(op:Int, handler:Array<Dynamic>->Dynamic):RPCSession<C, D> {
		if (__runtimeHandlers == null) {
			__runtimeHandlers = new IntMap();
		}
		__runtimeHandlers.set(op, handler);
		__syncOnDataBinding();
		return this;
	}

	/** Removes a previously registered runtime RPC handler. */
	public function deregister(op:Int):Bool {
		if (__runtimeHandlers == null || !__runtimeHandlers.exists(op)) {
			return false;
		}
		__runtimeHandlers.remove(op);
		if (!__hasRuntimeHandlers()) {
			__runtimeHandlers = null;
		}
		__syncOnDataBinding();
		return true;
	}

	/** Sends a one-way runtime RPC call on the dynamic lane. */
	public function call(op:Int, ?args:Array<Dynamic>):Void {
		__sendRuntimeFrame(op, 0, false, args);
	}

	/**
	 * Sends a request/response runtime RPC call on the dynamic lane.
	 *
	 * The response payload is decoded through the runtime codec and resolved into a
	 * normal `RPCResponse<T>`.
	 */
	public function request<T>(op:Int, ?args:Array<Dynamic>):RPCResponse<T> {
		final requestId = __nextRuntimeRequestId();
		final response = new RPCResponse<T>(requestId, op);
		__trackRuntimeResponse(requestId, cast response);
		__sendRuntimeFrame(op, requestId, true, args);
		return response;
	}

	@:noCompletion private function __hasRuntimeHandlers():Bool {
		if (__runtimeHandlers == null) {
			return false;
		}
		for (_ in __runtimeHandlers) {
			return true;
		}
		return false;
	}

	@:noCompletion private function __hasRuntimePendingResponses():Bool {
		return __runtimePendingResponse != null || (__runtimePendingResponses != null && __runtimePendingResponses.iterator().hasNext());
	}

	@:noCompletion private function __usesRuntimeLane():Bool {
		return __hasRuntimeHandlers() || __hasRuntimePendingResponses();
	}

	@:noCompletion private inline function __syncOnDataBinding():Void {
		if (__usesRuntimeLane()) {
			__connection.onData = __safeSessionOnData;
			__connection.readEnabled = (__handler != null || __commands != null || __hasRuntimeHandlers() || __hasRuntimePendingResponses());
			return;
		}

		if (__handler != null) {
			__connection.onData = __safeHandlerOnData;
			__connection.readEnabled = true;
			return;
		}

		if (__commands != null) {
			__connection.onData = __safeCommandsOnData;
			__connection.readEnabled = true;
			return;
		}

		__connection.onData = input -> {};
		__connection.readEnabled = false;
	}

	@:noCompletion private inline function __safeSessionOnData(input:ByteArrayInput):Void {
		try {
			__session_socket_onData(input);
		} catch (error:Dynamic) {
			__terminateProtocol(Reason.Error("RPC session decode failed: " + Std.string(error)));
		}
	}

	@:noCompletion private inline function __safeHandlerOnData(input:ByteArrayInput):Void {
		try {
			__handler.this_socket_onData(input);
		} catch (error:Dynamic) {
			__terminateProtocol(Reason.Error("RPC handler decode failed: " + Std.string(error)));
		}
	}

	@:noCompletion private inline function __safeCommandsOnData(input:ByteArrayInput):Void {
		try {
			__commands_socket_onData(input);
		} catch (error:Dynamic) {
			__terminateProtocol(Reason.Error("RPC command decode failed: " + Std.string(error)));
		}
	}

	@:noCompletion private inline function __commands_socket_onData(input:ByteArrayInput):Void {
		while (input.bytesAvailable >= 9) {
			final lenPos:Int = input.position;
			final payloadLen:Int = input.readInt();

			if (payloadLen < RPCWire.MIN_PAYLOAD_LEN || (RPCHandler.MAX_FRAME_LEN != 0 && payloadLen > RPCHandler.MAX_FRAME_LEN)) {
				throw "Invalid RPC frame length";
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				break;
			}

			final frameEnd:Int = input.position + payloadLen;
			if (__commands != null) {
				__commands.__frameEnd = frameEnd;
			}
			final flags:Int = input.readByte();
			if ((flags & RPCWire.FLAG_RUNTIME) != 0) {
				throw "Runtime RPC frame delivered to compile-time commands lane";
			}
			final op:Int = input.readInt();
			if (flags == RPCWire.FLAG_RESPONSE) {
				if (__commands != null) {
					__commands.__rpc_handle_response(op, input.readVarUInt(), input, false);
				}
			} else if (flags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
				if (__commands != null) {
					__commands.__rpc_handle_response(op, input.readVarUInt(), input, true);
				}
			}
			input.position = frameEnd;
		}

		@:privateAccess final now:Float = Timer.tryGetTime();
		if (now >= 0.0) {
			__connection.inTimestamp = now;
		}
	}

	@:noCompletion private inline function __session_socket_onData(input:ByteArrayInput):Void {
		while (input.bytesAvailable >= 9) {
			final lenPos:Int = input.position;
			final payloadLen:Int = input.readInt();

			if (payloadLen < RPCWire.MIN_PAYLOAD_LEN || (RPCHandler.MAX_FRAME_LEN != 0 && payloadLen > RPCHandler.MAX_FRAME_LEN)) {
				throw "Invalid RPC frame length";
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				break;
			}

			final frameEnd:Int = input.position + payloadLen;
			if (__handler != null) {
				__handler.this_frameEnd = frameEnd;
			}
			if (__commands != null) {
				__commands.__frameEnd = frameEnd;
			}
			final flags:Int = input.readByte();
			final op:Int = input.readInt();

			if ((flags & RPCWire.FLAG_RUNTIME) != 0) {
				__dispatchRuntimeFrame(flags, op, input, frameEnd);
			} else if (__handler != null) {
				__dispatchCompiledFrame(flags, op, input);
			} else if (__commands != null) {
				__dispatchCompiledResponseFrame(flags, op, input);
			}

			input.position = frameEnd;
		}

		@:privateAccess final now:Float = Timer.tryGetTime();
		if (now >= 0.0) {
			__connection.inTimestamp = now;
		}
	}

	@:noCompletion private inline function __dispatchCompiledFrame(flags:Int, op:Int, input:ByteArrayInput):Void {
		if (flags == 0) {
			__handler.dispatch(op, input, 0);
		} else if (flags == RPCWire.FLAG_REQUEST) {
			__handler.dispatch(op, input, input.readVarUInt());
		} else if (flags == RPCWire.FLAG_RESPONSE) {
			final requestId:Int = input.readVarUInt();
			if (__commands != null) {
				__commands.__rpc_handle_response(op, requestId, input, false);
			}
		} else if (flags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
			final requestId:Int = input.readVarUInt();
			if (__commands != null) {
				__commands.__rpc_handle_response(op, requestId, input, true);
			}
		} else {
			final requestId:Int = ((flags & RPCWire.FLAG_REQUEST) != 0) ? input.readVarUInt() : 0;
			__handler.dispatch(op, input, requestId);
		}
	}

	@:noCompletion private inline function __dispatchCompiledResponseFrame(flags:Int, op:Int, input:ByteArrayInput):Void {
		if (flags == RPCWire.FLAG_RESPONSE) {
			__commands.__rpc_handle_response(op, input.readVarUInt(), input, false);
		} else if (flags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
			__commands.__rpc_handle_response(op, input.readVarUInt(), input, true);
		}
	}

	/**
		One runtime frame, ending at `frameEnd`. Everything it carries is read,
		and checked to lie within it, before a handler runs or a caller is
		answered.
	**/
	@:noCompletion private function __dispatchRuntimeFrame(flags:Int, op:Int, input:ByteArrayInput, frameEnd:Int):Void {
		final runtimeFlags:Int = flags & ~RPCWire.FLAG_RUNTIME;
		if (runtimeFlags == 0 || runtimeFlags == RPCWire.FLAG_REQUEST) {
			final requestId:Int = runtimeFlags == 0 ? 0 : input.readVarUInt();
			// Asked before the arguments are read, so a call refused for its
			// size costs nothing to refuse. Refused, the frame is passed over.
			if (beforeRuntimeCall != null && !__admitRuntimeCall(op, requestId, frameEnd - input.position)) {
				return;
			}
			final args = RPCRuntimeCodec.readArgs(input, frameEnd);
			RPCWire.requireWithin(input, frameEnd);
			__invokeRuntime(op, args, requestId);
			return;
		}
		if (runtimeFlags == RPCWire.FLAG_RESPONSE) {
			final requestId:Int = input.readVarUInt();
			final value:Dynamic = RPCRuntimeCodec.readValue(input, frameEnd);
			RPCWire.requireWithin(input, frameEnd);
			__resolveRuntimeResponse(op, requestId, value);
			return;
		}
		if (runtimeFlags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
			final requestId:Int = input.readVarUInt();
			final message:String = input.readVarUTF();
			RPCWire.requireWithin(input, frameEnd);
			__rejectRuntimeResponse(requestId, message);
			return;
		}
		throw "Invalid runtime RPC flags";
	}

	@:noCompletion private function __invokeRuntime(op:Int, args:Array<Dynamic>, requestId:Int):Void {
		final handler = (__runtimeHandlers != null) ? __runtimeHandlers.get(op) : null;
		if (handler == null) {
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, "Unsupported runtime RPC op: " + op);
			}
			return;
		}

		var failure:Dynamic = null;
		try {
			final result = handler(args);
			if (requestId != 0) {
				__sendRuntimeResponse(op, requestId, result);
			}
		} catch (error:Dynamic) {
			// The caller was sent `Std.string(error)`, whatever it held -- a
			// path, a query, a stack -- and a one-way call rethrew, which
			// closed the connection. The same rules as the compiled lane now.
			failure = error;
			final answer:Null<String> = __answerFor(error);
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, answer != null ? answer : RPCError.INTERNAL_MESSAGE);
			}
			if (answer == null || requestId == 0) {
				__reportHandlerError(op, null, error);
			}
		}

		if (afterRuntimeCall != null) {
			try {
				afterRuntimeCall(op, requestId, failure);
			} catch (error:Dynamic) {
				__reportHandlerError(op, null, error);
			}
		}
	}

	/**
	 * Whether `beforeRuntimeCall` lets a call run. A refused request is
	 * answered with the refusal, and a hook that throws fails the call.
	 */
	@:noCompletion private function __admitRuntimeCall(op:Int, requestId:Int, payloadSize:Int):Bool {
		var refusal:Null<RPCError> = null;
		try {
			refusal = beforeRuntimeCall(op, requestId, payloadSize);
		} catch (error:Dynamic) {
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, RPCError.INTERNAL_MESSAGE);
			}
			__reportHandlerError(op, null, error);
			return false;
		}
		if (refusal == null) {
			return true;
		}
		if (requestId != 0) {
			__sendRuntimeError(op, requestId, refusal.message != null ? refusal.message : RPCError.INTERNAL_MESSAGE);
		}
		return false;
	}

	/** An `RPCError`'s message, which its caller is meant to see, or `null`. **/
	@:noCompletion private static function __answerFor(error:Dynamic):Null<String> {
		return Std.isOfType(error, RPCError) ? (cast error : RPCError).message : null;
	}

	@:noCompletion private function __reportHandlerError(op:Int, method:Null<String>, error:Dynamic):Void {
		try {
			onHandlerError(op, method, error);
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __sendRuntimeFrame(op:Int, requestId:Int, expectsResponse:Bool, args:Array<Dynamic>):Void {
		final framed = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 8);
		framed.writeInt(0);
		framed.writeByte(RPCWire.FLAG_RUNTIME | (expectsResponse ? RPCWire.FLAG_REQUEST : 0));
		framed.writeInt(op);
		if (expectsResponse) {
			framed.writeVarUInt(requestId);
		}
		RPCRuntimeCodec.writeArgs(framed, args);
		framed.writeIntAt(0, framed.bytesWritten - 4);
		framed.flush();
		__connection.send(framed);
	}

	@:noCompletion private function __sendRuntimeResponse(op:Int, requestId:Int, value:Dynamic):Void {
		final framed = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 8);
		framed.writeInt(0);
		framed.writeByte(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE);
		framed.writeInt(op);
		framed.writeVarUInt(requestId);
		RPCRuntimeCodec.writeValue(framed, value);
		framed.writeIntAt(0, framed.bytesWritten - 4);
		framed.flush();
		__connection.send(framed);
	}

	@:noCompletion private function __sendRuntimeError(op:Int, requestId:Int, message:String):Void {
		final framed = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 8);
		framed.writeInt(0);
		framed.writeByte(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR);
		framed.writeInt(op);
		framed.writeVarUInt(requestId);
		framed.writeVarUTF(message);
		framed.writeIntAt(0, framed.bytesWritten - 4);
		framed.flush();
		__connection.send(framed);
	}

	@:noCompletion private function __trackRuntimeResponse(requestId:Int, response:RPCResponse<Dynamic>):Void {
		if (__runtimePendingResponse == null) {
			__runtimePendingResponseId = requestId;
			__runtimePendingResponse = response;
		} else {
			if (__runtimePendingResponses == null) {
				__runtimePendingResponses = new IntMap();
			}
			__runtimePendingResponses.set(requestId, response);
		}
		__syncOnDataBinding();
	}

	@:noCompletion private function __resolveRuntimeResponse<T>(op:Int, requestId:Int, value:T):Void {
		final response = __takeRuntimeResponse(requestId);
		if (response == null) {
			return;
		}
		(cast response : RPCResponse<T>).__resolve(value);
	}

	@:noCompletion private function __rejectRuntimeResponse(requestId:Int, message:String):Void {
		final response = __takeRuntimeResponse(requestId);
		if (response == null) {
			return;
		}
		response.__reject(message);
	}

	@:noCompletion private function __takeRuntimeResponse(requestId:Int):RPCResponse<Dynamic> {
		var response:RPCResponse<Dynamic> = null;
		if (__runtimePendingResponse != null && requestId == __runtimePendingResponseId) {
			response = __runtimePendingResponse;
			__runtimePendingResponse = null;
			__runtimePendingResponseId = 0;
		} else if (__runtimePendingResponses != null) {
			response = __runtimePendingResponses.get(requestId);
			if (response != null) {
				__runtimePendingResponses.remove(requestId);
			}
		}
		__syncOnDataBinding();
		return response;
	}

	@:noCompletion private function __nextRuntimeRequestId():Int {
		do {
			__runtimeRequestIdSeed++;
			if (__runtimeRequestIdSeed <= 0) {
				__runtimeRequestIdSeed = 1;
			}
		} while ((__runtimeRequestIdSeed == __runtimePendingResponseId)
			|| (__runtimePendingResponses != null && __runtimePendingResponses.exists(__runtimeRequestIdSeed)));

		return __runtimeRequestIdSeed;
	}

	/**
	 * Rejects and clears every outstanding runtime `RPCResponse` with the given reason.
	 *
	 * Drains pending runtime request/response calls so callers are not left waiting on
	 * a reply that can no longer arrive. Must only be called on the owning thread.
	 */
	@:noCompletion private function __failAllRuntimePending(message:String):Void {
		final pending = __runtimePendingResponse;
		if (pending != null) {
			__runtimePendingResponse = null;
			__runtimePendingResponseId = 0;
			pending.__reject(message);
		}
		final map = __runtimePendingResponses;
		if (map != null) {
			__runtimePendingResponses = null;
			for (response in map) {
				response.__reject(message);
			}
		}
	}

	/**
	 * Rejects and clears every outstanding response on both the compiled command lane
	 * and the runtime lane.
	 *
	 * This is invoked when the session is stopped or the underlying connection closes,
	 * ensuring no `RPCResponse` is left perpetually uncompleted. Must only be called on
	 * the owning thread.
	 */
	@:noCompletion private function __failAllPending(message:String):Void {
		if (__commands != null) {
			__commands.__failAllPending(message);
		}
		__failAllRuntimePending(message);
	}

	/**
	 * Starts session bookkeeping and enables heartbeats when a command surface is present.
	 *
	 * @return `true` if the underlying connection was already connected at start time.
	 */
	public inline function start():Bool {
		Logger.info('Session $sessionId started');
		var status:Bool = __connection.connected;
		this.__heartbeatPhase = __calculateHeartbeatPhase();
		if (status && commands != null) {
			__resumeHeartbeat();
		}

		__active = true;

		return status;
	}

	/** Stops heartbeat bookkeeping without closing the underlying connection. */
	public inline function stop():Void {
		__active = false;
		__stopHeartbeat();
		__failAllPending("RPC session stopped");
	}

	@:noCompletion private inline function __stopHeartbeat():Void {
		// Guard against clearing an unstarted/already-cleared handle (0 is the
		// timer system's no-op sentinel). This keeps stop() safe and idempotent
		// even when no heartbeat was ever scheduled.
		if (__heartbeatTimerHandle != 0) {
			Timer.clear(__heartbeatTimerHandle);
			__heartbeatTimerHandle = 0;
		}
		__hasHeartbeat = false;
	}

	@:noCompletion private inline function __resumeHeartbeat():Void {
		Logger.info('Session $sessionId Heartbeat resumed');
		__hasHeartbeat = true;
		var jitter:Float = this.__heartbeatPhase / 1000;
		__intervalSec = this.__heartbeatInterval / 1000;
		Logger.info('With Jitter: $jitter and interval: $__intervalSec');
		Logger.separator();
		__timeoutSec = __heartbeatTimeout / 1000;
		this.__heartbeatTimerHandle = Timer.setInterval(jitter, __intervalSec, this.__onHeartbeat);
	}

	@:noCompletion private inline function __calculateHeartbeatPhase():Int {
		@:privateAccess
		var step:Int = Std.int(CrossByte.current().__tickInterval);
		var phase:Int = Bucket.phaseFromHash(__getHeartbeatKeyHash(), __heartbeatInterval, step);
		return phase;
	}

	@:noCompletion private inline function __getHeartbeatKeyHash():Int {
		var rAddr:String = (connection.remoteAddress == null ? "" : connection.remoteAddress);
		var lAddr:String = (connection.localAddress == null ? "" : connection.localAddress);
		var rPort:Int = connection.remotePort & 0xFFFF;
		var lPort:Int = connection.localPort & 0xFFFF;
		var key:String = rAddr + lAddr + rPort + lPort;
		var hash:Int = Hash.fnv1a32String(key);
		return Hash.combineHash32(HEARTBEAT_SALT, hash);
	}

	@:noCompletion private inline function __onHeartbeat():Void {
		if (__validateSession()) {
			commands.ping();
		}
		Logger.info('Session $sessionId sent a Heartbeat');
	}

	@:noCompletion private inline function __validateSession():Bool {
		final now:Float = Timer.getTime();
		final lastIn:Float = __connection.inTimestamp;

		final base:Float = (lastIn > 0.0) ? lastIn : now;
		final due:Float = base + __timeoutSec;

		Logger.info('Validating session $sessionId');
		Logger.info('now=$now lastIn=$lastIn timeoutSec=$__timeoutSec nextDue=$due');
		Logger.info('Previous incoming message received at $lastIn; next due at $due');

		if (now >= due) {
			__disconnect(Reason.Timeout);
			return false;
		}
		Logger.separator();

		final lastOut:Float = __connection.outTimestamp;
		return now - lastOut >= __intervalSec;
	}

	@:noCompletion private inline function __disconnect(reason:Reason):Void {
		__failAllPending("RPC connection closed: " + Std.string(reason));
		this.connection.close();
		this.connection.onClose(reason);
	}

	@:noCompletion private inline function __terminateProtocol(reason:Reason):Void {
		__failAllPending("RPC connection terminated: " + Std.string(reason));
		try {
			__connection.onError(reason);
		} catch (_:Dynamic) {}
		try {
			__connection.close();
		} catch (_:Dynamic) {}
	}
}
