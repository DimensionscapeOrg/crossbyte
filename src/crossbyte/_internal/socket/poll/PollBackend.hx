package crossbyte._internal.socket.poll;

import sys.net.Socket;

interface PollBackend {
	public var capacity(get, never):Int;
	public var readIndexes(default, null):Array<Int>;
	public var writeIndexes(default, null):Array<Int>;
	public function prepare(read:Array<Socket>, write:Array<Socket>):Void;
	public function events(timeout:Float):Void;
	public function dispose():Void;
}
