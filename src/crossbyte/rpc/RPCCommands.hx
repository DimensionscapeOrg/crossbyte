package crossbyte.rpc;

// Built for every target, JavaScript included: the portable suite runs RPC on
// Node and in a browser.

import crossbyte.errors.IllegalOperationError;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.net.NetConnection;
import crossbyte.rpc._internal.RPCWire;
import haxe.ds.IntMap;

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
abstract class RPCCommands {
	@:noCompletion private var __nc:NetConnection;
	// The session these are bound to, for what it asks of every call.
	@:noCompletion private var __session:Null<RPCSession<Dynamic, Dynamic>> = null;
	@:noCompletion private var __requestIdSeed:Int = 0;
	@:noCompletion private var __pendingResponseId:Int = 0;
	@:noCompletion private var __pendingResponse:RPCResponse<Dynamic> = null;
	@:noCompletion private var __pendingResponses:Null<IntMap<RPCResponse<Dynamic>>> = null;
	// Where the frame whose response is being read ends; the generated
	// readers read no further.
	@:noCompletion private var __frameEnd:Int = RPCWire.NO_FRAME_END;

	/**
		Built-in heartbeat/system ping. This stays on the commands surface and should not
		be declared inside shared RPC contract interfaces.
	**/
	abstract public function ping():Void;

	@:noCompletion abstract public function __rpc_handle_response(op:Int, requestId:Int, input:ByteArrayInput, failed:Bool):Void;

	/**
		The call for `op` waiting under `requestId`, which the stub took from
		`__nextRequestId` and framed its call with first: a call whose
		arguments cannot be framed throws before anything waits.
	**/
	@:noCompletion private function __createResponse<T>(op:Int, requestId:Int):RPCResponse<T> {
		final response = new RPCResponse<T>(requestId, op);
		response.__commands = this;
		if (__pendingResponse == null) {
			__pendingResponseId = requestId;
			__pendingResponse = cast response;
		} else {
			if (__pendingResponses == null) {
				__pendingResponses = new IntMap();
			}
			__pendingResponses.set(requestId, cast response);
		}
		// The session's deadline for every call, if it has one; a call
		// without one arms nothing.
		final session = __session;
		if (session != null && session.callTimeout > 0) {
			response.__arm(session.callTimeout);
		}
		return response;
	}

	/**
		Completes the call waiting under `requestId` with `value`, the answer
		to a call for `op` -- if that call was for `op`. A response is matched
		by its id and checked by its op: see `RPCSession.__answeredForAnotherOp`.
	**/
	/**
		What a call through commands no session has is told. They dereferenced
		a null connection, which on hxcpp in release is a crash.
	**/
	@:noCompletion private static inline final UNBOUND_MESSAGE:String = "RPC commands are not bound to a session";

	/**
		Sends a one-way call's frame, as its stub built it. On a connection
		that has ended it is dropped: nobody is told what becomes of a one-way
		call.

		@throws ArgumentError When the call is over its session's
		`RPCSession.maxFrameLength`: it went out without complaint and ended
		the connection on the other side.
		@throws IllegalOperationError When these commands have no session.
	**/
	@:noCompletion private function __sendCall(framed:ByteArrayOutput):Void {
		final session = __session;
		if (session == null) {
			throw new IllegalOperationError(UNBOUND_MESSAGE);
		}
		session.__sendCallFrame(framed);
	}

	/**
		Sends a request's frame, as its stub built it, or fails `response` at
		once when it cannot go -- see `RPCSession.__sendRequestFrame` -- or
		these commands have no session.
	**/
	@:noCompletion private function __sendRequest<T>(response:RPCResponse<T>, framed:ByteArrayOutput):Void {
		final session = __session;
		if (session == null) {
			__failResponse(response.requestId, UNBOUND_MESSAGE, new IllegalOperationError(UNBOUND_MESSAGE));
			return;
		}
		session.__sendRequestFrame(response, framed);
	}

	@:noCompletion private function __resolveResponse<T>(op:Int, requestId:Int, value:T):Void {
		final response = __takeResponse(requestId);
		if (response == null) {
			return;
		}
		if (response.op != op) {
			RPCSession.__answeredForAnotherOp(response, op);
			return;
		}
		(cast response : RPCResponse<T>).__resolve(value);
	}

	/**
		Fails a waiting call with the error the other side answered it with.
		Its handler meant this caller to see it, so the failure's cause is an
		`RPCError`: a handler here answering with this response -- forwarding
		it -- passes the message on, as it would one it threw.
	**/
	@:noCompletion private function __rejectResponse(op:Int, requestId:Int, message:String):Void {
		final response = __takeResponse(requestId);
		if (response == null) {
			return;
		}
		if (response.op != op) {
			RPCSession.__answeredForAnotherOp(response, op);
			return;
		}
		response.__fail(message, new RPCError(message));
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
			response = __pendingResponses.get(requestId);
			if (response != null) {
				__pendingResponses.remove(requestId);
			}
		}
		return response;
	}

	/** A response this side cannot read: its own failure, not the other side's answer. **/
	@:noCompletion private function __rejectUnknownResponse(requestId:Int, op:Int):Void {
		__failResponse(requestId, 'Unsupported RPC response op: $op', null);
	}

	@:noCompletion private function __nextRequestId():Int {
		do {
			// `| 0` because the guard below is the overflow handler, and it
			// only fires if the increment actually wraps. It does on a target
			// whose Int is 32 bits; on JavaScript an Int is a double, so
			// 0x7FFFFFFF + 1 is 2147483648 -- positive, past the guard, and
			// past the width of the field this id is written to on the wire.
			// The id and the pending-response key would then stop agreeing,
			// and the call would wait for a reply it could not match.
			__requestIdSeed = (__requestIdSeed + 1) | 0;

			if (__requestIdSeed <= 0) {
				__requestIdSeed = 1;
			}
		} while ((__requestIdSeed == __pendingResponseId)
			|| (__pendingResponses != null && __pendingResponses.exists(__requestIdSeed)));

		return __requestIdSeed;
	}

	/**
		Rejects and clears every outstanding `RPCResponse` with the given reason.

		Used to drain pending request/response calls when the underlying session is
		stopped or the connection closes, so callers are not left waiting forever for
		a reply that can no longer arrive. Must only be called on the owning thread.
	**/
	@:noCompletion private function __failAllPending(message:String):Void {
		final pending = __pendingResponse;
		if (pending != null) {
			__pendingResponse = null;
			__pendingResponseId = 0;
			pending.__reject(message);
		}
		final map = __pendingResponses;
		if (map != null) {
			__pendingResponses = null;
			for (response in map) {
				response.__reject(message);
			}
		}
	}
}
