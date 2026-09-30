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

	// Sockets watched for becoming writable: a connect in flight, which is
	// finished the moment the system says so rather than at the next tick.
	@:noCompletion private var __writeSet:DenseSet<Socket>;
	@:noCompletion private var __writeSnapshot:Array<Socket>;
	@:noCompletion private var __writeDirty:Bool = false;

	@:noCompletion private var __readSnapshot:Array<Socket>;
	@:noCompletion private var __selectBuffer:Array<Socket>;

	#if neko
	@:noCompletion private var __poll:NekoPoll;
	#end

	public var capacity(get, null):Int;
	public var size(get, null):Int;
	public var isEmpty(get, null):Bool;

	/**
		Given what a socket's handler threw, and that socket; see
		`NativeSocketRegistry.onHandlerError`. Null rethrows.
	**/
	public var onHandlerError:(error:Dynamic, socket:IPollableSocket) -> Void = null;

	/** Seconds spent blocked in select since last taken; see NativeSocketRegistry. **/
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
		__deregisterQueue = new Stack();
		__deregisterPending = new DenseSet();
		__writableQueue = new Stack();
		__writableSwap = new Stack();
		__writeSet = new DenseSet();
		__writeSnapshot = [];
		__readSnapshot = [];
		__selectBuffer = [];
		#if neko
		__poll = new NekoPoll(__capacity);
		#end
	}

	public inline function clear():Void {
		__set.clear();
		__deregisterQueue.clear(true);
		__deregisterPending.clear();
		__writableQueue.clear();
		__writableSwap.clear();
		__writeSet.clear();
		__writeSnapshot.resize(0);
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
			__ensureCapacity();
		}
	}

	public inline function deregister(socket:Socket):Void {
		if (__set.contains(socket) && __deregisterPending.add(socket)) {
			__deregisterQueue.push(socket);
		}
		unwatchWritable(socket);
	}

	/**
		Reports `socket` to its `registryOnWritable` once it can be written
		to, until `unwatchWritable`: how a connect in flight is finished as
		soon as the system finishes it. A socket whose failure the system
		reports only as an exception -- a refused connect, on Windows -- is
		reported the same way, so the handler asks which it was.
	**/
	public inline function watchWritable(socket:Socket):Void {
		if (__writeSet.add(socket)) {
			__writeDirty = true;
			__ensureCapacity();
		}
	}

	public inline function unwatchWritable(socket:Socket):Void {
		if (__writeSet.remove(socket)) {
			__writeDirty = true;
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

		if (__set.isEmpty && __writeSet.isEmpty) {
			// The last sockets polled are let go of here. The buffer is only
			// resized when the set's size changes, and an empty set returns
			// before that, so the last connections a server held stayed
			// reachable from it -- through their `custom`, each whole Socket
			// with its buffers and userData -- for as long as it sat idle.
			if (__selectBuffer.length > 0) {
				__selectBuffer.resize(0);
			}
			if (__writeSnapshot.length > 0) {
				__writeSnapshot.resize(0);
			}
			return;
		}

		#if neko
		// Taken before anything is dispatched, so a change a handler makes
		// below is seen by the next pass rather than cleared by this one.
		var changed:Bool = __isDirty || __writeDirty;
		#end

		if (__isDirty) {
			__readSnapshot = __set.keys;
			__isDirty = false;
		}

		// A copy, unlike the read snapshot: a connect that finishes leaves the
		// set from inside the dispatch below, which would reorder the set's
		// own array under the loop reading it.
		if (__writeDirty) {
			__writeSnapshot.resize(0);
			for (socket in __writeSet.keys) {
				__writeSnapshot.push(socket);
			}
			__writeDirty = false;
		}

		#if neko
		__pollNeko(timeout, changed);
		#else
		__select(timeout);
		#end
	}

	#if neko
	/**
		neko polls through its poll natives rather than `select`, which there
		takes at most 64 sockets on Windows and throws past them; see `NekoPoll`.
		Dispatched by position, as `NativeSocketRegistry` does: the read set
		only loses members between passes, so a position still names the
		socket it named when the poll was prepared.
	**/
	@:noCompletion private function __pollNeko(wait:Float, changed:Bool):Void {
		if (changed) {
			__poll.prepare(__readSnapshot, __writeSnapshot);
		}

		if (wait > 0) {
			var waitStart:Float = haxe.Timer.stamp();
			__poll.events(wait);
			__waited += haxe.Timer.stamp() - waitStart;
		} else {
			__poll.events(wait);
		}

		var n:Int = 0;
		var i:Int = __poll.readIndex(n);
		while (i != -1) {
			__dispatchReadable(__readSnapshot[i]);
			i = __poll.readIndex(++n);
		}

		if (__writeSnapshot.length > 0) {
			n = 0;
			i = __poll.writeIndex(n);
			while (i != -1) {
				__dispatchWritable(__writeSnapshot[i]);
				i = __poll.writeIndex(++n);
			}
		}
	}
	#else
	@:noCompletion private function __select(wait:Float):Void {
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

		// A TLS socket can hold bytes the kernel has already handed over: reads
		// there come off the channel a whole record at a time, so the end of a
		// handshake regularly arrives together with the first application
		// record -- which is what a client sending its request the moment it
		// connects produces, and that is every HTTPS client. select() then
		// reports an idle socket with a request already sitting in it.
		//
		// Selecting first and asking these second would make the wait itself
		// the bug: a pump blocking for `timeout` before looking at data it
		// already has. So they go first, and finding any drops the select to a
		// poll.
		//
		// Only the jvm backend can answer yes -- it is the one that decrypts in
		// front of the channel. Gating the sweep keeps every other target's
		// pump exactly as it was rather than paying a call per socket per pump
		// for an answer that is structurally always false.
		#if (java || jvm)
		for (i in 0...count) {
			var cb:IPollableSocket = cast __selectBuffer[i].custom;

			if (cb == null || cb.registryClosed || !cb.registryHasBufferedInput()) {
				continue;
			}

			wait = 0;
			try {
				cb.registryOnReadable();
			} catch (error:Dynamic) {
				__handlerThrew(error, cb);
			}
		}
		#end

		// Watched for writing, and for an exception too: a refused connect
		// is reported in the exception set on Windows and never becomes
		// writable.
		var watching:Bool = __writeSnapshot.length > 0;
		var write:Array<Socket> = watching ? __writeSnapshot.copy() : [];
		var others:Array<Socket> = watching ? __writeSnapshot.copy() : [];

		var res;
		if (wait > 0) {
			var waitStart:Float = haxe.Timer.stamp();
			res = Socket.select(__selectBuffer, write, others, wait);
			__waited += haxe.Timer.stamp() - waitStart;
		} else {
			res = Socket.select(__selectBuffer, write, others, wait);
		}

		for (s in res.read) {
			__dispatchReadable(s);
		}

		if (watching) {
			for (s in res.write) {
				__dispatchWritable(s);
			}
			if (res.others != null) {
				for (s in res.others) {
					// Once, when it is in both.
					if (res.write.indexOf(s) < 0) {
						__dispatchWritable(s);
					}
				}
			}
		}
	}
	#end

	@:noCompletion private inline function __dispatchReadable(s:Socket):Void {
		var cb:IPollableSocket = cast s.custom;
		if (cb != null && !cb.registryClosed) {
			try {
				cb.registryOnReadable();
			} catch (error:Dynamic) {
				__handlerThrew(error, cb);
			}
		}
	}

	@:noCompletion private inline function __dispatchWritable(s:Socket):Void {
		// Only while it is still watched: a connect finished by the readable
		// dispatch above has already been announced.
		if (__writeSet.contains(s)) {
			var cb:IPollableSocket = cast s.custom;
			if (cb != null && !cb.registryClosed) {
				try {
					cb.registryOnWritable();
				} catch (error:Dynamic) {
					__handlerThrew(error, cb);
				}
			}
		}
	}

	@:noCompletion private inline function __ensureCapacity():Void {
		if (__set.length + __writeSet.length > __capacity) {
			__grow();
		}
	}

	@:noCompletion private inline function __grow():Void {
		__capacity = Math.ceil(__capacity * 1.5);
		__isDirty = true;
		#if neko
		__poll = new NekoPoll(__capacity);
		__writeDirty = true;
		#end
	}

	@:noCompletion private inline function __onFlushSocket(sock:Socket):Void {
		var cb:IPollableSocket = cast sock.custom;
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

		throw error;
	}
}
#end
