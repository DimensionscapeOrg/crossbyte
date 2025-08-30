package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.net.NetConnection;

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
	private var __nc:NetConnection;

	abstract public function ping():Void;
}
