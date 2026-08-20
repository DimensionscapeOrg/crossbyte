package crossbyte._internal.socket;

// Not built for the browser: it polls OS socket descriptors, which a page does not have. The browser socket is driven by the runtime tick instead.
#if !js

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
		#else
		__readAt = __index(__read);
		__writeAt = __index(__write);
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

		if (__readAt == null) {
			__readAt = __index(__read);
		}
		if (__writeAt == null) {
			__writeAt = __index(__write);
		}

		__fillIndexes(readIndexes, __readAt, ready.read);
		__fillIndexes(writeIndexes, __writeAt, ready.write);
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
	/**
	 * Position of each registered socket, rebuilt when the set it describes
	 * changes rather than walked per readiness result.
	 */
	private var __readAt:haxe.ds.ObjectMap<Socket, Int>;
	private var __writeAt:haxe.ds.ObjectMap<Socket, Int>;

	private function __index(source:Array<Socket>):haxe.ds.ObjectMap<Socket, Int> {
		var at:haxe.ds.ObjectMap<Socket, Int> = new haxe.ds.ObjectMap();
		for (i in 0...source.length) {
			at.set(source[i], i);
		}
		return at;
	}

	private function __fillIndexes(indexes:Array<Int>, at:haxe.ds.ObjectMap<Socket, Int>, ready:Array<Socket>):Void {
		var count:Int = 0;

		// Was a scan of the registered set per ready socket, so a busy pass
		// cost registered x ready comparisons — 65,536 of them for 256 sockets
		// all readable at once, every pump. The positions are fixed until the
		// set changes, so they are looked up instead.
		for (socket in ready) {
			var i:Null<Int> = at.get(socket);
			if (i != null) {
				indexes[count++] = i;
			}
		}

		indexes[count] = -1;
		indexes.resize(count + 1);
	}
	#end
}
#end
