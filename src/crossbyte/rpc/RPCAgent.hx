package crossbyte.rpc;

import crossbyte.io.ByteArray;
import haxe.Rest;
import crossbyte.net.INetConnection;
import crossbyte.events.EventDispatcher;
import haxe.ds.StringMap;

class RPCAgent extends EventDispatcher {
	public var connection(get, never):INetConnection;

	private var __connection:INetConnection;

	private inline function get_connection():INetConnection {
		return __connection;
	}

	public function new(connection:INetConnection) {
		super();

		__connection = connection;
	}

	/**
	 * Calls a remote procedure manually.
	 * 
	 * @param command The name of the RPC command to invoke.
	 * @param args Arguments for the command.
	 */
	public function call(command:String, ...args):Void {
		var packet:ByteArray = new ByteArray();
		packet.writeUTF(command);
		for (arg in args) {
			packet.writeUTF(Std.string(arg));
		}
		__connection.send(packet);
	}

	public function setHeader<T>(params:StringMap<T>):Void {}
    
}
