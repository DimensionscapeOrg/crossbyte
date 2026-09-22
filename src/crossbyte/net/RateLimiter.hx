package crossbyte.net;

/**
 * Token-bucket request limiter.
 *
 * Each key (client IP, account, device, session) owns a bucket holding up to
 * `maxRequests` tokens that refills continuously at
 * `maxRequests / perSeconds` tokens per second. A request consumes one token
 * (or `cost` tokens via `tryAcquire`), so callers get burst capacity up to
 * `maxRequests` with a sustained rate of `maxRequests` per `perSeconds` —
 * without the double-burst edge a fixed window allows at its boundary.
 *
 * Nothing in it is about HTTP, which is why it no longer lives there: a
 * server admitting connections, a datagram path shedding a flood, and an RPC
 * endpoint metering a caller all want the same bucket. `HTTPServerConfig`
 * fits one by default; anything else can share that instance or own one per
 * concern.
 *
 * Buckets idle for a full refill period are evicted opportunistically, so
 * per-key state stays bounded under churn. An optional injectable clock
 * makes behavior deterministic in tests.
 */
class RateLimiter {
	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __refillPerSecond:Float;
	@:noCompletion private var __idleEvictSeconds:Float;
	@:noCompletion private var __clock:() -> Float;
	@:noCompletion private var __buckets:Map<String, Bucket>;
	@:noCompletion private var __lastSweep:Float;

	/**
	 * @param maxRequests Bucket capacity and sustained request budget.
	 * @param perSeconds The period over which `maxRequests` refills.
	 * @param clock Optional monotonic time source in seconds; defaults to
	 * `haxe.Timer.stamp`. Intended for tests.
	 */
	public function new(maxRequests:Int = 10, perSeconds:Float = 60.0, ?clock:() -> Float) {
		if (maxRequests < 1) {
			throw "maxRequests must be at least 1";
		}
		if (perSeconds <= 0 || !Math.isFinite(perSeconds)) {
			throw "perSeconds must be a positive finite number";
		}

		__capacity = maxRequests;
		__refillPerSecond = maxRequests / perSeconds;
		__idleEvictSeconds = perSeconds;
		__clock = (clock != null) ? clock : haxe.Timer.stamp;
		__buckets = new Map();
		__lastSweep = __clock();
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
		__sweepIfDue(now);

		var bucket:Bucket = __buckets.get(key);
		if (bucket == null) {
			bucket = {tokens: __capacity, updatedAt: now};
			__buckets.set(key, bucket);
		} else {
			__refill(bucket, now);
		}

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

		var bucket:Bucket = __buckets.get(key);
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
		if (key != null) {
			__buckets.remove(key);
		}
	}

	/**
	 * Number of keys currently holding bucket state. Useful for monitoring
	 * and for verifying idle eviction.
	 */
	public function activeKeyCount():Int {
		var count = 0;
		for (_ in __buckets.keys()) {
			count++;
		}
		return count;
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

	@:noCompletion private function __sweepIfDue(now:Float):Void {
		if (now - __lastSweep < __idleEvictSeconds) {
			return;
		}
		__lastSweep = now;

		// A bucket idle for a full refill period is indistinguishable from a
		// fresh one, so dropping it cannot change limiting decisions.
		var stale:Array<String> = [];
		for (key => bucket in __buckets) {
			if (now - bucket.updatedAt >= __idleEvictSeconds) {
				stale.push(key);
			}
		}
		for (key in stale) {
			__buckets.remove(key);
		}
	}
}

@:noCompletion private typedef Bucket = {
	var tokens:Float;
	var updatedAt:Float;
}
