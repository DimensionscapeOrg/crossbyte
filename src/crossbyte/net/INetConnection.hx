package crossbyte.net;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.Protocol;
import crossbyte.io.ByteArray;
interface INetConnection {
    public var protocol:Protocol;
    public var connected(get, never):Bool;
    public var inTimestamp(default, null):Float;
    public var outTimestamp(default, null):Float;
    public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;
    public function expose():Transport;
    public function send(data:ByteArray):Void;
    public function close():Void;
    public function startReceiving():Void;
    public function stopReceiving():Void;
}