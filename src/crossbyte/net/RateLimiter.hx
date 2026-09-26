package crossbyte.net;

/**
 * Token-bucket request limiter.
 *
 * Each key (client IP, account, device, session) owns a bucket holding up to
 * `maxRequests` tokens that refills continuously at
 * `maxRequests / perSeconds` tokens per second. A request consumes one token
 * (or `cost` tokens via `tryAcquire`), so callers get burst capacity up to
 * `maxRequests` with a sustained rate of `maxRequests` per `perSeconds`,
 * without the double-burst edge a fixed window allows at its boundary.
 *
 * Nothing in it is about HTTP, which is why it no longer lives there: a
 * server admitting connections, a datagram path shedding a flood, and an RPC
 * endpoint metering a caller all want the same bucket. `HTTPServerConfig`
 * fits one by default; anything else can share that instance or own one per
 * concern.
 *
 * Buckets are kept in two generations. Every `perSeconds` the older is
 * dropped whole and the newer becomes the older, and a key used from either
 * is carried into the newer. So what is dropped is only ever a bucket left
 * alone for a full period: one refilled to capacity, which a fresh bucket
 * cannot be told apart from. A generation nobody has used for a period goes
 * too, without waiting its turn. Retiring one is an assignment. It was a sweep
 * of every bucket, run inside whichever call found it due; keys are whatever
 * a client sends, and on Node two million of them held 294 MB and put an
 * 815 ms sweep inside one `tryAcquire`.
 *
 * `maxKeys` caps the keys held, across both generations. A key arriving
 * when the table is full shares one overflow bucket with every other such key,
 * so a flood of new keys is throttled as if it were one client while the keys
 * already held keep their own buckets. An optional injectable clock makes
 * behavior deterministic in tests.
 */
class RateLimiter {
	/** Keys held at most by default: 8 to 13 MB of buckets, by target. */
	public static inline var DEFAULT_MAX_KEYS:Int = 100000;

	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __refillPerSecond:Float;
	@:noCompletion private var __period:Float;
	@:noCompletion private var __clock:() -> Float;
	@:noCompletion private var __maxKeys:Int;
	@:noCompletion private var __current:Map<String, Bucket>;
	@:noCompletion private var __previous:Map<String, Bucket>;
	@:noCompletion private var __currentSize:Int = 0;
	@:noCompletion private var __previousSize:Int = 0;
	// When a bucket in each generation last had tokens asked of it.
	@:noCompletion private var __currentUsedAt:Float;
	@:noCompletion private var __previousUsedAt:Float;
	@:noCompletion private var __rotateAt:Float;
	@:noCompletion private var __overflow:Bucket = null;

	/**
	 * @param maxRequests Bucket capacity and sustained request budget.
	 * @param perSeconds The period over which `maxRequests` refills.
	 * @param clock Optional monotonic time source in seconds; defaults to
	 * `haxe.Timer.stamp`. Intended for tests.
	 * @param maxKeys Most keys held at once; a key arriving past it shares the
	 * overflow bucket. See the class notes.
	 */
	public function new(maxRequests:Int = 10, perSeconds:Float = 60.0, ?clock:() -> Float, maxKeys:Int = DEFAULT_MAX_KEYS) {
		if (maxRequests < 1) {
			throw "maxRequests must be at least 1";
		}
		if (perSeconds <= 0 || !Math.isFinite(perSeconds)) {
			throw "perSeconds must be a positive finite number";
		}
		if (maxKeys < 1) {
			throw "maxKeys must be at least 1";
		}

		__capacity = maxRequests;
		__refillPerSecond = maxRequests / perSeconds;
		__period = perSeconds;
		__clock = (clock != null) ? clock : haxe.Timer.stamp;
		__maxKeys = maxKeys;
		__current = new Map();
		__previous = new Map();
		var now:Float = __clock();
		__currentUsedAt = now;
		__previousUsedAt = now;
		__rotateAt = now + perSeconds;
	}

	/**
	 * Consumes one token for `key` and reports whether the request should be
	 * rejected. Retained for existing HTTP call sites; equivalent to
	 * `!tryAcquire(key)`.
	 */
	public function isRateLimited(key:String):Bool {
		return !tryAcquire(key);
	}

	/**
	 * Attempts to consume `cost` tokens for `key`.
	 *
	 * @return `true` when the tokens were available and consumed. A cost
	 * above the bucket capacity can never succeed and consumes nothing.
	 */
	public function tryAcquire(key:String, cost:Int = 1):Bool {
		if (cost < 1) {
			throw "cost must be at least 1";
		}
		if (key == null) {
			key = "";
		}
		if (cost > __capacity) {
			return false;
		}

		var now:Float = __clock();
		if (now >= __rotateAt) {
			__rotate(now);
		}

		var bucket:Null<Bucket> = __current.get(key);
		if (bucket == null) {
			bucket = __admit(key, now);
		} else if (now > __currentUsedAt) {
			__currentUsedAt = now;
		}
		__refill(bucket, now);

		if (bucket.tokens >= cost) {
			bucket.tokens -= cost;
			return true;
		}

		return false;
	}

	/**
	 * Returns the number of whole tokens currently available to `key`
	 * without consuming any.
	 */
	public function remaining(key:String):Int {
		if (key == null) {
			key = "";
		}

		var bucket:Null<Bucket> = __peek(key);
		if (bucket == null) {
			return __capacity;
		}

		__refill(bucket, __clock());
		return Math.floor(bucket.tokens);
	}

	/**
	 * Forgets `key`, restoring its full burst capacity.
	 */
	public function reset(key:String):Void {
		if (key == null) {
			return;
		}
		if (__current.remove(key)) {
			__currentSize--;
		}
		if (__previous.remove(key)) {
			__previousSize--;
		}
	}

	/**
	 * Number of keys currently holding bucket state, never more than
	 * `maxKeys`. Useful for monitoring and for verifying idle eviction.
	 */
	public function activeKeyCount():Int {
		return __currentSize + __previousSize;
	}

	@:noCompletion private function __rotate(now:Float):Void {
		if (now - __currentUsedAt >= __period) {
			// Nothing asked for tokens for a period: every bucket in either
			// generation is full.
			__previous = new Map();
			__previousSize = 0;
		} else {
			__previous = __current;
			__previousSize = __currentSize;
			__previousUsedAt = __currentUsedAt;
		}

		__current = new Map();
		__currentSize = 0;
		__rotateAt = now + __period;
	}

	/**
	 * The bucket a key the newer generation does not hold spends from: its
	 * own carried forward, a new one, or past the cap the overflow bucket.
	 */
	@:noCompletion private function __admit(key:String, now:Float):Bucket {
		var bucket:Null<Bucket> = __previous.get(key);
		if (bucket != null) {
			// Moved, not added: carrying a key forward leaves the count as it
			// was.
			__previous.remove(key);
			__previousSize--;
		} else {
			if (__currentSize + __previousSize >= __maxKeys && __previousSize > 0 && now - __previousUsedAt >= __period) {
				// Full, but partly of keys a period idle: room, without
				// waiting for that generation's turn.
				__previous = new Map();
				__previousSize = 0;
			}
			if (__currentSize + __previousSize >= __maxKeys) {
				if (__overflow == null) {
					__overflow = new Bucket(__capacity, now);
				}
				return __overflow;
			}
			bucket = new Bucket(__capacity, now);
		}

		__current.set(key, bucket);
		__currentSize++;
		// The latest, so a clock that steps back cannot age a generation early.
		if (now > __currentUsedAt) {
			__currentUsedAt = now;
		}
		return bucket;
	}

	/** What `key` would spend from, without carrying it forward. */
	@:noCompletion private function __peek(key:String):Null<Bucket> {
		var bucket:Null<Bucket> = __current.get(key);
		if (bucket == null) {
			bucket = __previous.get(key);
		}
		if (bucket == null && __currentSize + __previousSize >= __maxKeys) {
			bucket = __overflow;
		}
		return bucket;
	}

	@:noCompletion private function __refill(bucket:Bucket, now:Float):Void {
		var elapsed:Float = now - bucket.updatedAt;
		if (elapsed <= 0) {
			// A stalled or backwards clock must never mint tokens.
			return;
		}

		bucket.tokens = Math.min(__capacity, bucket.tokens + elapsed * __refillPerSecond);
		bucket.updatedAt = now;
	}
}

/**
 * One key's tokens. A class rather than an anonymous structure: on hxcpp an
 * anonymous structure's fields are looked up by name, and a Float stored in
 * one is boxed.
 */
@:noCompletion private class Bucket {
	public var tokens:Float;
	public var updatedAt:Float;

	public function new(tokens:Float, updatedAt:Float) {
		this.tokens = tokens;
		this.updatedAt = updatedAt;
	}
}
