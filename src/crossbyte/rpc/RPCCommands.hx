package crossbyte.rpc;

import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import haxe.ds.IntMap;

/**
 * `RPCCommands` is a base class for defining networked Remote Procedure Calls (RPC) 
 * in your application. By annotating methods with `@:rpc`, you enable automatic 
 * generation of network-ready functions for client-server communication.
 * 
 * ## Defining RPC Methods:
 * To create a set of remote commands, extend `RPCCommands` and annotate methods with `@:rpc`:
 * 
 * 
 * ## Important Notes:
 * - Only methods marked with `@:rpc` are exposed for remote calling.
 * - Each method automatically serializes arguments and sends them through the network.
 * - `RPCCommands` requires a `NetConnection` to be provided internally.
 * 
 * ## Best Practices:
 * - Use descriptive method names to clearly identify remote operations.
 * - Keep method signatures minimal for efficient transmission.
 * - Avoid large data structures as arguments to reduce network overhead.
 * 
 * ## Example Use Case:
 * ```haxe
 * class PlayerCommands extends RPCCommands {
 *     @:rpc
 *     public inline function jump():Void{}
 * 
 *     @:rpc
 *     public inline function movePlayer(x:Int, y:Int):Void{}
 * }
 * 
 * rpcAgent.commands = new PlayerCommands();
 * playerCommands.jump();
 * playerCommands.movePlayer(x, y);
 * ```
 */
@:autoBuild(crossbyte.rpc._internal.RPCCommandMacro.build())
abstract class RPCCommands {
	@:noCompletion private var __nc:INetConnection;
	@:noCompletion private var __requestIdSeed:Int = 0;
	@:noCompletion private var __pendingResponses:IntMap<RPCResponse<Dynamic>> = new IntMap();

	abstract public function ping():Void;

	@:noCompletion abstract public function __rpc_handle_response(op:Int, requestId:Int, input:ByteArrayInput, failed:Bool):Void;

	@:noCompletion private function __createResponse<T>(op:Int):RPCResponse<T> {
		final requestId:Int = __nextRequestId();
		final response = new RPCResponse<T>(requestId, op);
		__pendingResponses.set(requestId, cast response);
		return response;
	}

	@:noCompletion private function __resolveResponse<T>(requestId:Int, value:T):Void {
		final response:RPCResponse<Dynamic> = __pendingResponses.get(requestId);
		if (response == null) {
			return;
		}
		__pendingResponses.remove(requestId);
		(cast response : RPCResponse<T>).__resolve(value);
	}

	@:noCompletion private function __rejectResponse(requestId:Int, message:String):Void {
		final response:RPCResponse<Dynamic> = __pendingResponses.get(requestId);
		if (response == null) {
			return;
		}
		__pendingResponses.remove(requestId);
		response.__reject(message);
	}

	@:noCompletion private function __rejectUnknownResponse(requestId:Int, op:Int):Void {
		__rejectResponse(requestId, 'Unsupported RPC response op: $op');
	}

	@:noCompletion private function __nextRequestId():Int {
		do {
			__requestIdSeed++;
			if (__requestIdSeed <= 0) {
				__requestIdSeed = 1;
			}
		} while (__pendingResponses.exists(__requestIdSeed));

		return __requestIdSeed;
	}
}
