package crossbyte.net;

import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.Endpoint.parseURL;

@:forward
abstract NetHost(INetHost) from INetHost to INetHost {
	public inline function new(uri:String, ?onAccept:INetConnection->Void, ?onDisconnect:(INetConnection, Reason) -> Void, ?onError:Reason->Void,
			startListening:Bool = false):Void {
		var endpoint:Endpoint = parseURL(uri);
		var protocol:Protocol = endpoint.protocol;
		this = switch (protocol) {
			case TCP:
				var server:ServerSocket = new ServerSocket();
				server.bind(endpoint.port, endpoint.address);
				var nh:NetHost = new TCPHost(server);
				nh.onAccept = onAccept;
				nh.onDisconnect = onDisconnect;
				nh.onError = onError;
				if (startListening) {
					nh.listen();
				}
				// return
				nh;
			default:
				throw('Protocol error');
				null;
		}
	}
}

@:allow(crossbyte.net.NetHost)
@:noCompletion private class TCPHost implements INetHost {
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var isRunning(get, null):Bool = false;
	public var protocol(default, null):Protocol = TCP;
	public var maxConnections:Int = 0;
	public var onAccept(get, set):INetConnection->Void;
	public var onDisconnect(get, set):(INetConnection, Reason) -> Void;
	public var onError(get, set):Reason->Void;

	@:noCompletion private var __server:ServerSocket;
	@:noCompletion private var __onAccept:INetConnection->Void;
	@:noCompletion private var __onDisconnect:(INetConnection, Reason) -> Void;
	@:noCompletion private var __onError:Reason->Void;
	@:noCompletion private var __lifecycleReady:Bool = false;

	@:noCompletion private inline function get_isRunning():Bool {
		return __server.listening;
	}

	@:noCompletion private inline function get_localAddress():String {
		return this.__server.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return this.__server.localPort;
	}

	@:noCompletion private inline function get_onAccept():INetConnection->Void {
		return __onAccept;
	}

	@:noCompletion private inline function set_onAccept(value:INetConnection->Void):INetConnection->Void {
		return __onAccept = value;
	}

	@:noCompletion private inline function get_onDisconnect():(INetConnection, Reason) -> Void {
		return __onDisconnect;
	}

	@:noCompletion private inline function set_onDisconnect(value:(INetConnection, Reason) -> Void):(INetConnection, Reason) -> Void {
		return __onDisconnect = value;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value;
	}

	@:noCompletion private inline function new(server:ServerSocket) {
		this.__server = server;
	}

	public inline function bind(address:String, port:Int):Void {
		__server.bind(port, address);
	}

	public inline function listen():Void {
		__server.listen(maxConnections);
        __server.addEventListener(ServerSocketConnectEvent.CONNECT, __onConnect);
	}

	public function close():Void {
		__server.close();
	}

    private inline function __onConnect(e:ServerSocketConnectEvent):Void{
        var socket:Socket = e.socket;
        var nc:INetConnection = NetConnection.fromSocket(socket);
        onAccept(nc);
    }
}
/* @:noCompletion private class WebSocketHost implements INetHost {
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var isRunning(default, null):Bool;

	public function bind(address:String, port:Int):Void;

	public function listen():Void;

	public function close():Void;
}*/
