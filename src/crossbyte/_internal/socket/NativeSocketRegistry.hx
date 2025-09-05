package crossbyte._internal.socket;

import crossbyte.core.CrossByte;
import crossbyte.ds.Stack;
import cpp.net.Poll;
import sys.net.Socket;
import crossbyte.net.Socket as CBSocket;
import crossbyte.ds.DenseSet;

@:access(crossbyte.ds.DenseSet)
final class NativeSocketRegistry {
	@:noCompletion private var __set:DenseSet<Socket>;
	@:noCompletion private var __poll:Poll;
	@:noCompletion private var __isDirty:Bool = true;
	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __deregisterQueue:Stack<Socket>;
	@:noCompletion private var __writableQueue:Stack<Socket>;

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
		__poll = new Poll(__capacity);
		__deregisterQueue = new Stack();
		__writableQueue = new Stack();
	}

	public inline function clear():Void {
		__set.clear();
		__deregisterQueue.clear(true);
		__isDirty = true;
	}

	public inline function register(socket:Socket):Void {
		if (__set.add(socket)) {
			__isDirty = true;

			// we check here, we dont need to check again in `grow()`
			if (__set.length > capacity) {
				__grow();
			}
		}
	}

	public inline function deregister(socket:Socket):Void {
		// TODO: Lazy dereg? Rate limit this in teh future
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

		if (!__set.isEmpty) {
			if (__isDirty) {
				__poll.prepare(__set.keys, null);
				__isDirty = false;
			}
			__poll.events(timeout);
			for (i in __poll.readIndexes) {
				if (i == -1) {
					break;
				}
				var socket:Socket = __set.valueAt(i);
				var cb:CBSocket = socket.custom;
				@:privateAccess
				if (!cb.__closed) {
					cb.this_onTick();
				}
			}

			/* for (i in __poll.writeIndexes) {
				if (i == -1) {
					break;
				}
				var socket:Socket = __set.valueAt(i);
				var cb:CBSocket = socket.custom;
				@:privateAccess
				if (!cb.__closed) {
					cb.this_onTick();
				}
			}*/
		}
	}

	@:noCompletion private inline function __grow():Void {
		// ceil accepts a float and returns an int
		__capacity = Math.ceil(__capacity * 1.5);
		__poll = new Poll(__capacity);
		__isDirty = true;
	}

	@:noCompletion private inline function __onFlushSocket(socket:Socket):Void {
		var socket:crossbyte.net.Socket = socket.custom;
		@:privateAccess
		if (socket.__isDirty) {
			socket.flush();
		}
	}
}
