package crossbyte.rpc;

import crossbyte.rpc.Responder;
import crossbyte.io.ByteArray;
import haxe.Rest;
import crossbyte.net.INetConnection;
import crossbyte.events.EventDispatcher;
import haxe.ds.StringMap;

class RPCAgent extends EventDispatcher {
	public var connection(get, never):INetConnection;

	private var __connection:INetConnection;
    private var __commandFunctions:StringMap<Function>;

	private inline function get_connection():INetConnection {
		return __connection;
	}

	public function new(connection:INetConnection) {
		super();
        __commandFunctions = new StringMap();
		__connection = connection;
	}

	/**
	 * Calls a remote procedure manually.
	 * 
	 * @param command The name of the RPC command to invoke.
	 * @param args Arguments for the command.
	 */
	public function call(command:String, ...args):Void {
		__call(command, args);
	}

    public inline function __call(command:String, args:Array<Dynamic>):Void{
        var packet:ByteArray = new ByteArray();
		packet.writeUTF(command);
		for (arg in args) {
			packet.writeUTF(Std.string(arg));
		}
		__connection.send(packet);
    }

	public function request(command:String, responder:Responder, ...args):Responder {
        if(responder == null){
            responder = new Responder();
        }

        __call(command, args);

        return responder;
    }

    public function register(command:String, func:Function):Void{
        __commandFunctions.set(command, func);
    }

    public function deregister(command:String):Void{
        __commandFunctions.remove(command);
    }

    public function clearCommands():Void{
        __commandFunctions.clear();
    }

	public function setHeader<T>(params:StringMap<T>):Void {}
}
