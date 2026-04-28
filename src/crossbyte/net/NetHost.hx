package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.net.Endpoint.parseURL;

@:forward
abstract NetHost(INetHost) from INetHost to INetHost {
	public inline function new(uri:String, ?onAccept:INetConnection->Void, ?onDisconnect:(INetConnection, Reason) -> Void, ?onError:Reason->Void,
			startListening:Bool = false):Void {
		var endpoint:Endpoint = parseURL(uri);
		var secureWebSocket = __isSecureWebSocketUri(uri);
		this = switch (endpoint.protocol) {
			case TCP:
				var server = new ServerSocket();
				server.bind(endpoint.port, endpoint.address);
				fromServerSocket(server, onAccept, onDisconnect, onError);
			case WEBSOCKET:
				var server = new ServerWebSocket(secureWebSocket);
				server.bind(endpoint.port, endpoint.address);
				fromServerWebSocket(server, onAccept, onDisconnect, onError);
			case RUDP:
				var server = new ReliableDatagramServerSocket();
				server.bind(endpoint.port, endpoint.address);
				fromReliableDatagramServerSocket(server, onAccept, onDisconnect, onError);
			default:
				throw "Protocol error";
		}

		if (startListening) {
			this.listen();
		}
	}

	public static inline function fromServerSocket(server:ServerSocket, ?onAccept:INetConnection->Void,
			?onDisconnect:(INetConnection, Reason) -> Void, ?onError:Reason->Void):NetHost {
		var host:TCPHost = new TCPHost(server);
		host.onAccept = onAccept;
		host.onDisconnect = onDisconnect;
		host.onError = onError;
		return host;
	}

	public static inline function fromServerWebSocket(server:ServerWebSocket, ?onAccept:INetConnection->Void,
			?onDisconnect:(INetConnection, Reason) -> Void, ?onError:Reason->Void):NetHost {
		var host:WebSocketHost = new WebSocketHost(server);
		host.onAccept = onAccept;
		host.onDisconnect = onDisconnect;
		host.onError = onError;
		return host;
	}

	public static inline function fromReliableDatagramServerSocket(server:ReliableDatagramServerSocket, ?onAccept:INetConnection->Void,
			?onDisconnect:(INetConnection, Reason) -> Void, ?onError:Reason->Void):NetHost {
		var host:RUDPHost = new RUDPHost(server);
		host.onAccept = onAccept;
		host.onDisconnect = onDisconnect;
		host.onError = onError;
		return host;
	}

	private static inline function __isSecureWebSocketUri(uri:String):Bool {
		if (uri == null) {
			return false;
		}

		var normalized = StringTools.trim(uri).toLowerCase();
		return StringTools.startsWith(normalized, "wss://");
	}
}

private typedef DisconnectHandler = (INetConnection, Reason) -> Void;

private class BaseNetHost<TServer:ServerSocket> implements INetHost {
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var isRunning(get, null):Bool = false;
	public var protocol(default, null):Protocol;
	public var maxConnections:Int = 0;
	public var onAccept(get, set):INetConnection->Void;
	public var onDisconnect(get, set):DisconnectHandler;
	public var onError(get, set):Reason->Void;

	@:noCompletion private var __server:TServer;
	@:noCompletion private var __onAccept:INetConnection->Void = __noopAccept;
	@:noCompletion private var __onDisconnect:DisconnectHandler = __noopDisconnect;
	@:noCompletion private var __onError:Reason->Void = __noopError;
	@:noCompletion private var __listeningHooked:Bool = false;

	@:noCompletion private inline function new(server:TServer, protocol:Protocol) {
		__server = server;
		this.protocol = protocol;
	}

	public function bind(address:String, port:Int):Void {
		__server.bind(port, address);
	}

	public function listen():Void {
		if (isRunning) {
			__ensureListeningHooks();
			return;
		}

		__server.listen(maxConnections);
		__ensureListeningHooks();
	}

	public function close():Void {
		__removeListeningHooks();
		__server.close();
	}

	@:noCompletion private function __ensureListeningHooks():Void {
		if (__listeningHooked) {
			return;
		}

		__listeningHooked = true;
		__server.addEventListener(ServerSocketConnectEvent.CONNECT, __onConnect);
		__server.addEventListener(Event.CLOSE, __onServerClose);
	}

	@:noCompletion private function __removeListeningHooks():Void {
		if (!__listeningHooked) {
			return;
		}

		__listeningHooked = false;
		__server.removeEventListener(ServerSocketConnectEvent.CONNECT, __onConnect);
		__server.removeEventListener(Event.CLOSE, __onServerClose);
	}

	@:noCompletion private inline function get_isRunning():Bool {
		return __server.listening;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __server.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __server.localPort;
	}

	@:noCompletion private inline function get_onAccept():INetConnection->Void {
		return __onAccept;
	}

	@:noCompletion private inline function set_onAccept(value:INetConnection->Void):INetConnection->Void {
		return __onAccept = (value != null) ? value : __noopAccept;
	}

	@:noCompletion private inline function get_onDisconnect():DisconnectHandler {
		return __onDisconnect;
	}

	@:noCompletion private inline function set_onDisconnect(value:DisconnectHandler):DisconnectHandler {
		return __onDisconnect = (value != null) ? value : __noopDisconnect;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = (value != null) ? value : __noopError;
	}

	@:noCompletion private function __onConnect(event:ServerSocketConnectEvent):Void {
		var connection = __wrapConnection(event.socket);
		__onAccept(connection);
	}

	@:noCompletion private function __onServerClose(_event:Event):Void {
		__removeListeningHooks();
		__onError(Reason.Closed);
	}

	@:noCompletion private function __wrapConnection(socket:Socket):INetConnection {
		return __bindConnectionCallbacks(NetConnection.fromSocket(socket));
	}

	@:noCompletion private function __bindConnectionCallbacks(connection:NetConnection):INetConnection {
		var wrapped:INetConnection = connection;
		var forwarded:NetConnection = connection;
		forwarded.onClose = reason -> __onDisconnect(wrapped, reason);
		forwarded.onError = reason -> __onError(reason);
		return wrapped;
	}

	@:noCompletion private static inline function __noopAccept(_:INetConnection):Void {}

	@:noCompletion private static inline function __noopDisconnect(_:INetConnection, _:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}

@:allow(crossbyte.net.NetHost)
private class TCPHost extends BaseNetHost<ServerSocket> {
	@:noCompletion private inline function new(server:ServerSocket) {
		super(server, TCP);
	}
}

@:allow(crossbyte.net.NetHost)
private class WebSocketHost extends BaseNetHost<ServerWebSocket> {
	@:noCompletion private inline function new(server:ServerWebSocket) {
		super(server, WEBSOCKET);
	}

	override private function __wrapConnection(socket:Socket):INetConnection {
		if (Std.isOfType(socket, WebSocket)) {
			return __bindConnectionCallbacks(NetConnection.fromWebSocket(cast socket));
		}

		return super.__wrapConnection(socket);
	}
}

@:allow(crossbyte.net.NetHost)
private class RUDPHost implements INetHost {
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var isRunning(get, never):Bool;
	public var protocol(default, null):Protocol = RUDP;
	public var maxConnections:Int = 0;
	public var onAccept(get, set):INetConnection->Void;
	public var onDisconnect(get, set):DisconnectHandler;
	public var onError(get, set):Reason->Void;

	@:noCompletion private var __server:ReliableDatagramServerSocket;
	@:noCompletion private var __onAccept:INetConnection->Void = __noopAccept;
	@:noCompletion private var __onDisconnect:DisconnectHandler = __noopDisconnect;
	@:noCompletion private var __onError:Reason->Void = __noopError;
	@:noCompletion private var __listeningHooked:Bool = false;

	@:noCompletion private inline function new(server:ReliableDatagramServerSocket) {
		__server = server;
	}

	public function bind(address:String, port:Int):Void {
		__server.bind(port, address);
	}

	public function listen():Void {
		if (!isRunning) {
			__server.listen();
		}
		__ensureListeningHooks();
	}

	public function close():Void {
		__removeListeningHooks();
		__server.close();
	}

	@:noCompletion private function __ensureListeningHooks():Void {
		if (__listeningHooked) {
			return;
		}

		__listeningHooked = true;
		__server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, __onConnect);
		__server.addEventListener(Event.CLOSE, __onServerClose);
	}

	@:noCompletion private function __removeListeningHooks():Void {
		if (!__listeningHooked) {
			return;
		}

		__listeningHooked = false;
		__server.removeEventListener(ReliableDatagramSocketConnectEvent.CONNECT, __onConnect);
		__server.removeEventListener(Event.CLOSE, __onServerClose);
	}

	@:noCompletion private inline function get_localAddress():String {
		return __server.localAddress;
	}

	@:noCompletion private inline function get_localPort():Int {
		return __server.localPort;
	}

	@:noCompletion private inline function get_isRunning():Bool {
		return __server.listening;
	}

	@:noCompletion private inline function get_onAccept():INetConnection->Void {
		return __onAccept;
	}

	@:noCompletion private inline function set_onAccept(value:INetConnection->Void):INetConnection->Void {
		return __onAccept = (value != null) ? value : __noopAccept;
	}

	@:noCompletion private inline function get_onDisconnect():DisconnectHandler {
		return __onDisconnect;
	}

	@:noCompletion private inline function set_onDisconnect(value:DisconnectHandler):DisconnectHandler {
		return __onDisconnect = (value != null) ? value : __noopDisconnect;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = (value != null) ? value : __noopError;
	}

	@:noCompletion private function __onConnect(event:ReliableDatagramSocketConnectEvent):Void {
		var connection = NetConnection.fromReliableDatagramSocket(event.socket);
		var wrapped:INetConnection = connection;
		connection.onClose = reason -> __onDisconnect(wrapped, reason);
		connection.onError = reason -> __onError(reason);
		__onAccept(wrapped);
	}

	@:noCompletion private function __onServerClose(_event:Event):Void {
		__removeListeningHooks();
		__onError(Reason.Closed);
	}

	@:noCompletion private static inline function __noopAccept(_:INetConnection):Void {}

	@:noCompletion private static inline function __noopDisconnect(_:INetConnection, _:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}
