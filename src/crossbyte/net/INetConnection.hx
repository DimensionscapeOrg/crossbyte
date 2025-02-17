package crossbyte.net;
import crossbyte.net.Protocol;
import crossbyte.io.ByteArray;
interface INetConnection {
    public var protocol:Protocol;
    public var connected:Bool;
    public function send(data:ByteArray):Void;
    public function read():ByteArray;
    public function close():Void;
}