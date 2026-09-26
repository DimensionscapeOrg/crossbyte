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
	 * Seconds until `key` could spend `cost` tokens: `0` when it could now,
	 * and `Math.POSITIVE_INFINITY` for a cost above the bucket's capacity,
	 * which it never could. What a `Retry-After` should say. Spends nothing.
	 */
	public function secondsUntil(key:String, cost:Int = 1):Float {
		if (cost < 1) {
			throw "cost must be at least 1";
		}
		if (cost > __capacity) {
			return Math.POSITIVE_INFINITY;
		}
		if (key == null) {
			key = "";
		}

		var bucket:Null<Bucket> = __peek(key);
		if (bucket == null) {
			return 0;
		}

		var now:Float = __clock();
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
	 * on the whole address let one client take a new bucket per request --
	 * a thousand attempts from one /64 against a limit of five were refused
	 * none of the time. An IPv4-mapped IPv6 address (`::ffff:192.0.2.1`, what
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
