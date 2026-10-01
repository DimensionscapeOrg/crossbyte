package crossbyte.net._internal;

import crossbyte.core.CrossByte;

/**
	Hands a close made on another thread to the runtime the connection runs
	on.

	What a runtime owns -- its socket registry, its timers, its listeners --
	is not thread-safe, and closing a connection touches all three. Each
	socket's `close()` therefore runs on its runtime's thread: called from
	any other, it is posted there, as `CrossByte.post` posts any work, and
	the call returns at once. Closing is the one thing worth allowing from
	elsewhere -- a worker that decides a connection has to go -- and it
	used to throw part way through, or tell the connection's listeners on
	the wrong thread.
**/
class RuntimeHandOff {
	/**
		Posts `work` to `runtime` when the calling thread is not the one it
		runs on, and says whether it did. False on the runtime's own thread,
		with no runtime, and when the runtime has exited, where nothing would
		run it: the caller then does the work itself. Always false without
		threads.
	**/
	public static function elsewhere(runtime:Null<CrossByte>, work:Void->Void):Bool {
		#if target.threaded
		if (runtime == null || runtime.__isOwnThread()) {
			return false;
		}
		return runtime.post(work);
		#else
		return false;
		#end
	}
}
