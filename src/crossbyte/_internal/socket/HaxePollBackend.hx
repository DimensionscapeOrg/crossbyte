package crossbyte._internal.socket;

import crossbyte._internal.socket.poll.PollBackend;
import sys.net.Socket;

#if cpp
import cpp.net.Poll;
#end

class HaxePollBackend implements PollBackend {
	private var __capacity:Int;
	private var __read:Array<Socket>;
	private var __write:Array<Socket>;

	#if cpp
	private var __poll:Poll;
	#end

	public var capacity(get, never):Int;
	public var readIndexes(default, null):Array<Int>;
	public var writeIndexes(default, null):Array<Int>;

	private inline function get_capacity():Int {
		return __capacity;
	}

	public function new(capacity:Int) {
		__capacity = capacity;
		__read = [];
		__write = [];
		readIndexes = [-1];
		writeIndexes = [-1];

		#if cpp
		__poll = new Poll(capacity);
		readIndexes = __poll.readIndexes;
		writeIndexes = __poll.writeIndexes;
		#end
	}

	public function prepare(read:Array<Socket>, write:Array<Socket>):Void {
		__read = read != null ? read : [];
		__write = write != null ? write : [];

		#if cpp
		__poll.prepare(__read, __write);
		#end
	}

	public function events(timeout:Float):Void {
		#if cpp
		__poll.events(timeout);
		readIndexes = __poll.readIndexes;
		writeIndexes = __poll.writeIndexes;
		#else
		var read = __read.copy();
		var write = __write.copy();
		var ready = Socket.select(read, write, [], timeout);

		__fillIndexes(readIndexes, __read, ready.read);
		__fillIndexes(writeIndexes, __write, ready.write);
		#end
	}

	public function dispose():Void {
		__read = [];
		__write = [];

		#if cpp
		__poll = null;
		#end
	}

	#if !cpp
	private function __fillIndexes(indexes:Array<Int>, source:Array<Socket>, ready:Array<Socket>):Void {
		var count:Int = 0;
		for (socket in ready) {
			for (i in 0...source.length) {
				if (source[i] == socket) {
					indexes[count++] = i;
					break;
				}
			}
		}

		indexes[count] = -1;
		indexes.resize(count + 1);
	}
	#end
}
