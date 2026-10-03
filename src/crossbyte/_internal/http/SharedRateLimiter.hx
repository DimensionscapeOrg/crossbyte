package crossbyte._internal.http;

// Not built for the browser, which serves nothing.
#if (!js && target.threaded)
import crossbyte.net.RateLimiter;
import sys.thread.Mutex;

/**
	A `RateLimiter` several runtimes consult at once: each call is passed to
	the limiter it was made for, one at a time.

	`HTTPServerConfig.rateLimiter` is asked about every request, and a
	server spread over runtimes asks it from each of their threads. The
	limiter itself keeps its buckets in plain maps, which two threads
	changing at once corrupt, and a lock inside it would charge every server
	on one runtime for what only a spread one needs. So a spread server puts
	this in front of the limiter it was given, which keeps one budget for
	every client across all of its runtimes.
**/
@:noCompletion
class SharedRateLimiter extends RateLimiter {
	/** The limiter every call is passed to. **/
	public final inner:RateLimiter;

	@:noCompletion private final __lock:Mutex = new Mutex();

	public function new(inner:RateLimiter) {
		// The parent's own buckets are never used: everything goes to inner.
		super(1, 1.0, null, 1);
		this.inner = inner;
	}

	/** `limiter`, behind one of these unless it is one already. **/
	public static function around(limiter:RateLimiter):RateLimiter {
		if (limiter == null || Std.isOfType(limiter, SharedRateLimiter)) {
			return limiter;
		}
		return new SharedRateLimiter(limiter);
	}

	override public function isRateLimited(key:String):Bool {
		__lock.acquire();
		try {
			var answer:Bool = inner.isRateLimited(key);
			__lock.release();
			return answer;
		} catch (error:Dynamic) {
			__lock.release();
			throw error;
		}
	}

	override public function tryAcquire(key:String, cost:Int = 1):Bool {
		__lock.acquire();
		try {
			var answer:Bool = inner.tryAcquire(key, cost);
			__lock.release();
			return answer;
		} catch (error:Dynamic) {
			__lock.release();
			throw error;
		}
	}

	override public function secondsUntil(key:String, cost:Int = 1):Float {
		__lock.acquire();
		try {
			var answer:Float = inner.secondsUntil(key, cost);
			__lock.release();
			return answer;
		} catch (error:Dynamic) {
			__lock.release();
			throw error;
		}
	}

	override public function remaining(key:String):Int {
		__lock.acquire();
		try {
			var answer:Int = inner.remaining(key);
			__lock.release();
			return answer;
		} catch (error:Dynamic) {
			__lock.release();
			throw error;
		}
	}

	override public function reset(key:String):Void {
		__lock.acquire();
		try {
			inner.reset(key);
			__lock.release();
		} catch (error:Dynamic) {
			__lock.release();
			throw error;
		}
	}

	override public function activeKeyCount():Int {
		__lock.acquire();
		try {
			var answer:Int = inner.activeKeyCount();
			__lock.release();
			return answer;
		} catch (error:Dynamic) {
			__lock.release();
			throw error;
		}
	}
}
#end
