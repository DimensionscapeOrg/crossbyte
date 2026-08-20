package crossbyte._internal.socket;

// Not built for the browser: it polls OS socket descriptors, which a page does not have. The browser socket is driven by the runtime tick instead.
#if !js

import crossbyte.ds.Stack;
import sys.net.Socket;
import crossbyte.ds.DenseSet;

@:access(crossbyte.ds.DenseSet)
final class SocketRegistry {
	@:noCompletion private var __set:DenseSet<Socket>;
	@:noCompletion private var __isDirty:Bool = true;
	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __deregisterQueue:Stack<Socket>;
	@:noCompletion private var __deregisterPending:DenseSet<Socket>;
	@:noCompletion private var __writableQueue:Stack<Socket>;
	@:noCompletion private var __writableSwap:Stack<Socket>;

	@:noCompletion private var __readSnapshot:Array<Socket>;
	@:noCompletion private var __selectBuffer:Array<Socket>;

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
		__deregisterPending = new DenseSet();
		__writableQueue = new Stack();
		__writableSwap = new Stack();
		__readSnapshot = [];
		__selectBuffer = [];
	}

	public inline function clear():Void {
		__set.clear();
		__deregisterQueue.clear(true);
		__deregisterPending.clear();
		__writableQueue.clear();
		__writableSwap.clear();
		__readSnapshot.resize(0);
		__selectBuffer.resize(0);
		__isDirty = true;
	}

	public inline function register(socket:Socket):Void {
		if (__deregisterPending.remove(socket)) {
			return;
		}

		if (__set.add(socket)) {
			__isDirty = true;

			if (__set.length > capacity) {
				__grow();
			}
		}
	}

	public inline function deregister(socket:Socket):Void {
		if (__set.contains(socket) && __deregisterPending.add(socket)) {
			__deregisterQueue.push(socket);
		}
	}

	public inline function queueWritable(socket:Socket):Void {
		__writableQueue.push(socket);
	}

	@:noCompletion private inline function __onDeregisterSocket(s:Socket):Void {
		if (__deregisterPending.remove(s)) {
			__set.remove(s);
		}
	}
	public #if final inline #end function update(timeout:Float = 0):Void {
		if (!__writableQueue.isEmpty) {
			// Swapped before draining: a socket that is still blocked
			// re-queues itself from inside this dispatch, and clearing the
			// live queue afterwards discarded those, stranding whatever it
			// still held.
			var draining:Stack<Socket> = __writableQueue;
			__writableQueue = __writableSwap;
			__writableSwap = draining;

			draining.forEach(__onFlushSocket);
			draining.clear();
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

		if (__readSnapshot == null || __readSnapshot.length == 0) {
			return;
		}

		// Refilled into a buffer this registry keeps rather than a fresh array
		// per pump. The list handed to select cannot be the snapshot itself:
		// that is the DenseSet's own backing array, and select is free to
		// treat what it is given as scratch. Reusing one array keeps that
		// protection without allocating for it every pass.
		var count:Int = __readSnapshot.length;
		if (__selectBuffer.length != count) {
			__selectBuffer.resize(count);
		}
		for (i in 0...count) {
			__selectBuffer[i] = __readSnapshot[i];
		}

		var res = Socket.select(__selectBuffer, [], [], timeout);

		for (s in res.read) {
			var cb:IPollableSocket = cast s.custom;
			if (cb != null && !cb.registryClosed) {
				cb.registryOnReadable();
			}
		}
	}

	@:noCompletion private inline function __grow():Void {
		__capacity = Math.ceil(__capacity * 1.5);
		__isDirty = true;
	}

	@:noCompletion private inline function __onFlushSocket(sock:Socket):Void {
		var cb:IPollableSocket = cast sock.custom;
		if (cb != null && !cb.registryClosed) {
			cb.registryOnWritable();
		}
	}
}
#end
