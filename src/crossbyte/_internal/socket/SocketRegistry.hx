package crossbyte._internal.socket;

import crossbyte.core.CrossByte;
import crossbyte.ds.Stack;
import sys.net.Socket;
import crossbyte.net.Socket as CBSocket;
import crossbyte.ds.DenseSet;

@:access(crossbyte.ds.DenseSet)
final class SocketRegistry {
	@:noCompletion private var __set:DenseSet<Socket>;
	@:noCompletion private var __isDirty:Bool = true;
	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __deregisterQueue:Stack<Socket>;
	@:noCompletion private var __writableQueue:Stack<Socket>;

	@:noCompletion private var __readSnapshot:Array<Socket>;

	public var capacity(get, null):Int;
	public var size(get, null):Int;
	public var isEmpty(get, null):Bool;

	private inline function get_capacity():Int {
		return __capacity;
	}

	public inline function get_isEmpty():Bool {
		return __set.isEmpty;
	}

	private inline function get_size():Int {
		return __set.length;
	}

	public inline function new(capacity:Int) {
		__capacity = capacity;
		__set = new DenseSet();
		__deregisterQueue = new Stack();
		__writableQueue = new Stack();
		__readSnapshot = [];
	}

	public inline function clear():Void {
		__set.clear();
		__deregisterQueue.clear(true);
		__writableQueue.clear();
		__readSnapshot.resize(0);
		__isDirty = true;
	}

	public inline function register(socket:Socket):Void {
		if (__set.add(socket)) {
			__isDirty = true;

			if (__set.length > capacity) {
				__grow();
			}
		}
	}

	public inline function deregister(socket:Socket):Void {
		__deregisterQueue.push(socket);
	}

	public inline function queueWritable(socket:Socket):Void {
		__writableQueue.push(socket);
	}

	@:noCompletion private inline function __onDeregisterSocket(s:Socket):Void {
		__set.remove(s);
	}
	public #if final inline #end function update(timeout:Float = 0):Void {
		if (!__writableQueue.isEmpty) {
			__writableQueue.forEach(__onFlushSocket);
			__writableQueue.clear();
		}

		if (!__deregisterQueue.isEmpty) {
			__deregisterQueue.forEach(__onDeregisterSocket);
			__deregisterQueue.clear(true);
			__isDirty = true;
		}

		if (__set.isEmpty) {
			return;
		}

		if (__isDirty) {
			__readSnapshot = __set.keys;
			__isDirty = false;
		}

		var read:Array<Socket> = __readSnapshot != null ? __readSnapshot.copy() : [];
		if (read.length == 0) {
			return;
		}

		var res = Socket.select(read, null, null, timeout);

		for (s in res.read) {
			var cb:CBSocket = s.custom;
			@:privateAccess if (cb != null && !cb.__closed) {
				cb.this_onTick();
			}
		}
	}

	@:noCompletion private inline function __grow():Void {
		__capacity = Math.ceil(__capacity * 1.5);
		__isDirty = true;
	}

	@:noCompletion private inline function __onFlushSocket(sock:Socket):Void {
		var cb:crossbyte.net.Socket = sock.custom;
		@:privateAccess if (cb.__isDirty) {
			cb.flush();
		}
	}
}
