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
 * Nothing in it is about HTTP: a
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
 * too, without waiting its turn. Retiring one is an assignment rather than
 * a sweep of every bucket inside whichever call found it due: keys are
 * whatever a client sends, and on Node such a sweep over two million of
 * them takes 815 ms inside one `tryAcquire`.
 *
 * `maxKeys` caps the keys held, across both generations. A key arriving
 * when the table is full shares one overflow bucket with every other such key,
 * so a flood of new keys is throttled as if it were one client while the keys
 * already held keep their own buckets. An optional injectable clock makes
 * behavior deterministic in tests.
 *
 * **Shared buckets.** Given a `RateLimitStore`, the limiter keeps its
 * buckets there instead, and every limiter on that store limits together: on
 * PHP, where each request is a process of its own and buckets in memory would
 * be gone with it, and for a service run as several processes or behind a
 * load balancer. The API is the same either way; a check is then one read
 * and one compare-and-set in the store, and its time is the time of day,
 * which processes share. `crossbyte.db.kv.KVRateLimitStore` is one, over
 * SQLite on PHP and natively:
 *
 * ```haxe
 * var store = new crossbyte.db.kv.KVRateLimitStore(crossbyte.db.kv.SQLiteKVStore.open("limits.db"));
 * var logins = new RateLimiter(5, 60, store);
 * if (!logins.tryAcquire(RateLimiter.addressKey(address))) {
 * 	// 429, with logins.secondsUntil(...) as its Retry-After.
 * }
 * ```
 *
 * `maxKeys` and `activeKeyCount` are about buckets held in memory; a store
 * holds as many as it is given, and forgets those full again.
 */
class RateLimiter {
	/** Keys held at most by default: 8 to 13 MB of buckets, by target. */
	public static inline var DEFAULT_MAX_KEYS:Int = 100000;

	@:noCompletion private var __capacity:Int;
	@:noCompletion private var __refillPerSecond:Float;
	@:noCompletion private var __period:Float;
	// The clock a test gave, or null for haxe.Timer.stamp, called directly:
	// natively a Float returned through a function value is boxed, 16 bytes
	// a request.
	@:noCompletion private var __clock:Null<() -> Float>;
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
	@:noCompletion private var __store:Null<RateLimitStore>;

	/**
		How often a check on a store reads its bucket again because another
		wrote it between the read and the write, before it refuses the
		request rather than let it through.
	**/
	@:noCompletion private static inline var STORE_ATTEMPTS:Int = 16;

	/**
	 * @param maxRequests Bucket capacity and sustained request budget.
	 * @param perSeconds The period over which `maxRequests` refills.
	 * @param clock Optional monotonic time source in seconds; defaults to
	 * `haxe.Timer.stamp`. Intended for tests.
	 * @param maxKeys Most keys held at once; a key arriving past it shares the
	 * overflow bucket. See the class notes.
	 * @param store Where the buckets are kept, shared with every limiter on
	 * it, instead of in memory: see the class notes. Its clock is the time of
	 * day, in seconds since the epoch, unless `clock` is given.
	 */
	public function new(maxRequests:Int = 10, perSeconds:Float = 60.0, ?clock:() -> Float, maxKeys:Int = DEFAULT_MAX_KEYS, ?store:RateLimitStore) {
		if (maxRequests < 1) {
			throw new crossbyte.errors.ArgumentError("maxRequests must be at least 1");
		}
		if (perSeconds <= 0 || !Math.isFinite(perSeconds)) {
			throw new crossbyte.errors.ArgumentError("perSeconds must be a positive finite number");
		}
		if (maxKeys < 1) {
			throw new crossbyte.errors.ArgumentError("maxKeys must be at least 1");
		}

		__capacity = maxRequests;
		__refillPerSecond = maxRequests / perSeconds;
		__period = perSeconds;
		__clock = clock;
		__maxKeys = maxKeys;
		__store = store;
		__current = new Map();
		__previous = new Map();
		var now:Float = __now();
		__currentUsedAt = now;
		__previousUsedAt = now;
		__rotateAt = now + perSeconds;
	}

	@:noCompletion private inline function __now():Float {
		return __clock != null ? __clock() : (__store != null ? __timeOfDay() : haxe.Timer.stamp());
	}

	// time of day: a store's buckets are read by other processes, which share
	// no monotonic clock with this one.
	@:noCompletion private static inline function __timeOfDay():Float {
		return Date.now().getTime() / 1000;
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
			throw new crossbyte.errors.ArgumentError("cost must be at least 1");
		}
		if (key == null) {
			key = "";
		}
		if (cost > __capacity) {
			return false;
		}
		if (__store != null) {
			return __stored(key, cost, true).allowed;
		}

		var bucket:Bucket = __bucketNow(key);
		if (bucket.tokens >= cost) {
			bucket.tokens -= cost;
			return true;
		}

		return false;
	}

	/**
		Attempts to consume `cost` tokens for `key`, as `tryAcquire` does,
		and answers what a server tells the client either way: the limit,
		what is left, and how long until it could try again (see
		`RateLimitResult`).
	**/
	public function consume(key:String, cost:Int = 1):RateLimitResult {
		if (cost < 1) {
			throw new crossbyte.errors.ArgumentError("cost must be at least 1");
		}
		if (key == null) {
			key = "";
		}
		if (__store != null) {
			return cost > __capacity ? __stored(key, 1, false).refused(cost) : __stored(key, cost, true).result();
		}
		if (cost > __capacity) {
			return __result(false, __tokensNow(key), cost);
		}

		var bucket:Bucket = __bucketNow(key);
		var allowed:Bool = bucket.tokens >= cost;
		if (allowed) {
			bucket.tokens -= cost;
		}
		return __result(allowed, bucket.tokens, cost);
	}

	/**
		The bucket `key` spends from now, refilled to now: carried forward
		into the newer generation, made, or past the cap the overflow bucket.
	**/
	@:noCompletion private inline function __bucketNow(key:String):Bucket {
		var now:Float = __now();
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
		return bucket;
	}

	/** The tokens `key` holds now in memory, without carrying its bucket forward. **/
	@:noCompletion private function __tokensNow(key:String):Float {
		var bucket:Null<Bucket> = __peek(key);
		if (bucket == null) {
			return __capacity;
		}
		var now:Float = __now();
		return now > bucket.updatedAt ? Math.min(__capacity, bucket.tokens + (now - bucket.updatedAt) * __refillPerSecond) : bucket.tokens;
	}

	/** What a check that found `tokens` tells its caller about a request costing `cost`. **/
	@:noCompletion private function __result(allowed:Bool, tokens:Float, cost:Int):RateLimitResult {
		var retryAfter:Float = if (cost > __capacity) {
			Math.POSITIVE_INFINITY;
		} else if (allowed || tokens >= cost) {
			0.0;
		} else {
			(cost - tokens) / __refillPerSecond;
		}
		return new RateLimitResult(allowed, __capacity, Math.floor(tokens), retryAfter, Math.max(0, (__capacity - tokens) / __refillPerSecond));
	}

	/**
		A check on the store: the bucket read, refilled to now, and with
		`spend` its tokens spent and written back if nobody wrote it
		meanwhile, read again when somebody did. A refusal, or a check that
		spends nothing, writes nothing: what is stored, and the time since,
		already say it.
	**/
	@:noCompletion private function __stored(key:String, cost:Int, spend:Bool):StoredCheck {
		for (_ in 0...STORE_ATTEMPTS) {
			var now:Float = __now();
			var bucket:Null<RateLimitBucket> = __store.get(key);
			var tokens:Float = __capacity;
			var counted:Float = now;
			var expected:Float = 0;
			if (bucket != null) {
				expected = bucket.revision;
				tokens = bucket.tokens;
				counted = bucket.updatedAt;
				// Never back: a process whose clock is behind another's must
				// not count the same seconds' tokens twice.
				if (now > counted) {
					tokens = Math.min(__capacity, tokens + (now - counted) * __refillPerSecond);
					counted = now;
				}
			}
			if (!spend) {
				return new StoredCheck(this, tokens >= cost, tokens, cost);
			}
			if (tokens < cost) {
				return new StoredCheck(this, false, tokens, cost);
			}
			var left:Float = tokens - cost;
			if (__store.compareAndSet(key, left, counted, counted + (__capacity - left) / __refillPerSecond, expected)) {
				return new StoredCheck(this, true, left, cost);
			}
		}
		// Written by others between every read and write: refused, which is
		// the side a limiter errs on.
		return new StoredCheck(this, false, 0, cost);
	}

	/**
	 * Seconds until `key` could spend `cost` tokens: `0` when it could now,
	 * and `Math.POSITIVE_INFINITY` for a cost above the bucket's capacity,
	 * which it never could. What a `Retry-After` should say. Spends nothing.
	 */
	public function secondsUntil(key:String, cost:Int = 1):Float {
		if (cost < 1) {
			throw new crossbyte.errors.ArgumentError("cost must be at least 1");
		}
		if (cost > __capacity) {
			return Math.POSITIVE_INFINITY;
		}
		if (key == null) {
			key = "";
		}
		if (__store != null) {
			return __stored(key, cost, false).result().retryAfter;
		}

		var bucket:Null<Bucket> = __peek(key);
		if (bucket == null) {
			return 0;
		}

		var now:Float = __now();
		var tokens:Float = bucket.tokens;
		if (now > bucket.updatedAt) {
			tokens = Math.min(__capacity, tokens + (now - bucket.updatedAt) * __refillPerSecond);
		}
		return tokens >= cost ? 0 : (cost - tokens) / __refillPerSecond;
	}

	/**
	 * The key a client address should be limited under.
	 *
	 * An IPv4 address is its own key. An IPv6 address is keyed by its first
	 * `prefixBits` bits, a /64 unless told otherwise: that is the block one
	 * subscriber is given, and every address in it is theirs to use, so keying
	 * on the whole address would let one client take a new bucket per
	 * request. An IPv4-mapped IPv6 address (`::ffff:192.0.2.1`, what
	 * a dual-stack listener reports for an IPv4 client) is keyed as the IPv4
	 * address it maps, so a client is one key whichever way it arrived. A
	 * zone (`%eth0`) and brackets are ignored. Anything that is not an address
	 * comes back as it was.
	 *
	 * The key for IPv6 is the prefix written out in full, every group, with
	 * the length: `2001:db8:1:2:0:0:0:0/64`.
	 */
	public static function addressKey(address:String, prefixBits:Int = 64):String {
		if (address == null) {
			return "";
		}
		if (address.indexOf(":") < 0) {
			return address;
		}

		var groups:Null<Array<Int>> = __parseIPv6(address);
		if (groups == null) {
			return address;
		}

		if (groups[0] == 0 && groups[1] == 0 && groups[2] == 0 && groups[3] == 0 && groups[4] == 0 && groups[5] == 0xFFFF) {
			return (groups[6] >> 8) + "." + (groups[6] & 0xFF) + "." + (groups[7] >> 8) + "." + (groups[7] & 0xFF);
		}

		if (prefixBits < 0) {
			prefixBits = 0;
		} else if (prefixBits > 128) {
			prefixBits = 128;
		}

		var key:StringBuf = new StringBuf();
		for (i in 0...8) {
			var kept:Int = prefixBits - i * 16;
			var group:Int = kept >= 16 ? groups[i] : (kept <= 0 ? 0 : groups[i] & ((0xFFFF << (16 - kept)) & 0xFFFF));
			if (i > 0) {
				key.add(":");
			}
			key.add(StringTools.hex(group).toLowerCase());
		}
		key.add("/");
		key.add(prefixBits);
		return key.toString();
	}

	/** The eight groups of an IPv6 address in text, or null when it is not one. */
	@:noCompletion private static function __parseIPv6(text:String):Null<Array<Int>> {
		if (StringTools.startsWith(text, "[") && StringTools.endsWith(text, "]")) {
			text = text.substr(1, text.length - 2);
		}
		var zone:Int = text.indexOf("%");
		if (zone >= 0) {
			text = text.substr(0, zone);
		}

		var halves:Array<String> = text.split("::");
		if (halves.length > 2) {
			return null;
		}

		var head:Null<Array<Int>> = __parseGroups(halves[0], halves.length == 1);
		var tail:Null<Array<Int>> = halves.length == 2 ? __parseGroups(halves[1], true) : [];
		if (head == null || tail == null) {
			return null;
		}

		var missing:Int = 8 - head.length - tail.length;
		if (halves.length == 1 ? missing != 0 : missing < 1) {
			return null;
		}

		var groups:Array<Int> = head;
		for (_ in 0...missing) {
			groups.push(0);
		}
		for (group in tail) {
			groups.push(group);
		}
		return groups;
	}

	/**
	 * Colon-separated groups of up to four hex digits, the last of which may
	 * be a dotted IPv4 address standing for two groups when `mayEndInIPv4`.
	 */
	@:noCompletion private static function __parseGroups(text:String, mayEndInIPv4:Bool):Null<Array<Int>> {
		var groups:Array<Int> = [];
		if (text.length == 0) {
			return groups;
		}

		var parts:Array<String> = text.split(":");
		for (i in 0...parts.length) {
			var part:String = parts[i];
			if (i == parts.length - 1 && mayEndInIPv4 && part.indexOf(".") >= 0) {
				var octets:Array<String> = part.split(".");
				if (octets.length != 4) {
					return null;
				}
				var values:Array<Int> = [];
				for (octet in octets) {
					if (octet.length == 0 || octet.length > 3) {
						return null;
					}
					var value:Int = crossbyte.utils.IntParse.decimal(octet, 255);
					if (value < 0) {
						return null;
					}
					values.push(value);
				}
				groups.push((values[0] << 8) | values[1]);
				groups.push((values[2] << 8) | values[3]);
				continue;
			}

			if (part.length == 0 || part.length > 4) {
				return null;
			}
			var group:Int = crossbyte.utils.IntParse.hex(part, 0xFFFF);
			if (group < 0) {
				return null;
			}
			groups.push(group);
		}
		return groups;
	}

	/**
	 * Returns the number of whole tokens currently available to `key`
	 * without consuming any.
	 */
	public function remaining(key:String):Int {
		if (key == null) {
			key = "";
		}
		if (__store != null) {
			return Math.floor(__stored(key, 1, false).tokens);
		}

		var bucket:Null<Bucket> = __peek(key);
		if (bucket == null) {
			return __capacity;
		}

		__refill(bucket, __now());
		return Math.floor(bucket.tokens);
	}

	/**
	 * Forgets `key`, restoring its full burst capacity.
	 *
	 * A null key is reset as the empty string, which is the key
	 * `tryAcquire` spends a null key's tokens from. A key sharing the
	 * overflow bucket (one that arrived with the table full; see `maxKeys`)
	 * has no bucket of its own to forget,
	 * and the shared one is left as it is: refilling it would refill every
	 * key sharing it.
	 */
	public function reset(key:String):Void {
		if (key == null) {
			key = "";
		}
		if (__store != null) {
			__store.delete(key);
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
	 * Number of keys currently holding bucket state in memory, never more
	 * than `maxKeys`: `0` for a limiter on a store, which holds them instead.
	 * Useful for monitoring and for verifying idle eviction.
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

/** What a check on the store found: its tokens, and whether its cost was spent. **/
@:noCompletion private class StoredCheck {
	public final allowed:Bool;
	public final tokens:Float;

	final __limiter:RateLimiter;
	final __cost:Int;

	public function new(limiter:RateLimiter, allowed:Bool, tokens:Float, cost:Int) {
		__limiter = limiter;
		this.allowed = allowed;
		this.tokens = tokens;
		__cost = cost;
	}

	public function result():RateLimitResult {
		return @:privateAccess __limiter.__result(allowed, tokens, __cost);
	}

	/** As refused for `cost`, which this check did not spend. **/
	public function refused(cost:Int):RateLimitResult {
		return @:privateAccess __limiter.__result(false, tokens, cost);
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
