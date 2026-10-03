package crossbyte.net;

import crossbyte.core.CrossByte;
#if target.threaded
import sys.thread.Thread;
#end

#if target.threaded
/** Where a connection was announced, and the connection. **/
@:access(crossbyte.core.CrossByte)
class Arrival {
	public var runtime:CrossByte;
	public var thread:Thread;
	public var socket:Socket;

	public function new(runtime:CrossByte, thread:Thread, socket:Socket) {
		this.runtime = runtime;
		this.thread = thread;
		this.socket = socket;
	}

	/** Taken inside a `connect` listener: the runtime and thread it ran on. **/
	public static function of(socket:Socket):Arrival {
		return new Arrival(CrossByte.__currentOrNull(), Thread.current(), socket);
	}
}
#end
