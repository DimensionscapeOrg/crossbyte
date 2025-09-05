package crossbyte.net;

interface INetHost {
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var isRunning(get, null):Bool;
	public var protocol(default, null):Protocol;
	public var maxConnections:Int;
	public var onAccept(get, set):INetConnection->Void;
	public var onDisconnect(get, set):(INetConnection, Reason) -> Void;
	public var onError(get, set):Reason->Void;
	public function bind(address:String, port:Int):Void;
	public function listen():Void;
	public function close():Void;
}
