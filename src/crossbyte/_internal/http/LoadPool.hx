package crossbyte._internal.http;

// Not built for JavaScript, where a load is asynchronous and needs no thread.
#if !js
#if target.threaded
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
 * The threads `URLLoader` runs its loads on: started as loads need them, up
 * to `maxThreads`, kept while loads keep coming, and let go after
 * `idleSeconds` without one.
 *
 * A load is a blocking request, so it has a thread to itself while it runs.
 * It used to have a new one: every `load()` started a thread and let it end,
 * so a hundred loads a second were a hundred thread starts, and on the jvm
 * each of those threads also opened a selector for its reads that nothing
 * ever closed -- two loopback sockets per load, left open until the process
 * ended, and enough of them ran the machine out of ports. Here a thread
 * finishing a load takes the next one waiting.
 *
 * Shared by every loader in the process. The queue is first come, first
 * served: past `maxThreads` loads at once, a load waits for one to finish.
 */
class LoadPool {
	/**
	 * Loads that run at once, at most, across every `URLLoader`. More wait
	 * their turn in the order they were made. Defaults to 16.
	 *
	 * Each running load holds a thread for as long as its server takes, so a
	 * program that keeps many slow requests open at once -- long polls, say
	 * -- should raise this to at least that many.
	 */
	public static var maxThreads:Int = 16;

	/** Seconds a thread with nothing to do waits for another load before it ends. */
	public static var idleSeconds:Float = 30;

	#if target.threaded
	private static final __jobs:Deque<Void->Void> = new Deque();
	// Released once per load queued, so the threads waiting on it take one
	// load each. A Lock rather than a Condition: a thread parked on a
	// Condition deadlocks the hxcpp collector, and Lock.wait takes a timeout,
	// which is how an idle thread knows to end.
	private static final __signal:Lock = new Lock();
	private static final __lock:Mutex = new Mutex();
	private static var __threads:Int = 0;
	private static var __idle:Int = 0;
	private static var __queued:Int = 0;
	private static var __started:Int = 0;
	#end

	/** Threads started since the process began. For diagnostics and tests. */
	@:noCompletion public static function threadsStarted():Int {
		#if target.threaded
		__lock.acquire();
		var started:Int = __started;
		__lock.release();
		return started;
		#else
		return 0;
		#end
	}

	/** Threads alive now, working or waiting for work. */
	@:noCompletion public static function threadCount():Int {
		#if target.threaded
		__lock.acquire();
		var count:Int = __threads;
		__lock.release();
		return count;
		#else
		return 0;
		#end
	}

	/**
	 * Runs `job` on one of the pool's threads, as soon as one is free.
	 *
	 * `job` should report its own failures: what it throws is caught, so the
	 * thread lives on for the next load, and is otherwise dropped.
	 */
	public static function run(job:Void->Void):Void {
		#if target.threaded
		__lock.acquire();
		__queued++;
		// A thread is started only when the ones waiting are too few for what
		// is queued. One that is finishing its wait counts as waiting, so
		// this can start one fewer than it might; the load then goes to the
		// first thread to come free, which is the queue working, not stuck.
		var start:Bool = __idle < __queued && __threads < __limit();
		if (start) {
			__threads++;
			__started++;
		}
		__lock.release();

		// Queued before the release, so the thread the release wakes finds it.
		__jobs.add(job);
		__signal.release();

		if (start) {
			Thread.create(__work);
		}
		#else
		__runContained(job);
		#end
	}

	#if target.threaded
	private static inline function __limit():Int {
		return maxThreads < 1 ? 1 : maxThreads;
	}

	private static function __work():Void {
		while (true) {
			__lock.acquire();
			__idle++;
			__lock.release();

			var woken:Bool = __signal.wait(idleSeconds);

			__lock.acquire();
			__idle--;
			if (!woken) {
				if (__queued == 0) {
					__threads--;
					__lock.release();
					return;
				}
				// A load came as the wait ran out: its release is still in
				// the lock, so this thread goes back for it rather than ending
				// with it unclaimed.
				__lock.release();
				continue;
			}
			if (__threads > __limit()) {
				// maxThreads was lowered while this thread lived. It ends
				// rather than add to the loads at once, and hands the load it
				// was woken for to another.
				__threads--;
				__lock.release();
				__signal.release();
				return;
			}
			__queued--;
			__lock.release();

			var job:Null<Void->Void> = __jobs.pop(false);
			if (job != null) {
				__runContained(job);
			}
		}
	}
	#end

	private static function __runContained(job:Void->Void):Void {
		try {
			job();
		} catch (_:Dynamic) {
			// A load reports its own failure to its loader before it gets
			// here; this is only what escaped that, and the thread is kept.
		}
	}
}
#end
