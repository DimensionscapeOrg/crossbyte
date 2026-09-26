package crossbyte.crypto.password._internal;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.sys.Task;
import crossbyte.sys.TaskPool;
#if target.threaded
import sys.thread.Mutex;
#end

/**
 * Runs password hashing off the calling thread, for `BCrypt` and `Argon2id`.
 *
 * A hash at the recommended cost takes 100 ms or more, all of it spent on
 * whichever thread asked. On a runtime's thread that is 100 ms in which no other
 * connection is served, so about eight sign-ins a second fill a server. The
 * async variants hand the work to a `TaskPool` and give back a `Future`.
 */
@:noCompletion
class PasswordWork {
	/**
	 * Workers in the shared pool.
	 *
	 * Two, so one slow hash does not queue every other sign-in behind it, and no
	 * more, because each Argon2id hash holds its whole memory limit -- 64 MiB at
	 * the interactive setting -- while it runs. A service that wants more passes
	 * its own pool.
	 */
	public static inline final SHARED_WORKERS:Int = 2;

	@:noCompletion private static var __shared:Null<TaskPool> = null;
	#if target.threaded
	@:noCompletion private static final __sharedLock:Mutex = new Mutex();
	#end

	/**
	 * Runs `job` on `pool`, or on the shared pool when that is null.
	 *
	 * The task's events are delivered on the thread that submitted it, when that
	 * thread runs a CrossByte runtime, so the future completes there too.
	 */
	public static function run<T>(job:Void->T, pool:Null<TaskPool>):Future<T> {
		var completer:Completer<T> = new Completer<T>();
		var task:Task<T>;

		try {
			task = (pool != null ? pool : sharedPool()).submitResult(job);
		} catch (error:Dynamic) {
			// A pool that has been shut down refuses the job. That is this
			// call's failure, and it belongs in the future like any other.
			completer.fail(error);
			return completer.future;
		}

		task.onComplete(value -> completer.complete(value));
		task.onError(error -> completer.fail(error));
		task.onCancel(() -> completer.fail("The password hashing task was cancelled before it ran."));
		return completer.future;
	}

	/** The pool the async variants use when not given one, started on first use. */
	public static function sharedPool():TaskPool {
		// Always under the lock: an unlocked first read could see the pool
		// before its constructor's writes on a weakly ordered machine, and one
		// acquire is nothing beside the hash it is about to queue.
		#if target.threaded
		__sharedLock.acquire();
		#end
		var pool:Null<TaskPool> = __shared;
		if (pool == null) {
			pool = new TaskPool(SHARED_WORKERS);
			__shared = pool;
		}
		#if target.threaded
		__sharedLock.release();
		#end
		return pool;
	}
}
