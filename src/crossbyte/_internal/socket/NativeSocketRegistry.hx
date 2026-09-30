package crossbyte._internal.socket;

// Not built for the browser: it polls OS socket descriptors, which a page does not have. The browser socket is driven by the runtime tick instead.
#if !js

import crossbyte.ds.Stack;
import crossbyte._internal.socket.poll.PollBackend;
import crossbyte._internal.socket.poll.PollBackendRegistry;
import sys.net.Socket;
import crossbyte.ds.DenseSet;

@:access(crossbyte.ds.DenseSet)
final class NativeSocketRegistry {
	@:noCompletion private var __set:DenseSet<Socket>;
	@:noCompletion private var __poll:PollBackend;
	@:noCompletion private var __isDirty:Bool = true;
	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __deregisterQueue:Stack<Socket>;
	@:noCompletion private var __deregisterPending:DenseSet<Socket>;
	@:noCompletion private var __writableQueue:Stack<Socket>;
	@:noCompletion private var __writableSwap:Stack<Socket>;
	@:noCompletion private var __readSnapshot:Array<Socket>;

	// Sockets watched for becoming writable: a connect in flight, finished
	// the moment the system says so rather than at the next tick. Polled from
	// a copy, since a connect that finishes leaves the set from inside the
	// dispatch that reports it.
	@:noCompletion private var __writeSet:DenseSet<Socket>;
	@:noCompletion private var __writeSnapshot:Array<Socket>;

	public var capacity(get, null):Int;
	public var size(get, null):Int;
	public var isEmpty(get, null):Bool;

	/**
		Given what a socket's handler threw, and that socket. Each handler is
		contained on its own, so one connection's bug is not the rest's:
		letting it propagate from inside the dispatch skipped every other
		ready socket this pass and took the runtime's loop down with it. Null
		rethrows instead, for a registry nothing is driving; a runtime sets
		this, and decides what becomes of the socket.
	**/
	public var onHandlerError:(error:Dynamic, socket:IPollableSocket) -> Void = null;

	/**
		Seconds spent blocked inside poll since the runtime last took it, so
		the POLL loop can tell the time it waited from the time it worked.
	**/
	@:noCompletion public var __waited:Float = 0.0;

	private inline function get_capacity():Int {
		return __capacity;
	}

	public inline function get_isEmpty():Bool {
		return __set.isEmpty && __writeSet.isEmpty;
	}

	private inline function get_size():Int {
		return __set.length;
	}

	public inline function new(capacity:Int) {
		__capacity = capacity;
		__set = new DenseSet();
		__poll = PollBackendRegistry.create(__capacity);
		__deregisterQueue = new Stack();
		__deregisterPending = new DenseSet();
		__writableQueue = new Stack();
		__writableSwap = new Stack();
		__readSnapshot = [];
		__writeSet = new DenseSet();
		__writeSnapshot = null;
	}

	public inline function clear():Void {
		__set.clear();
		__poll.dispose();
		__deregisterQueue.clear(true);
		__deregisterPending.clear();
		__writableQueue.clear();
		__writableSwap.clear();
		__readSnapshot.resize(0);
		__writeSet.clear();
		__writeSnapshot = null;
		__isDirty = true;
	}

	public inline function register(socket:Socket):Void {
		if (__deregisterPending.remove(socket)) {
			return;
		}

		if (__set.add(socket)) {
			__isDirty = true;
			__ensureCapacity();
		}
	}

	public inline function deregister(socket:Socket):Void {
		if (__set.contains(socket) && __deregisterPending.add(socket)) {
			__deregisterQueue.push(socket);
		}
		if (__writeSet.remove(socket)) {
			__isDirty = true;
		}
	}

	/**
		Reports `socket` to its `registryOnWritable` once it can be written
		to, until `unwatchWritable`: how a connect in flight is finished as
		soon as the system finishes it.
	**/
	public inline function watchWritable(socket:Socket):Void {
		if (__writeSet.add(socket)) {
			__isDirty = true;
			__ensureCapacity();
		}
	}

	public inline function unwatchWritable(socket:Socket):Void {
		if (__writeSet.remove(socket)) {
			__isDirty = true;
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
			// Drained through a swap buffer, because a socket that is still
			// blocked re-queues itself from inside this dispatch. Iterating
			// the live queue and clearing it afterwards threw those away,
			// so a socket only ever got one retry and whatever it still
			// held was stranded, no error, no close, indistinguishable
			// from data that was never sent.
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

		if (__set.isEmpty && __writeSet.isEmpty) {
			return;
		}

		if (__isDirty) {
			__readSnapshot = __set.keys;
			__writeSnapshot = __writeSet.isEmpty ? null : __writeSet.toArray();
			__poll.prepare(__readSnapshot, __writeSnapshot);
			__isDirty = false;
		}

		if (timeout > 0) {
			// Timed only when it can block, which is the POLL loop's case;
			// the DEFAULT loop's per-frame poll pays nothing for it.
			var waitStart:Float = haxe.Timer.stamp();
			__poll.events(timeout);
			__waited += haxe.Timer.stamp() - waitStart;
		} else {
			__poll.events(timeout);
		}
		for (i in __poll.readIndexes) {
			if (i == -1) {
				break;
			}
			__dispatchReadable(__readSnapshot[i]);
		}

		var watched:Array<Socket> = __writeSnapshot;
		if (watched != null) {
			for (i in __poll.writeIndexes) {
				if (i == -1) {
					break;
				}
				__dispatchWritable(watched[i]);
			}
		}
	}

	@:noCompletion private inline function __ensureCapacity():Void {
		// Both lists count: a backend is prepared with the two together, and
		// refuses more than it was made for.
		if (__set.length + __writeSet.length > __capacity) {
			__grow();
		}
	}

	@:noCompletion private inline function __grow():Void {
		__capacity = Math.ceil(__capacity * 1.5);
		__poll.dispose();
		__poll = PollBackendRegistry.create(__capacity);
		__isDirty = true;
	}

	@:noCompletion private inline function __dispatchReadable(socket:Socket):Void {
		var cb:IPollableSocket = cast socket.custom;
		if (cb != null && !cb.registryClosed) {
			try {
				cb.registryOnReadable();
			} catch (error:Dynamic) {
				__handlerThrew(error, cb);
			}
		}
	}

	@:noCompletion private inline function __dispatchWritable(socket:Socket):Void {
		// Only while it is still watched: a connect finished by the readable
		// dispatch above has already been announced.
		if (__writeSet.contains(socket)) {
			var cb:IPollableSocket = cast socket.custom;
			if (cb != null && !cb.registryClosed) {
				try {
					cb.registryOnWritable();
				} catch (error:Dynamic) {
					__handlerThrew(error, cb);
				}
			}
		}
	}

	@:noCompletion private inline function __onFlushSocket(socket:Socket):Void {
		var cb:IPollableSocket = cast socket.custom;
		if (cb != null && !cb.registryClosed) {
			try {
				cb.registryOnWritable();
			} catch (error:Dynamic) {
				__handlerThrew(error, cb);
			}
		}
	}

	@:noCompletion private function __handlerThrew(error:Dynamic, socket:IPollableSocket):Void {
		if (onHandlerError != null) {
			onHandlerError(error, socket);
			return;
		}

		#if cpp
		cpp.Lib.rethrow(error);
		#else
		throw error;
		#end
	}
}
#end
