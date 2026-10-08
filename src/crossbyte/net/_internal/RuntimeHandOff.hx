package crossbyte.net._internal;

import crossbyte.core.CrossByte;

/**
	Hands a close made on another thread to the runtime the connection runs
	on.

	What a runtime owns (its socket registry, its timers, its listeners)
	is not thread-safe, and closing a connection touches all three. Each
	socket's `close()` therefore runs on its runtime's thread: called from
	any other, it is posted there, as `CrossByte.post` posts any work, and
	the call returns at once. Closing is the one thing worth allowing from
	elsewhere (a worker that decides a connection has to go), and run on the
	calling thread it would throw part way through, or tell the
	connection's listeners on the wrong thread.

	Asked first, then posted, so a close on the runtime's own thread (every
	close but these) builds no closure to post: a caller writes

	```haxe
	if (RuntimeHandOff.offThread(runtime) && runtime.post(() -> close())) {
		return;
	}
	```

	and does the work itself when the runtime has exited, which takes
	nothing posted since nothing would run it.
**/
class RuntimeHandOff {
	/**
		Whether the calling thread is not the one `runtime` runs on. False
		with no runtime and without threads. The thread's own runtime is
		looked at first, a thread-local read, so the answer on the runtime's
		thread costs no lookup of the thread itself.
	**/
	public static inline function offThread(runtime:Null<CrossByte>):Bool {
		#if target.threaded
		return runtime != null && CrossByte.__currentOrNull() != runtime && !runtime.__isOwnThread();
		#else
		return false;
		#end
	}
}
