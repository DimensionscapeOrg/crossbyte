package crossbyte.rpc;

import crossbyte._internal.system.timer.TimerHandle;

// Built for every target, JavaScript included: the portable suite runs RPC on
// Node and in a browser, where a NetConnection's Socket is a WebSocket.

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.io.ByteArray;
import crossbyte.net.INetConnection;
import crossbyte.net.Transport;
import crossbyte.net.Reason;
import crossbyte.utils.LogLevel;
import crossbyte.utils.Logger;
import crossbyte.core.CrossByte;
import crossbyte.Future;
import crossbyte.utils.Bucket;
import crossbyte.utils.Hash;
import crossbyte.sys.System;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCCommands;
import crossbyte.net.NetConnection;
import crossbyte.net.NetConnectionBase;
import crossbyte.events.EventDispatcher;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.rpc._internal.RPCRuntimeCodec;
import haxe.ds.IntMap;
// haxe.atomic on hl needs HashLink 1.13, and Haxe 4.3 assumes 1.12 unless told
// otherwise with -D hl-ver: the counter takes neko's lock there rather than
// failing the build with "Atomic operations require HL 1.13+".
#if (neko || (hl && hl_ver < version("1.13.0")))
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
	/** Default for `maxCallsWaiting`. */
	public static inline final DEFAULT_MAX_CALLS_WAITING:Int = 256;
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
	// TimerHandle.INVALID when no heartbeat is scheduled. Not 0: that is a real
	// handle, the first timer a scheduler hands out.
	@:noCompletion private var __heartbeatTimerHandle:Int = TimerHandle.INVALID;
	@:noCompletion private var __heartbeatInterval:Int = DEFAULT_HEARTBEAT_INTERVAL;
	@:noCompletion private var __heartbeatTimeout:Int = DEFAULT_HEARTBEAT_TIMEOUT;
	@:noCompletion private var __heartbeatPhase:Int;
	@:noCompletion private var __active:Bool = false;
	@:noCompletion private var __hasHeartbeat:Bool = false;
	@:noCompletion private var __timeoutSec:Float = 0.0;
	@:noCompletion private var __intervalSec:Float = 0.0;
	// When the heartbeat started, on the runtime's clock: what the peer is
	// judged to have been heard since, until something arrives.
	@:noCompletion private var __heardSince:Float = 0.0;
	@:noCompletion private var __runtimeHandlers:Null<IntMap<Array<Dynamic>->Dynamic>> = null;
	@:noCompletion private var __runtimeRequestIdSeed:Int = 0;
	@:noCompletion private var __runtimePendingResponseId:Int = 0;
	@:noCompletion private var __runtimePendingResponse:RPCResponse<Dynamic> = null;
	@:noCompletion private var __runtimePendingResponses:Null<IntMap<RPCResponse<Dynamic>>> = null;

	/**
	 * The most inbound calls, on both lanes together, that may wait on an
	 * answer at once: calls whose handler answered with a `Future` not yet
	 * complete. Each holds whatever it is waiting on, so without a limit a
	 * peer could make this side hold as much as it liked. A call past it is
	 * refused before its method runs -- a request answered
	 * `RPCError.BUSY_MESSAGE`, a one-way call dropped -- as `beforeCall`
	 * refuses one, and like a refusal it is not reported. On the runtime lane,
	 * where which handlers answer later is not known before they run, every
	 * call is refused while the limit is reached. `0` removes it.
	 */
	public var maxCallsWaiting:Int = DEFAULT_MAX_CALLS_WAITING;

	/** How many inbound calls are waiting on an answer now; see `maxCallsWaiting`. */
	public var callsWaiting(get, never):Int;

	/**
		How long, in milliseconds, each request this session makes -- through
		its commands or with `request` -- may wait for its answer before it
		fails with an `RPCTimeoutError`. `0`, as it starts, is no deadline: a
		call waits for as long as the connection lasts. A call can have a
		deadline of its own instead; see `RPCResponse.timeout`.

		Read as each call is made. A call with no deadline arms nothing; one
		with a deadline holds a timer until it is answered.
	**/
	public var callTimeout:Int = 0;

	/**
		How long, in milliseconds, a call this session's handler answers with
		a `Future` may wait for that future. Past it the caller is answered
		`RPCError.TIMEOUT_MESSAGE`, `onHandlerError` is told with an
		`RPCTimeoutError`, `afterCall` sees the same, and the call stops
		counting against `maxCallsWaiting`; the future completing later
		answers nothing. `0`, as it starts, is no limit: a future that never
		completes holds its place among the calls waiting for as long as the
		connection lasts.

		Both lanes, and only calls answered later: a method answering at once
		has answered before any deadline could pass.
	**/
	public var handlerTimeout:Int = 0;

	/**
		The most bytes a frame may hold, after its 4-byte length: what this
		session will read, and what it will send. A frame read past it ends
		the connection, since nothing after it can be trusted to line up. A
		call past it fails before it is sent -- a request's `RPCResponse` with
		an `ArgumentError` as its cause, a one-way call by throwing one -- and
		an answer past it is not sent: its caller is answered
		`RPCError.INTERNAL_MESSAGE` and `onHandlerError` is told.

		It was a constant, 8 MiB, and checked only as frames arrived, so a
		larger call went out without complaint and ended the connection on
		the other side, failing every call waiting on it. Both ends of a
		connection should agree on it. `0` removes the limit.
	**/
	public var maxFrameLength:Int = RPCHandler.MAX_FRAME_LEN;

	@:noCompletion private var __callsWaiting:Int = 0;
	// Whether the connection's onData is this session's reader: READ_ON,
	// READ_OFF, or READ_UNSET before the first binding.
	@:noCompletion private static inline final READ_UNSET:Int = -1;
	@:noCompletion private static inline final READ_OFF:Int = 0;
	@:noCompletion private static inline final READ_ON:Int = 1;
	@:noCompletion private var __readState:Int = READ_UNSET;
	// Set once the connection has ended: an answer completing after that has
	// nobody to go to, and a call made after it fails at once, with the
	// reason it ended.
	@:noCompletion private var __ended:Bool = false;
	@:noCompletion private var __endReason:Null<Reason> = null;
	// Which of its connection's lives the session is on, advanced each time
	// the connection ends. A call answered later keeps the one it came in on,
	// and is answered only while it is still current: a connection that takes
	// another peer, as a listening LocalConnection does, must not hand that
	// peer the last one's answers.
	@:noCompletion private var __epoch:Int = 0;
	#if (cpp || neko || hl || java || jvm || eval)
	@:noCompletion private static final __threadTokens:sys.thread.Tls<{}> = new sys.thread.Tls();
	#end

	#if (neko || (hl && hl_ver < version("1.13.0")))
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
		#if (neko || (hl && hl_ver < version("1.13.0")))
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
				old.__session = null;
			}
			if (commands != null) {
				commands.__nc = __connection;
				commands.__session = cast this;
			}
			__syncOnDataBinding();
		}

		return __commands;
	}

	/**
		The handler is not told of this session here: it may serve others,
		and is bound to each only while that one's calls run. See
		`__safeHandlerOnData`.
	**/
	@:noCompletion private inline function set_handler(handler:RPCHandler):RPCHandler {
		__handler = handler;
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
		__isUp = connection.connected;
		this.commands = commands;
		this.handler = handler;
		// Told as the connection ends, whenever and whether the application
		// sets onClose. A call still waiting on an answer used to wait for good
		// once the connection went: only stop(), a heartbeat timeout or an
		// unreadable frame failed it. And told, the same way, as it becomes
		// ready, for a heartbeat started before it was.
		(connection : NetConnectionBase).__observeClose(__connectionEnded);
		(connection : NetConnectionBase).__observeReady(__connectionReady);
	}

	/** The shortest wait before a session made by `dial` dials again, in seconds. **/
	public static inline final MIN_REDIAL:Float = 0.25;

	/** The longest, in seconds: the wait doubles from `MIN_REDIAL` each time a dial fails. **/
	public static inline final MAX_REDIAL:Float = 30.0;

	/**
		Called when the connection becomes ready: connected, or -- for a
		listening `LocalConnection`, or a session made by `dial` -- connected
		again. Not for a connection ready before the session was made, as an
		accepted one is.
	**/
	public dynamic function onUp():Void {}

	/**
		Called when a connection that was usable ends, with the reason its
		transport gave. The calls waiting on it have failed by then, with that
		reason as their `cause`.
	**/
	public dynamic function onDown(reason:Reason):Void {}

	/** Whether calls can go now: the connection is up and has not ended. **/
	public var up(get, never):Bool;

	@:noCompletion private inline function get_up():Bool {
		return __isUp && !__ended && __connection.connected;
	}

	// Whether the connection has been ready since it last ended -- from the
	// start, for one ready before the session was made -- so that being told
	// twice, as a connection ready as the session takes it may tell it
	// again, is one onUp.
	@:noCompletion private var __isUp:Bool = false;

	// For a session made by dial(): where it dials, how long it waits before
	// the next attempt, and the timer waiting; and, for any session, whether
	// close() has ended it for good.
	@:noCompletion private var __dialUri:Null<String> = null;
	@:noCompletion private var __redialDelay:Float = MIN_REDIAL;
	@:noCompletion private var __redialTimer:Int = TimerHandle.INVALID;
	@:noCompletion private var __closed:Bool = false;

	/**
		A client session that dials `uri` -- as `NetConnection` does, `tcp://`,
		`ws://`, `wss://`, `rudp://` or `local://` -- and dials it again whenever
		its connection ends, until `close()`: at once after an end, then waiting
		from `MIN_REDIAL` up to `MAX_REDIAL` seconds, doubling, between attempts
		that fail.

		While it is down -- before its first connection is up, and between one
		connection and the next -- a call through it fails as it is made, with a
		`Reason` as its `cause`: why the last connection ended, or why the last
		attempt failed. A call waiting when a connection ends fails with that
		connection's reason. `onUp` and `onDown` say when it comes and goes, and
		`up` whether it is up now.

		A gateway to a backend used to build this itself: dial, back off, bind
		a new session to each new connection, and check it was up before each
		call, since a call on a closed TCP connection threw out of its stub.

		Its `connection` is each connection in turn. Its commands, handler,
		`data` and hooks stay with it across them, and so does `start()`: a
		heartbeat runs on each connection while it is up. Made on the thread
		whose runtime will run it, which dials from its own timers.
	**/
	public static function dial<C:RPCCommands>(uri:String, ?commands:C, ?handler:RPCHandler):RPCSession<C, Dynamic> {
		final session = new RPCSession<C, Dynamic>(new Unconnected(uri), commands, handler);
		session.__dialUri = uri;
		session.__ended = true;
		session.__endReason = Reason.Error("Not connected to " + uri + " yet");
		// The first attempt at the next tick, not in here: a connect that
		// finishes as it is made -- local IPC, or anything on eval -- would
		// be up, and have told onUp, before the caller could set it.
		session.__redialTimer = Timer.setTimeout(0, session.__dial);
		return session;
	}

	/**
		Ends the session: it stops its heartbeat, dials no more if it was made
		by `dial`, and closes its connection, whose end its calls waiting and
		`onDown` hear as ever.
	**/
	public function close():Void {
		__closed = true;
		if (__redialTimer != TimerHandle.INVALID) {
			Timer.clear(__redialTimer);
			__redialTimer = TimerHandle.INVALID;
		}
		__active = false;
		__stopHeartbeat();
		try {
			__connection.close();
		} catch (_:Dynamic) {}
		// A connection whose close says nothing -- some of an application's
		// own -- has ended all the same.
		if (!__ended) {
			__connectionEnded(Reason.Closed);
		}
	}

	/** One attempt: a new connection to `__dialUri`, which the session moves to. **/
	@:noCompletion private function __dial():Void {
		__redialTimer = TimerHandle.INVALID;
		if (__closed) {
			return;
		}
		var connection:Null<NetConnection> = null;
		try {
			// A single try over local IPC, whose connect waits on this thread
			// for a listener: a dial never holds up the runtime waiting.
			connection = new NetConnection(__dialUri, null, null, null, null, false, 0);
		} catch (error:Dynamic) {
			// Refused as it was made -- a local:// name nobody listens on.
			__endReason = Reason.Error("Could not connect to " + __dialUri + ": " + Std.string(error));
			__redialLater();
			return;
		}
		__moveTo(connection);
	}

	/** Dials again once the wait is up, and waits longer next time. **/
	@:noCompletion private function __redialLater():Void {
		if (__closed || __dialUri == null || __redialTimer != TimerHandle.INVALID) {
			return;
		}
		final delay:Float = __redialDelay;
		__redialDelay = __redialDelay * 2 > MAX_REDIAL ? MAX_REDIAL : __redialDelay * 2;
		__redialTimer = Timer.setTimeout(delay, __dial);
	}

	/**
		Lets go of the connection it had, which has ended, and takes
		`connection`: reads it, observes it, and binds its commands to it. The
		session stays down until `connection` says it is ready.
	**/
	@:noCompletion private function __moveTo(connection:NetConnection):Void {
		final old:NetConnectionBase = __connection;
		old.__observeClose(null);
		old.__observeReady(null);
		if (__readState == READ_ON) {
			try {
				__connection.onData = __noData;
				__connection.readEnabled = false;
			} catch (_:Dynamic) {}
		}
		__connection = connection;
		__readState = READ_UNSET;
		__isUp = false;
		if (__commands != null) {
			__commands.__nc = connection;
		}
		(connection : NetConnectionBase).__observeClose(__connectionEnded);
		(connection : NetConnectionBase).__observeReady(__connectionReady);
		__syncOnDataBinding();
		// Connected already -- a connect that finishes as it is made, as on
		// eval, told whoever was listening before this was.
		if (connection.connected) {
			__connectionReady();
		}
	}

	/** The connection can carry no answer now, so nothing waiting on one gets it. **/
	@:noCompletion private function __connectionEnded(reason:Reason):Void {
		final wasUp:Bool = __isUp && !__ended;
		__isUp = false;
		__ended = true;
		__endReason = reason;
		// `| 0` so it wraps on JavaScript as it does elsewhere.
		__epoch = (__epoch + 1) | 0;
		// Stopped, not forgotten: `start()` still stands, for a connection
		// that becomes ready again.
		__stopHeartbeat();
		__failAllPending("RPC connection closed: " + Std.string(reason), reason);
		if (wasUp) {
			try {
				onDown(reason);
			} catch (error:Dynamic) {
				Logger.error("RPCSession.onDown threw: " + Std.string(error));
			}
		}
		if (__dialUri != null && !__closed) {
			// At once after a connection that was up; later after an attempt
			// that never got that far.
			if (wasUp) {
				__redialDelay = MIN_REDIAL;
				__dial();
			} else {
				__redialLater();
			}
		}
	}

	/** Whether the connection is still on the life `epoch` names, and has not ended. **/
	@:noCompletion private inline function __isCurrent(epoch:Int):Bool {
		return epoch == __epoch && !__ended;
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

	/**
		Sends a one-way runtime RPC call on the dynamic lane. Each argument is
		`null`, a `Bool`, an `Int`, a `Float`, a `String` or `haxe.io.Bytes`
		-- a `ByteArray` among them, sent as its `length` bytes -- and arrives
		as the same, `Bytes` for either of the last.

		@throws ArgumentError When the call is over `maxFrameLength`.
		@throws String When an argument is of a type the runtime lane does not carry.
	**/
	public function call(op:Int, ?args:Array<Dynamic>):Void {
		__sendCallFrame(__runtimeFrame(op, 0, args));
	}

	/**
	 * Sends a request/response runtime RPC call on the dynamic lane. Its
	 * arguments, and the answer, are of the types `call` carries.
	 *
	 * The response payload is decoded through the runtime codec and resolved into a
	 * normal `RPCResponse<T>`. A call that cannot go fails at once: over
	 * `maxFrameLength`, with an `ArgumentError` as its cause; on a connection
	 * that has ended, with the `Reason` it ended with; and when the send
	 * throws, with what it threw.
	 *
	 * @throws String When an argument is of a type the runtime lane does not carry;
	 * nothing is left waiting.
	 */
	public function request<T>(op:Int, ?args:Array<Dynamic>):RPCResponse<T> {
		final requestId = __nextRuntimeRequestId();
		// Framed before it waits, so an argument that cannot be sent leaves
		// nothing waiting for good.
		final framed = __runtimeFrame(op, requestId, args);
		final response = new RPCResponse<T>(requestId, op);
		response.__session = cast this;
		__trackRuntimeResponse(requestId, cast response);
		if (callTimeout > 0) {
			response.__arm(callTimeout);
		}
		__sendRequestFrame(response, framed);
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

	/**
		Whether the session reads its connection: while it has anything that
		reads -- a handler, commands, runtime handlers or runtime calls
		waiting -- or a heartbeat, which reads the answers to its pings. A
		session with none leaves what arrives unread until it has.

		Called as each of those changes, which on the runtime lane is every
		call; so the connection is told only when the answer changes.
	**/
	@:noCompletion private function __syncOnDataBinding():Void {
		final read:Bool = __handler != null || __commands != null || __active || __hasRuntimeHandlers() || __hasRuntimePendingResponses();
		final state:Int = read ? READ_ON : READ_OFF;
		if (state == __readState) {
			return;
		}
		__readState = state;
		if (read) {
			__connection.onData = __safeOnData;
			__connection.readEnabled = true;
		} else {
			__connection.onData = __noData;
			__connection.readEnabled = false;
		}
	}

	@:noCompletion private static function __noData(input:ByteArrayInput):Void {}

	/*
		A delivery, read here whatever the session has bound; a frame nothing
		here can read ends the connection.

		The handler is bound to this session for as long as its calls run --
		a field write per call -- and put back as it was once the delivery
		has been read. One handler can serve any number of sessions, so it
		answers on, and names as `session`, whichever is dispatching to it
		now. Put back rather than cleared: over a connection that delivers at
		once, a method running for this session can make a call that another
		session dispatches to the same handler before this one's method has
		returned.
	*/
	@:noCompletion private function __safeOnData(input:ByteArrayInput):Void {
		final handler = __handler;
		final outer:RPCSession<Dynamic, Dynamic> = handler != null ? handler.this_session : null;
		try {
			__readFrames(input);
		} catch (error:Dynamic) {
			if (handler != null) {
				handler.this_session = outer;
			}
			__terminateProtocol(Reason.Error("RPC frame could not be read: " + Std.string(error)));
			return;
		}
		if (handler != null) {
			handler.this_session = outer;
		}
	}

	/**
		Every whole frame in `input`, on both lanes.

		There were three readers, one for each thing a session might have
		bound, and each knew only its own: a runtime call to a session with
		no runtime handlers ended its connection -- the reader for a
		compiled handler took it for garbage -- where the guide promised an
		error answer, and a compiled request to a session with no handler
		was dropped, with its caller left waiting on a connection that was
		up. Now any runtime call is answered as the runtime lane answers, and
		a request with nothing to answer it is answered
		`RPCError.NO_HANDLER_MESSAGE`.
	**/
	@:noCompletion private inline function __readFrames(input:ByteArrayInput):Void {
		final maxLength:Int = maxFrameLength;
		while (input.bytesAvailable >= 9) {
			final lenPos:Int = input.position;
			final payloadLen:Int = input.readInt();

			if (payloadLen < RPCWire.MIN_PAYLOAD_LEN || (maxLength > 0 && payloadLen > maxLength)) {
				throw "Invalid RPC frame length";
			}

			if (input.bytesAvailable < payloadLen) {
				input.position = lenPos;
				break;
			}

			final frameEnd:Int = input.position + payloadLen;
			final flags:Int = input.readByte();
			final op:Int = input.readInt();

			if ((flags & RPCWire.FLAG_RUNTIME) != 0) {
				__dispatchRuntimeFrame(flags, op, input, frameEnd);
			} else if (flags == 0 || flags == RPCWire.FLAG_REQUEST) {
				final requestId:Int = flags == 0 ? 0 : input.readVarUInt();
				final handler = __handler;
				if (requestId == 0 && op == RPCWire.PING_OP) {
					__pinged();
				} else if (handler != null) {
					handler.this_session = cast this;
					handler.this_frameEnd = frameEnd;
					handler.dispatch(op, input, requestId);
				} else if (requestId != 0) {
					__sendCompiledError(op, requestId, RPCError.NO_HANDLER_MESSAGE);
				}
			} else if (flags == RPCWire.FLAG_RESPONSE || flags == (RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR)) {
				// Id 0 answers no call: a pong.
				final requestId:Int = input.readVarUInt();
				final commands = __commands;
				if (requestId != 0 && commands != null) {
					commands.__frameEnd = frameEnd;
					commands.__rpc_handle_response(op, requestId, input, flags != RPCWire.FLAG_RESPONSE);
				}
			} else {
				throw "Invalid RPC frame flags " + flags;
			}

			input.position = frameEnd;
		}

		@:privateAccess final now:Float = Timer.tryGetTime();
		if (now >= 0.0) {
			__connection.inTimestamp = now;
		}
	}

	/**
		A ping arrived: answered with a pong, and the handler's `ping` told,
		if it has one. Not a call, so neither `beforeCall` nor `afterCall`
		sees it: a limit on calls must not refuse the heartbeat.
	**/
	@:noCompletion private function __pinged():Void {
		__answerPing();
		final handler = __handler;
		if (handler != null) {
			try {
				handler.ping();
			} catch (error:Dynamic) {
				__reportHandlerError(RPCWire.PING_OP, "ping", error);
			}
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
			__rejectRuntimeResponse(op, requestId, message);
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
		if (__atCallLimit()) {
			if (requestId != 0) {
				__sendRuntimeError(op, requestId, RPCError.BUSY_MESSAGE);
			}
			return;
		}

		var failure:Dynamic = null;
		var later:Null<Future<Dynamic>> = null;
		try {
			final result = handler(args);
			// A type check a call: the one thing answering later costs a
			// handler that does not.
			if (Std.isOfType(result, Future)) {
				later = cast result;
			} else if (requestId != 0) {
				__sendRuntimeResponse(op, requestId, result);
			}
		} catch (error:Dynamic) {
			// The caller was sent `Std.string(error)`, whatever it held -- a
			// path, a query, a stack -- and a one-way call rethrew, which
			// closed the connection. The same rules as the compiled lane now.
			failure = error;
			__answerRuntimeFailure(op, requestId, error, __epoch);
		}

		if (later != null) {
			final epoch:Int = __epoch;
			__settleOnThisThread(later, settled -> __settleRuntimeCall(op, requestId, settled, epoch));
			return;
		}
		__afterRuntimeCall(op, requestId, failure);
	}

	/**
		A runtime call whose handler answered with a future, now complete:
		answered while the connection is on the life, `epoch`, it came in on.
	**/
	@:noCompletion private function __settleRuntimeCall(op:Int, requestId:Int, settled:Future<Dynamic>, epoch:Int):Void {
		var failure:Dynamic = null;
		if (settled.succeeded) {
			if (requestId != 0 && __isCurrent(epoch)) {
				try {
					__sendRuntimeResponse(op, requestId, settled.result);
				} catch (error:Dynamic) {
					failure = error;
					__answerRuntimeFailure(op, requestId, error, epoch);
				}
			}
		} else {
			failure = __failureOf(settled);
			__answerRuntimeFailure(op, requestId, failure, epoch);
		}
		__afterRuntimeCall(op, requestId, failure);
	}

	/**
	 * A runtime call failed with `error`: a request is answered with an
	 * `RPCError`'s message, or `RPCError.INTERNAL_MESSAGE`, and whatever the
	 * caller is not told is reported.
	 */
	@:noCompletion private function __answerRuntimeFailure(op:Int, requestId:Int, error:Dynamic, epoch:Int):Void {
		final answer:Null<String> = __answerFor(error);
		if (requestId != 0 && __isCurrent(epoch)) {
			__sendRuntimeError(op, requestId, answer != null ? answer : RPCError.INTERNAL_MESSAGE);
		}
		if (__reported(answer, requestId, error)) {
			__reportHandlerError(op, null, error);
		}
	}

	/**
		Whether a call's failure is reported on this side: when its caller is
		not told what it was -- anything but an `RPCError`, or anything from a
		one-way call -- and when it timed out, which its caller is told and
		which is news here as well.
	**/
	@:noCompletion private static inline function __reported(answer:Null<String>, requestId:Int, error:Dynamic):Bool {
		return answer == null || requestId == 0 || Std.isOfType(error, RPCTimeoutError);
	}

	/**
		A compiled call failed with `error`, where `answerable` says whether
		its caller can still be answered: a request is answered with an
		`RPCError`'s message, or `RPCError.INTERNAL_MESSAGE`, and whatever the
		caller is not told is reported. An `RPCError` for a caller who can no
		longer be told is neither.
	**/
	@:noCompletion private function __callFailed(op:Int, method:String, requestId:Int, error:Dynamic, answerable:Bool):Void {
		final answer:Null<String> = __answerFor(error);
		if (requestId != 0 && answerable) {
			__sendCompiledError(op, requestId, answer != null ? answer : RPCError.INTERNAL_MESSAGE);
		}
		if (__reported(answer, requestId, error)) {
			__reportHandlerError(op, method, error);
		}
	}

	/**
		Sends a compiled call's answer, framed by the handler's generated code.
		One over `maxFrameLength` throws, which the call it answers takes for
		the handler failing: its caller is answered `RPCError.INTERNAL_MESSAGE`
		and `onHandlerError` is told.
	**/
	@:noCompletion private inline function __sendAnswer(framed:ByteArrayOutput):Void {
		if (__oversized(framed)) {
			throw new ArgumentError(__oversizedMessage("RPC answer", framed));
		}
		// An answer for a connection that has ended -- its handler closed it
		// -- has nobody to go to.
		if (!__ended) {
			__connection.send(framed);
		}
	}

	/**
		Why a call made now cannot go, or `null` if it can: the connection has
		ended. The message for a caller, and the `Reason` it ended with as the
		cause.
	**/
	@:noCompletion private inline function __closedMessage():String {
		return "RPC connection closed: " + Std.string(__endReason);
	}

	/**
		Sends a request's frame, or fails `response` at once when it cannot go:
		the connection has ended, the frame is over `maxFrameLength`, or the
		send throws. Nothing is left waiting on an answer that cannot come.

		Over TCP a send on a closed connection threw out of the call, and left
		its response waiting; over local IPC it was reported to `onError`, and
		the response waited for good.
	**/
	@:noCompletion private function __sendRequestFrame<T>(response:RPCResponse<T>, framed:ByteArrayOutput):Void {
		var message:Null<String> = null;
		var cause:Dynamic = null;
		if (__oversized(framed)) {
			message = __oversizedMessage("RPC call", framed);
			cause = new ArgumentError(message);
		} else if (__ended) {
			message = __closedMessage();
			cause = __endReason;
		} else {
			try {
				__connection.send(framed);
			} catch (error:Dynamic) {
				message = "RPC call could not be sent: " + Std.string(error);
				cause = error;
			}
		}
		if (message != null) {
			// Out of where it waits first, as a deadline takes it.
			if (response.__commands != null) {
				response.__commands.__takeResponse(response.requestId);
			} else {
				__takeRuntimeResponse(response.requestId);
			}
			response.__fail(message, cause);
		}
	}

	/**
		Sends a one-way call's frame. Over `maxFrameLength` it throws; on a
		connection that has ended it is dropped, since nobody is told what
		becomes of a one-way call.

		@throws ArgumentError When the call is over `maxFrameLength`.
	**/
	@:noCompletion private function __sendCallFrame(framed:ByteArrayOutput):Void {
		if (__oversized(framed)) {
			throw new ArgumentError(__oversizedMessage("RPC call", framed));
		}
		if (!__ended) {
			__connection.send(framed);
		}
	}

	/** Whether `framed`, its 4-byte length first, holds more than `maxFrameLength`. **/
	@:noCompletion private inline function __oversized(framed:ByteArrayOutput):Bool {
		return maxFrameLength > 0 && framed.bytesWritten - 4 > maxFrameLength;
	}

	@:noCompletion private function __oversizedMessage(what:String, framed:ByteArrayOutput):String {
		return what + " of " + (framed.bytesWritten - 4) + " bytes is over the " + maxFrameLength + "-byte RPC frame limit";
	}

	/** Answers a compiled request with an error; nothing, once the connection has ended. **/
	@:noCompletion private function __sendCompiledError(op:Int, requestId:Int, message:String):Void {
		if (__ended) {
			return;
		}
		var framed:ByteArrayOutput = __errorFrame(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR, op, requestId, message);
		if (__oversized(framed)) {
			// A message too long to send -- an RPCError's -- is not the caller's
			// to see in part.
			framed = __errorFrame(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR, op, requestId, RPCError.INTERNAL_MESSAGE);
		}
		__connection.send(framed);
	}

	@:noCompletion private static function __errorFrame(flags:Int, op:Int, requestId:Int, message:String):ByteArrayOutput {
		final framed:ByteArrayOutput = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 8);
		framed.writeInt(0);
		framed.writeByte(flags);
		framed.writeInt(op);
		framed.writeVarUInt(requestId);
		framed.writeVarUTF(message);
		framed.writeIntAt(0, framed.bytesWritten - 4);
		framed.flush();
		return framed;
	}

	@:noCompletion private inline function __afterRuntimeCall(op:Int, requestId:Int, failure:Dynamic):Void {
		if (afterRuntimeCall != null) {
			try {
				afterRuntimeCall(op, requestId, failure);
			} catch (error:Dynamic) {
				__reportHandlerError(op, null, error);
			}
		}
	}

	/** Whether `maxCallsWaiting` calls are waiting already. **/
	@:noCompletion private inline function __atCallLimit():Bool {
		return maxCallsWaiting > 0 && __callsWaiting >= maxCallsWaiting;
	}

	@:noCompletion private inline function get_callsWaiting():Int {
		return __callsWaiting;
	}

	/**
	 * Has `settle` run for `future` on this session's thread once it
	 * completes: at once if it has, or when it completes on this thread, and
	 * posted to this thread's runtime when it completes on another -- a
	 * connection is not thread-safe, and neither is anything this does in
	 * answer. Until then the call counts against `maxCallsWaiting`.
	 *
	 * Called on this session's thread, from the dispatch of the call. A
	 * thread with no runtime has nothing to hand the answer to, so there it
	 * is settled on whichever thread completes the future.
	 */
	@:noCompletion private function __settleOnThisThread<T>(future:Future<T>, settle:Future<T>->Void):Void {
		// Under the future's lock, so what settle reads of one another thread
		// has just completed is that thread's, whole.
		if (future.__stateNow() != 0) {
			// Heard, so not reported as a failure nobody listened for -- which a
			// future that failed before anyone could attach otherwise is.
			future.__failureObserved = true;
			settle(future);
			return;
		}
		__callsWaiting++;
		// With a `handlerTimeout`, settled by whichever of the future and the
		// deadline comes first, on this thread; without one, only the future
		// settles it, and nothing more is made for it.
		final finish:Void->Void = handlerTimeout > 0 ? new HandlerDeadline<T>(cast this, future, settle, handlerTimeout).finish : function():Void {
			__callsWaiting--;
			settle(future);
		};
		#if (cpp || neko || hl || java || jvm || eval)
		// Which thread this is, told apart by a token of its own rather than
		// by runtime: CrossByte.current() says which runtime a thread has,
		// and throws on a thread with none, where a future is often
		// completed; it cannot say which thread the completion came on. The
		// runtime is read here, on this session's thread, where it has one.
		final home:{} = __threadToken();
		var runtime:Null<CrossByte> = null;
		try {
			runtime = CrossByte.current();
		} catch (_:Dynamic) {}
		final arrived = function():Void {
			if (runtime != null && __threadToken() != home) {
				runtime.__post(finish);
			} else {
				finish();
			}
		};
		future.then(_ -> arrived(), _ -> arrived());
		#else
		future.then(_ -> finish(), _ -> finish());
		#end
	}

	#if (cpp || neko || hl || java || jvm || eval)
	@:noCompletion private static function __threadToken():{} {
		var token:Null<{}> = __threadTokens.value;
		if (token == null) {
			token = {};
			__threadTokens.value = token;
		}
		return token;
	}
	#end

	/** What a failed future failed with: its cause, or else its message. **/
	@:noCompletion private static inline function __failureOf<T>(future:Future<T>):Dynamic {
		return future.cause != null ? future.cause : future.error;
	}

	/** The failure a call answered later settles with when `handlerTimeout` passes first. **/
	@:noCompletion private static function __handlerTimedOut<T>():Future<T> {
		final timedOut = new Future<T>();
		// Read at once, by whoever settles with it: not a failure nobody heard.
		timedOut.__failureObserved = true;
		timedOut.__fail(RPCError.TIMEOUT_MESSAGE, new RPCTimeoutError());
		return timedOut;
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

	/** A runtime call's frame: a request with `requestId`, or a one-way call when it is 0. **/
	@:noCompletion private static function __runtimeFrame(op:Int, requestId:Int, args:Array<Dynamic>):ByteArrayOutput {
		final framed = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 8);
		framed.writeInt(0);
		framed.writeByte(RPCWire.FLAG_RUNTIME | (requestId != 0 ? RPCWire.FLAG_REQUEST : 0));
		framed.writeInt(op);
		if (requestId != 0) {
			framed.writeVarUInt(requestId);
		}
		RPCRuntimeCodec.writeArgs(framed, args);
		framed.writeIntAt(0, framed.bytesWritten - 4);
		framed.flush();
		return framed;
	}

	/** One over `maxFrameLength` throws, as `__sendAnswer` does. **/
	@:noCompletion private function __sendRuntimeResponse(op:Int, requestId:Int, value:Dynamic):Void {
		final framed = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 8);
		framed.writeInt(0);
		framed.writeByte(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE);
		framed.writeInt(op);
		framed.writeVarUInt(requestId);
		RPCRuntimeCodec.writeValue(framed, value);
		framed.writeIntAt(0, framed.bytesWritten - 4);
		framed.flush();
		if (__oversized(framed)) {
			throw new ArgumentError(__oversizedMessage("RPC answer", framed));
		}
		if (!__ended) {
			__connection.send(framed);
		}
	}

	@:noCompletion private function __sendRuntimeError(op:Int, requestId:Int, message:String):Void {
		if (__ended) {
			return;
		}
		final flags:Int = RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR;
		var framed:ByteArrayOutput = __errorFrame(flags, op, requestId, message);
		if (__oversized(framed)) {
			framed = __errorFrame(flags, op, requestId, RPCError.INTERNAL_MESSAGE);
		}
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
		// A call waiting can only start the session reading.
		if (__readState != READ_ON) {
			__syncOnDataBinding();
		}
	}

	@:noCompletion private function __resolveRuntimeResponse<T>(op:Int, requestId:Int, value:T):Void {
		final response = __takeRuntimeResponse(requestId);
		if (response == null) {
			return;
		}
		if (response.op != op) {
			__answeredForAnotherOp(response, op);
			return;
		}
		(cast response : RPCResponse<T>).__resolve(value);
	}

	@:noCompletion private function __rejectRuntimeResponse(op:Int, requestId:Int, message:String):Void {
		final response = __takeRuntimeResponse(requestId);
		if (response == null) {
			return;
		}
		if (response.op != op) {
			__answeredForAnotherOp(response, op);
			return;
		}
		// The other side's handler meant its caller to see this, so it fails
		// with an RPCError: a handler here answering with this response passes
		// the message on, as it would one it threw.
		response.__fail(message, new RPCError(message));
	}

	/**
		A response under `response`'s id for another op, `op`, is not its
		answer, and its value is not of its type.

		Responses were matched by id alone. Each caller numbers its calls from
		1, so a peer answering one caller's call on another's connection -- as
		one handler bound to two sessions did -- completed that caller's own
		call with the wrong answer: a `String` call resolved with an `Int`. The
		call fails instead, since the one answer it could have had is spent.
	**/
	@:noCompletion private static function __answeredForAnotherOp(response:RPCResponse<Dynamic>, op:Int):Void {
		response.__fail('RPC response for op $op does not answer call ${response.requestId}, which was for op ${response.op}', null);
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
		// One no longer waiting can only stop it, and only when nothing else
		// keeps it reading.
		if (__handler == null && __commands == null && !__active) {
			__syncOnDataBinding();
		}
		return response;
	}

	@:noCompletion private function __nextRuntimeRequestId():Int {
		do {
			// `| 0` so the increment wraps on JavaScript too; see
			// RPCCommands.__nextRequestId.
			__runtimeRequestIdSeed = (__runtimeRequestIdSeed + 1) | 0;
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
	@:noCompletion private function __failAllRuntimePending(message:String, ?cause:Dynamic):Void {
		final pending = __runtimePendingResponse;
		if (pending != null) {
			__runtimePendingResponse = null;
			__runtimePendingResponseId = 0;
			pending.__fail(message, cause);
		}
		final map = __runtimePendingResponses;
		if (map != null) {
			__runtimePendingResponses = null;
			for (response in map) {
				response.__fail(message, cause);
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
	 *
	 * `cause` is the `Reason` the connection ended with, when it did: a call that
	 * failed as its connection went carried a message and nothing a caller could
	 * decide by, and a gateway could not tell a backend gone from a refusal.
	 */
	@:noCompletion private function __failAllPending(message:String, ?cause:Dynamic):Void {
		if (__commands != null) {
			__commands.__failAllPending(message, cause);
		}
		__failAllRuntimePending(message, cause);
	}

	/**
	 * Starts the session's heartbeat: a `ping` every `heartbeatInterval`
	 * milliseconds when nothing else has been sent, and the connection
	 * closed when nothing has arrived for `heartbeatTimeout`. Every session
	 * answers a ping, so an idle peer is heard from all the same.
	 *
	 * A session with or without commands has one. Started before its
	 * connection is up, it begins once the connection is ready. Started
	 * again, it carries on as it was.
	 *
	 * @return `true` if the underlying connection was already connected at start time.
	 */
	public function start():Bool {
		final connected:Bool = __connection.connected;
		if (!__active) {
			__active = true;
			__heartbeatPhase = __calculateHeartbeatPhase();
			// It reads its connection now, whatever it has bound, to hear
			// the answers to its pings.
			__syncOnDataBinding();
		}
		if (connected && !__ended && !__hasHeartbeat) {
			__resumeHeartbeat();
		}
		return connected;
	}

	/** Stops heartbeat bookkeeping without closing the underlying connection. */
	public function stop():Void {
		__active = false;
		__stopHeartbeat();
		__syncOnDataBinding();
		__failAllPending("RPC session stopped");
	}

	/**
		The connection has become ready: a heartbeat asked for before it was
		starts now, and a connection that had ended -- a `LocalConnection`
		listening again, which takes its next peer on the same object -- is
		answered on again.

		The session stayed ended once its connection first closed: for every
		peer after the first, each error answer and each answer given later was
		dropped, and the heartbeat stayed off. What was waiting from the last
		peer stays on its own life of the connection, and answers nobody.
	**/
	@:noCompletion private function __connectionReady():Void {
		if (__isUp) {
			return;
		}
		__isUp = true;
		if (__ended) {
			__ended = false;
			__endReason = null;
		}
		__redialDelay = MIN_REDIAL;
		if (__active && !__hasHeartbeat) {
			__resumeHeartbeat();
		}
		try {
			onUp();
		} catch (error:Dynamic) {
			Logger.error("RPCSession.onUp threw: " + Std.string(error));
		}
	}

	@:noCompletion private inline function __stopHeartbeat():Void {
		// Guard against clearing an unstarted/already-cleared handle, which keeps
		// stop() safe and idempotent even when no heartbeat was ever scheduled.
		// The sentinel is TimerHandle.INVALID, not 0: slot 0 of generation 0 is
		// handle 0, so a session whose heartbeat was the scheduler's first timer
		// could never be stopped, and went on pinging a closed connection.
		if (__heartbeatTimerHandle != TimerHandle.INVALID) {
			Timer.clear(__heartbeatTimerHandle);
			__heartbeatTimerHandle = TimerHandle.INVALID;
		}
		__hasHeartbeat = false;
	}

	/**
		Schedules the heartbeat, which is not running. Its phase spreads the
		sessions of one process across the interval, so a server's heartbeats
		do not all fall on one tick.

		What it has heard is counted from now as well as from the last
		arrival. A connection starts having heard nothing, at 0, and a peer
		that never sent a byte was compared against a deadline that moved
		with the clock: it was never timed out.
	**/
	@:noCompletion private function __resumeHeartbeat():Void {
		__hasHeartbeat = true;
		__intervalSec = __heartbeatInterval / 1000;
		__timeoutSec = __heartbeatTimeout / 1000;
		__heardSince = Timer.getTime();
		__heartbeatTimerHandle = Timer.setInterval(__heartbeatPhase / 1000, __intervalSec, __onHeartbeat);
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

	/**
		A beat: the connection closed if nothing has arrived for the timeout,
		and otherwise a ping if nothing has been sent for an interval.

		It logged five lines at INFO for every session on every beat.
	**/
	@:noCompletion private function __onHeartbeat():Void {
		if (__ended) {
			__stopHeartbeat();
			return;
		}
		final now:Float = Timer.getTime();
		final lastIn:Float = __connection.inTimestamp;
		final heard:Float = lastIn > __heardSince ? lastIn : __heardSince;
		if (now - heard >= __timeoutSec) {
			__timedOut(now - heard);
			return;
		}
		if (now - __connection.outTimestamp >= __intervalSec) {
			__sendPing();
		}
	}

	/** A ping: a one-way frame for `ping`, with no arguments. **/
	@:noCompletion private function __sendPing():Void {
		final framed:ByteArrayOutput = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 4);
		framed.writeInt(RPCWire.MIN_PAYLOAD_LEN);
		framed.writeByte(0);
		framed.writeInt(RPCWire.PING_OP);
		framed.flush();
		try {
			__connection.send(framed);
		} catch (_:Dynamic) {
			// A connection that can take nothing more says so as it ends,
			// which stops this. A beat does not throw out of the tick.
		}
	}

	/**
		Answers a ping with a pong: a response frame for `ping` under request
		id 0. Pings were one-way and nobody answered them, so a client
		heartbeating a server that only answers calls heard nothing between
		calls and closed a healthy connection.
	**/
	@:noCompletion private function __answerPing():Void {
		if (__ended) {
			return;
		}
		final framed:ByteArrayOutput = new ByteArrayOutput(RPCWire.MIN_PAYLOAD_LEN + 5);
		framed.writeInt(RPCWire.MIN_PAYLOAD_LEN + 1);
		framed.writeByte(RPCWire.FLAG_RESPONSE);
		framed.writeInt(RPCWire.PING_OP);
		framed.writeVarUInt(0);
		framed.flush();
		__connection.send(framed);
	}

	/**
		Nothing has arrived for the heartbeat's timeout: the calls waiting
		fail, saying so, and the connection is closed, which tells the
		application -- once, with the reason its transport gives for a close.
		The session used to report `Timeout` itself after `close()` had
		reported `Closed`, so `onClose` ran twice.
	**/
	@:noCompletion private function __timedOut(silence:Float):Void {
		__stopHeartbeat();
		if (Logger.isEnabled(LogLevel.DEBUG)) {
			Logger.debug('RPC session $sessionId heard nothing for $silence s; closing its connection');
		}
		__failAllPending("RPC connection timed out: nothing arrived for " + __heartbeatTimeout + " ms", Reason.Timeout);
		try {
			__connection.close();
		} catch (_:Dynamic) {}
		// A connection whose close says nothing -- some of an application's
		// own -- has ended all the same.
		if (!__ended) {
			__connectionEnded(Reason.Timeout);
		}
	}

	@:noCompletion private inline function __terminateProtocol(reason:Reason):Void {
		__failAllPending("RPC connection terminated: " + Std.string(reason), reason);
		try {
			__connection.onError(reason);
		} catch (_:Dynamic) {}
		try {
			__connection.close();
		} catch (_:Dynamic) {}
	}
}

/**
	A call answered later, held to its session's `handlerTimeout`: settled
	once, by the future completing or the deadline passing, whichever is
	first. Both are told on the session's thread.

	A future that never completed held its place among the calls waiting,
	and its caller, for as long as the connection lasted. An object of its
	own rather than state its closures share, which hxcpp would box a field
	at a time -- and only for a session with a deadline.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.Future)
private class HandlerDeadline<T> {
	final session:RPCSession<Dynamic, Dynamic>;
	final future:Future<T>;
	final settle:Future<T>->Void;
	var settled:Bool = false;
	var timer:Int = TimerHandle.INVALID;

	public function new(session:RPCSession<Dynamic, Dynamic>, future:Future<T>, settle:Future<T>->Void, milliseconds:Int) {
		this.session = session;
		this.future = future;
		this.settle = settle;
		timer = Timer.setTimeout(milliseconds / 1000, expire);
	}

	/** The future has completed. **/
	public function finish():Void {
		if (settled) {
			return;
		}
		settled = true;
		if (timer != TimerHandle.INVALID) {
			Timer.clear(timer);
			timer = TimerHandle.INVALID;
		}
		session.__callsWaiting--;
		settle(future);
	}

	function expire():Void {
		timer = TimerHandle.INVALID;
		if (settled) {
			return;
		}
		settled = true;
		session.__callsWaiting--;
		settle(RPCSession.__handlerTimedOut());
	}
}

/**
	What a session made by `RPCSession.dial` holds before its first
	connection: never connected, sending nothing, closing nothing.
**/
private class Unconnected extends NetConnectionBase implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;

	final __uri:String;
	var __readEnabled:Bool = false;
	var __onData:ByteArrayInput->Void = null;
	var __onClose:Reason->Void = null;
	var __onError:Reason->Void = null;
	var __onReady:Void->Void = null;

	public function new(uri:String) {
		__uri = uri;
		protocol = TCP;
	}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		throw new IOError("Not connected to " + __uri);
	}

	public function close():Void {}

	inline function get_remoteAddress():String {
		return __uri;
	}

	inline function get_remotePort():Int {
		return 0;
	}

	inline function get_localAddress():String {
		return "";
	}

	inline function get_localPort():Int {
		return 0;
	}

	inline function get_connected():Bool {
		return false;
	}

	inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	inline function set_readEnabled(value:Bool):Bool {
		return __readEnabled = value;
	}

	inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __onData = value;
	}

	inline function get_onClose():Reason->Void {
		return __onClose;
	}

	inline function set_onClose(value:Reason->Void):Reason->Void {
		return __onClose = value;
	}

	inline function get_onError():Reason->Void {
		return __onError;
	}

	inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value;
	}

	inline function get_onReady():Void->Void {
		return __onReady;
	}

	inline function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value;
	}
}
