package crossbyte._internal.js;

/**
 * A `sys.thread.Mutex` for a target that has one thread.
 *
 * Unlike the filesystem shim beside it, this does not throw, and the
 * difference is the point. A mutex excludes other threads from a section of
 * code; where there is only one thread there is nothing to exclude, so taking
 * it is not an unsupported operation — it is an operation with nothing to do.
 * Refusing here would break correct code for no reason.
 *
 * JavaScript has exactly one thread of execution per context. Web Workers do
 * not change that: they are separate contexts that exchange messages and share
 * no memory, so two of them can never be inside this code at once. The same
 * holds for Node's worker threads.
 *
 * `tryAcquire` always succeeds for the same reason — the lock can never be
 * held by anyone else.
 */
class NoMutex {
	public function new() {}

	public inline function acquire():Void {}

	public inline function tryAcquire():Bool {
		return true;
	}

	public inline function release():Void {}
}
