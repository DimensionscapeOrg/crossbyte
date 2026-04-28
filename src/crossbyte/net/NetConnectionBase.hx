package crossbyte.net;

import crossbyte.io.ByteArray;

abstract class NetConnectionBase {
	public var protocol:Protocol;
	public var inTimestamp:Float = 0.0;
	public var outTimestamp:Float = 0.0;

	public abstract function expose():Transport;
	public abstract function send(data:ByteArray):Void;
	public abstract function close():Void;
}
