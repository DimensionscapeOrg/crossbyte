package crossbyte.rpc;

// Not built for the browser: the command surface is bound to RPCSession.

import crossbyte.io.ByteArrayInput;
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
abstract class RPCCommands {
	@:noCompletion private var __nc:NetConnection;
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

	@:noCompletion private function __createResponse<T>(op:Int):RPCResponse<T> {
		final requestId:Int = __nextRequestId();
		final response = new RPCResponse<T>(requestId, op);
		if (__pendingResponse == null) {
			__pendingResponseId = requestId;
			__pendingResponse = cast response;
		} else {
			if (__pendingResponses == null) {
				__pendingResponses = new IntMap();
			}
			__pendingResponses.set(requestId, cast response);
		}
		return response;
	}

	@:noCompletion private function __resolveResponse<T>(requestId:Int, value:T):Void {
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
		if (response == null) {
			return;
		}
		(cast response : RPCResponse<T>).__resolve(value);
	}

	@:noCompletion private function __rejectResponse(requestId:Int, message:String):Void {
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
		if (response == null) {
			return;
		}
		response.__reject(message);
	}

	@:noCompletion private function __rejectUnknownResponse(requestId:Int, op:Int):Void {
		__rejectResponse(requestId, 'Unsupported RPC response op: $op');
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
