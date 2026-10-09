package crossbyte.rpc;

// Built for every target, JavaScript included: the portable suite runs RPC on
// Node and in a browser.

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.NetConnection;
import crossbyte.rpc._internal.RPCFrame;
import crossbyte.rpc._internal.RPCPendingCalls;
import crossbyte.rpc._internal.RPCReceiverCall;
import crossbyte.rpc._internal.RPCWire;

/**
	`RPCCommands` is the outbound stub surface for CrossByte RPC sessions.

	There are two supported ways to define command methods:

	- Manual mode: declare `@:rpc` methods directly on the subclass. One-way calls
	  return `Void` and request/response calls return `RPCResponse<T>`.
	- Contract mode: annotate the subclass with `@:rpcContract(YourContract)`. The
	  shared contract interface uses plain logical return types such as `String`,
	  `Int`, or `Void`, and the macro lifts non-`Void` returns into
	  `RPCResponse<T>` on the command side automatically.

	The shared contract should describe application logic, not transport wrappers.
	That means a contract method should be declared as `function getName(id:Int):String`
	rather than `function getName(id:Int):RPCResponse<String>`.

	A contract can extend other contracts, and its stubs then cover their methods
	too: an application's contract can be built from reusable ones. Two methods whose
	names hash to the same op fail the build, since on the wire they would be one.

	Example:

	```haxe
	interface PlayerContract {
		function jump():Void;
		function getName(id:Int):String;
	}

	@:rpcContract(PlayerContract)
	class PlayerCommands extends RPCCommands {}
	```
**/
@:autoBuild(crossbyte.rpc._internal.RPCCommandMacro.build())
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc._internal.RPCReceiverCall)
abstract class RPCCommands {
	@:noCompletion private var __nc:NetConnection;
	// The session these are bound to, for what it asks of every call.
	@:noCompletion private var __session:Null<RPCSession<Dynamic, Dynamic>> = null;
	@:noCompletion private var __requestIdSeed:Int = 0;
	@:noCompletion private var __pendingResponseId:Int = 0;
	@:noCompletion private var __pendingResponse:RPCResponse<Dynamic> = null;
	@:noCompletion private var __pendingResponses:Null<RPCPendingCalls> = null;
	// The calls kept for calls made with a receiver, waiting to be used
	// again: one is taken for each such call, and given back as it ends.
	@:noCompletion private var __freeCalls:Null<RPCReceiverCall> = null;
	@:noCompletion private var __freeCount:Int = 0;
	// Where the frame whose response is being read ends; the generated
	// readers read no further.
	@:noCompletion private var __frameEnd:Int = RPCWire.NO_FRAME_END;
	// The deadline `withTimeout` gave the next call, or -1 for none given;
	// and the one the request being made waits under, read as it is framed.
	@:noCompletion private var __nextTimeout:Int = -1;
	@:noCompletion private var __callTimeout:Int = 0;
	@:noCompletion private var __callTimeoutSent:Bool = false;

	/**
		Gives the next call made through these commands a deadline of its
		own, `milliseconds` from when it is made, in place of its session's
		`RPCSession.callTimeout`; `0` gives it none. Returns these commands,
		so the call follows:

		```haxe
		// Given commands:PlayerCommands, receiver:crossbyte.rpc.RPCStringReceiver.
		commands.withTimeout(2000).getNameThen(7, receiver);
		commands.withTimeout(500).getName(7).then(name -> trace(name));
		```

		Past it, a call made with a receiver is told `RPCFailure.TimedOut`, and
		an `RPCResponse` fails with an `RPCTimeoutError` as its `cause`. The
		deadline waits with the session's others, under one timer, so it
		allocates nothing. Only the next call takes it, one-way or not; a
		one-way call has no answer to wait for, and drops it.

		Each commands class returns its own type, so the call that follows is
		typed.
	**/
	public function withTimeout(milliseconds:Int):RPCCommands {
		__nextTimeout = milliseconds < 0 ? 0 : milliseconds;
		return this;
	}

	/**
		Built-in heartbeat/system ping. This stays on the commands surface and should not
		be declared inside shared RPC contract interfaces.
	**/
	abstract public function ping():Void;

	@:noCompletion abstract public function __rpc_handle_response(op:Int, requestId:Int, input:ByteArrayInput, failed:Bool):Void;

	/**
		The fingerprint of the methods these commands call, `RPCOps.fingerprint`
		of their ops: what a session's hello says it calls. Generated.
	**/
	@:noCompletion public function __rpc_fingerprint():Int {
		return 0;
	}

	/**
		The call for `op` waiting under `requestId`, which the stub took from
		`__nextRequestId` and framed its call with first: a call whose
		arguments cannot be framed throws before anything waits.
	**/
	@:noCompletion private function __createResponse<T>(op:Int, requestId:Int):RPCResponse<T> {
		final response = new RPCResponse<T>(requestId, op);
		response.__commands = this;
		__wait(cast response);
		return response;
	}

	/**
		The call for `op` waiting under `requestId` to tell `receiver`, as
		`__createResponse` makes one for a future: one of the calls these
		commands keep, so nothing is allocated for it. Its stub framed the
		call first, as a future's does.
	**/
	@:noCompletion private function __createReceiverCall(op:Int, requestId:Int, receiver:RPCReceiver):RPCReceiverCall {
		var call:Null<RPCReceiverCall> = __freeCalls;
		if (call != null) {
			__freeCalls = call.nextFree;
			call.nextFree = null;
			__freeCount--;
		} else {
			call = new RPCReceiverCall(this);
		}
		call.begin(requestId, op, receiver);
		__wait(call);
		return call;
	}

	/** The most calls kept for use again; past it, one that ends is let go. **/
	@:noCompletion private static inline final KEEP_CALLS:Int = 1024;

	/** `call` has ended, and is kept for the next call made with a receiver. **/
	@:noCompletion private function __recycle(call:RPCReceiverCall):Void {
		if (__freeCount < KEEP_CALLS) {
			call.nextFree = __freeCalls;
			__freeCalls = call;
			__freeCount++;
		}
	}

	/** What a stub throws for a receiver that is `null`, before anything is framed. **/
	@:noCompletion private static function __noReceiver(method:String):ArgumentError {
		return new ArgumentError("RPC call " + method + " was given no receiver");
	}

	/** Waits for `response`'s answer, under its request id, and under the session's deadline if it has one. **/
	@:noCompletion private function __wait(response:RPCResponse<Dynamic>):Void {
		final requestId:Int = response.requestId;
		if (__pendingResponse == null) {
			__pendingResponseId = requestId;
			__pendingResponse = response;
		} else {
			if (__pendingResponses == null) {
				__pendingResponses = new RPCPendingCalls();
			}
			__pendingResponses.put(requestId, response);
		}
		// Its deadline, as it was framed, in its session's heap of them; a
		// call without one arms nothing.
		final timeout:Int = __callTimeout;
		final session = __session;
		if (timeout > 0 && session != null) {
			__callTimeout = 0;
			session.__queueDeadline(response, timeout);
			response.__deadlineSent = __callTimeoutSent;
		}
	}

	/**
		What a call through commands no session has is told, rather than
		dereferencing a null connection, which on hxcpp in release is a crash.
	**/
	@:noCompletion private static inline final UNBOUND_MESSAGE:String = "RPC commands are not bound to a session";

	/**
		The frame a stub writes its call into, begun: its session's, or with
		no session (whose call fails as it is sent), one of its own.
	**/
	@:noCompletion private inline function __startFrame(room:Int, op:Int, requestId:Int):RPCFrame {
		// Inlined into every stub, so only a one-way call's usual way is
		// here; anything more (a request, a deadline given, no session) is a
		// call, which keeps a large commands class's methods small on the jvm.
		final session = __session;
		return requestId == 0 && session != null && __nextTimeout < 0 ? session.__takeFrame(room, 0, op, 0) : __startOtherFrame(room, op,
			requestId);
	}

	/** `__startFrame`'s other ways: a request, with the deadline it waits under; a call given `withTimeout`; commands with no session. **/
	@:noCompletion private function __startOtherFrame(room:Int, op:Int, requestId:Int):RPCFrame {
		final session = __session;
		final flags:Int = requestId != 0 ? RPCWire.FLAG_REQUEST : 0;
		// The deadline `withTimeout` gave, taken by this call, one-way or not.
		final timeout:Int = __nextTimeout;
		if (timeout >= 0) {
			__nextTimeout = -1;
		}
		if (session != null) {
			if (requestId != 0) {
				// Carried with the call to a peer that reads it, so its
				// handler knows when this side stops waiting.
				final waits:Int = timeout >= 0 ? timeout : session.callTimeout;
				__callTimeout = waits;
				__callTimeoutSent = waits > 0 && session.__readsCallControl();
				return session.__takeRequestFrame(room, flags, op, requestId, waits);
			}
			return session.__takeFrame(room, flags, op, requestId);
		}
		final frame = new RPCFrame(room);
		frame.begin(room, flags, op, requestId);
		return frame;
	}

	/**
		Gives back a frame `__startFrame` began whose arguments could not be
		written (a null inside an array or a structure), so that its
		session's next frame is written in it, not in a fresh one.
	**/
	@:noCompletion private function __dropFrame(framed:RPCFrame):Void {
		final session = __session;
		if (session != null) {
			session.__sent(framed);
		}
	}

	/**
		Sends a one-way call's frame, as its stub built it. On a connection
		that has ended it is dropped: nobody is told what becomes of a one-way
		call.

		@throws ArgumentError When the call is over its session's
		`RPCSession.maxFrameLength`: it went out without complaint and ended
		the connection on the other side.
		@throws IllegalOperationError When these commands have no session.
	**/
	@:noCompletion private function __sendCall(framed:RPCFrame):Void {
		final session = __session;
		if (session == null) {
			throw new IllegalOperationError(UNBOUND_MESSAGE);
		}
		session.__sendCallFrame(framed);
	}

	/**
		Sends a request's frame, as its stub built it, or fails `response` at
		once when it cannot go (see `RPCSession.__sendRequestFrame`) or
		these commands have no session.
	**/
	@:noCompletion private function __sendRequest<T>(response:RPCResponse<T>, framed:RPCFrame):Void {
		final session = __session;
		if (session == null) {
			__failResponse(response.requestId, UNBOUND_MESSAGE, new IllegalOperationError(UNBOUND_MESSAGE));
			return;
		}
		session.__sendRequestFrame(response, framed);
	}

	/**
		The call waiting under `requestId`, no longer waiting, to be answered
		by an answer for `op`; `null` if there is none, or if it was made
		for another op, which fails it.
	**/
	@:noCompletion private inline function __takeAnswered(op:Int, requestId:Int):Null<RPCResponse<Dynamic>> {
		var response = __takeResponse(requestId);
		if (response != null && response.op != op) {
			RPCSession.__answeredForAnotherOp(response, op);
			response = null;
		}
		return response;
	}

	// The answers the generated readers hand over, one for each kind of
	// receiver: a call made with one is told typed, and nothing is boxed for
	// it; a future is resolved with the answer.

	@:noCompletion private function __answerInt(op:Int, requestId:Int, value:Int):Void {
		final response = __takeAnswered(op, requestId);
		if (response == null) {
			return;
		}
		if (response.__pooled) {
			final call:RPCReceiverCall = cast response;
			final id:Int = call.requestId;
			final receiver:RPCIntReceiver = cast call.finish();
			try {
				receiver.onInt(id, value);
			} catch (error:Dynamic) {
				RPCReceiverCall.contained(error);
			}
		} else {
			(cast response : RPCResponse<Int>).__resolve(value);
		}
	}

	@:noCompletion private function __answerInt64(op:Int, requestId:Int, value:haxe.Int64):Void {
		final response = __takeAnswered(op, requestId);
		if (response == null) {
			return;
		}
		if (response.__pooled) {
			final call:RPCReceiverCall = cast response;
			final id:Int = call.requestId;
			final receiver:RPCInt64Receiver = cast call.finish();
			try {
				receiver.onInt64(id, value);
			} catch (error:Dynamic) {
				RPCReceiverCall.contained(error);
			}
		} else {
			(cast response : RPCResponse<haxe.Int64>).__resolve(value);
		}
	}

	@:noCompletion private function __answerFloat(op:Int, requestId:Int, value:Float, single:Bool):Void {
		final response = __takeAnswered(op, requestId);
		if (response == null) {
			return;
		}
		if (response.__pooled) {
			final call:RPCReceiverCall = cast response;
			final id:Int = call.requestId;
			final receiver:RPCFloatReceiver = cast call.finish();
			try {
				receiver.onFloat(id, value);
			} catch (error:Dynamic) {
				RPCReceiverCall.contained(error);
			}
		} else {
			#if hl
			// HashLink keeps a Single apart from a Float, boxed or not: a
			// Float32 future given a Float would read its bits as a Single.
			if (single) {
				(cast response : RPCResponse<Single>).__resolve((value : Single));
				return;
			}
			#end
			(cast response : RPCResponse<Float>).__resolve(value);
		}
	}

	@:noCompletion private function __answerBool(op:Int, requestId:Int, value:Bool):Void {
		final response = __takeAnswered(op, requestId);
		if (response == null) {
			return;
		}
		if (response.__pooled) {
			final call:RPCReceiverCall = cast response;
			final id:Int = call.requestId;
			final receiver:RPCBoolReceiver = cast call.finish();
			try {
				receiver.onBool(id, value);
			} catch (error:Dynamic) {
				RPCReceiverCall.contained(error);
			}
		} else {
			(cast response : RPCResponse<Bool>).__resolve(value);
		}
	}

	@:noCompletion private function __answerString(op:Int, requestId:Int, value:String):Void {
		final response = __takeAnswered(op, requestId);
		if (response == null) {
			return;
		}
		if (response.__pooled) {
			final call:RPCReceiverCall = cast response;
			final id:Int = call.requestId;
			final receiver:RPCStringReceiver = cast call.finish();
			try {
				receiver.onString(id, value);
			} catch (error:Dynamic) {
				RPCReceiverCall.contained(error);
			}
		} else {
			(cast response : RPCResponse<String>).__resolve(value);
		}
	}

	/** Any other answer, an object, which goes to a receiver or a future as it is. **/
	@:noCompletion private function __answerValue<T>(op:Int, requestId:Int, value:T):Void {
		final response = __takeAnswered(op, requestId);
		if (response != null) {
			// A call made with a receiver takes it through RPCReceiverCall's
			// `__resolve`, as an `RPCValueReceiver`.
			(cast response : RPCResponse<T>).__resolve(value);
		}
	}

	/**
		An error answer to the call `requestId`, from the generated reader,
		`input` at its message: the call fails with it, typed by the code of
		what refused it. A refusal the other side's session made is told with
		its message as this side has it, so no string is read for one. One
		that does not read fails its call, and the connection carries on.
	**/
	@:noCompletion private function __rejectFrom(op:Int, requestId:Int, input:ByteArrayInput):Void {
		var message:String = null;
		var code:Int = RPCWire.REFUSED_BY_HANDLER;
		try {
			code = RPCWire.refusalCode(input, __frameEnd);
			message = code != RPCWire.REFUSED_BY_HANDLER ? RPCWire.refusalMessage(code) : input.readVarUTF();
			RPCWire.requireWithin(input, __frameEnd);
		} catch (error:Dynamic) {
			__rejectUnreadableResponse(op, requestId, error);
			return;
		}
		__rejectResponse(op, requestId, message, code);
	}

	/**
		Fails a waiting call with the error the other side answered it with,
		`message`, refused as `code` says (`RPCWire.REFUSED_*`). The other
		side meant this caller to see it, so the failure's cause is an
		`RPCError`: a handler here answering with this response (forwarding
		it) passes the refusal on, as it would one it threw.
	**/
	@:noCompletion private function __rejectResponse(op:Int, requestId:Int, message:String, code:Int):Void {
		final response = __takeAnswered(op, requestId);
		if (response == null) {
			return;
		}
		if (response.__pooled) {
			// Told with the failure, and no RPCError made to carry it: a
			// refusal the session made is a single value.
			final call:RPCReceiverCall = cast response;
			final id:Int = call.requestId;
			RPCReceiverCall.tell(call.finish(), id, RPCReceiverCall.refusal(code, message));
			return;
		}
		response.__fail(message, RPCSession.__refusalError(message, code));
	}

	@:noCompletion private function __failResponse(requestId:Int, message:String, cause:Null<Dynamic>):Void {
		final response = __takeResponse(requestId);
		if (response == null) {
			return;
		}
		response.__fail(message, cause);
	}

	/** The call waiting under `requestId`, no longer waiting; `null` if there is none. **/
	@:noCompletion private function __takeResponse(requestId:Int):RPCResponse<Dynamic> {
		var response:RPCResponse<Dynamic> = null;
		if (__pendingResponse != null && requestId == __pendingResponseId) {
			response = __pendingResponse;
			__pendingResponse = null;
			__pendingResponseId = 0;
		} else if (__pendingResponses != null) {
			response = __pendingResponses.take(requestId);
		}
		return response;
	}

	/** A response this side cannot read: its own failure, not the other side's answer. **/
	@:noCompletion private function __rejectUnknownResponse(requestId:Int, op:Int):Void {
		__failResponse(requestId, 'Unsupported RPC response op: $op', null);
	}

	/**
		An answer whose value did not read (it ran past its frame, or named
		more than its frame holds): the call it answers fails saying so, and the
		connection carries on, where it ended. See
		`RPCSession.onUnreadableFrame`.
	**/
	@:noCompletion private function __rejectUnreadableResponse(op:Int, requestId:Int, error:Dynamic):Void {
		final response = __takeResponse(requestId);
		final session = __session;
		if (session != null) {
			session.__unreadableAnswer(op, requestId, response, error);
		} else if (response != null) {
			response.__fail("RPC answer could not be read: " + Std.string(error), error);
		}
	}

	@:noCompletion private function __nextRequestId():Int {
		do {
			// `| 0` because the guard below is the overflow handler, and it
			// only fires if the increment actually wraps. It does on a target
			// whose Int is 32 bits; on JavaScript an Int is a double, so
			// 0x7FFFFFFF + 1 is 2147483648: positive, past the guard, and
			// past the width of the field this id is written to on the wire.
			// The id and the pending-response key would then stop agreeing,
			// and the call would wait for a reply it could not match.
			__requestIdSeed = (__requestIdSeed + 1) | 0;

			if (__requestIdSeed <= 0) {
				__requestIdSeed = 1;
			}
		} while ((__requestIdSeed == __pendingResponseId)
			|| (__pendingResponses != null && __pendingResponses.has(__requestIdSeed)));

		return __requestIdSeed;
	}

	/**
		Rejects and clears every outstanding `RPCResponse` with the given reason.

		Used to drain pending request/response calls when the underlying session is
		stopped or the connection closes, so callers are not left waiting forever for
		a reply that can no longer arrive. Must only be called on the owning thread.
	**/
	@:noCompletion private function __failAllPending(message:String, ?cause:Dynamic):Void {
		final pending = __pendingResponse;
		if (pending != null) {
			__pendingResponse = null;
			__pendingResponseId = 0;
			pending.__fail(message, cause);
		}
		final waiting = __pendingResponses;
		if (waiting != null) {
			__pendingResponses = null;
			waiting.failAll(message, cause);
		}
	}
}
