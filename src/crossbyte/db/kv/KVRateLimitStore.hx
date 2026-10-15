package crossbyte.db.kv;

import crossbyte.net.RateLimitBucket;
import crossbyte.net.RateLimitStore;
import haxe.io.Bytes;

/**
	A `RateLimitStore` in a `KVStore`: the buckets of every
	`crossbyte.net.RateLimiter` given it, shared by every process that opens
	the same store. Over `SQLiteKVStore`, one database file serves every PHP
	request, or every process of a server; over `PostgresKVStore`, several
	hosts.

	```haxe
	var limits = new KVRateLimitStore(SQLiteKVStore.open("data/limits.db", {table: "rate_limits"}));
	var logins = new crossbyte.net.RateLimiter(5, 60, limits);
	```

	Each check is a `get` and a `compareAndSet` on the bucket's revision, so
	two requests checking one key at once cannot both spend its last token.

	**A store of its own.** Give it a `KVStore` it alone uses (a table of its
	own in a shared database is enough): it removes the buckets that are full
	again, which are the same as none, and then the tombstones their removal
	left, with `purgeTombstones`, which reaches every record of the store.
	It does so on its own, a page of buckets at a time, after about one write
	in `sweepEvery` (as PHP collects its sessions), so the table holds
	roughly the keys seen in the last `perSeconds`, and no request pays for
	sweeping all of them. `removeExpired()` does it at once.

	Keys are kept as they are, under `prefix`, when they are short printable
	ASCII (an address from `RateLimiter.addressKey` is); any other is kept as
	its SHA-256, so a key a client chose (a login name, say) cannot be one the
	store refuses.
**/
class KVRateLimitStore implements RateLimitStore {
	/** `prefix` unless given. **/
	public static inline var DEFAULT_PREFIX:String = "ratelimit/";

	/** `sweepEvery` unless given. **/
	public static inline var DEFAULT_SWEEP_EVERY:Int = 1000;

	// The buckets examined, at most, by one sweep after a write.
	@:noCompletion private static inline var SWEEP_PAGE:Int = 200;

	// The longest key kept as it is; others are hashed.
	@:noCompletion private static inline var PLAIN_KEY_MOST:Int = 200;

	/** The store the buckets are kept in. **/
	public final store:KVStore;

	/** What every bucket's key starts with. **/
	public final prefix:String;

	/**
		One write in about this many sweeps a page of the buckets after it;
		`0` never does, leaving it to `removeExpired()`.
	**/
	public var sweepEvery:Int;

	// The time of day, as the limiter's own when it has none given.
	@:noCompletion private var __clock:Null<() -> Float>;

	/**
		@param store A `KVStore` this alone uses: see the class notes.
		@param prefix What the keys of the buckets start with.
		@param sweepEvery See `sweepEvery`.
		@param clock Seconds since the epoch, for the sweep to tell which
			buckets are full again: the time of day unless given. Give the
			same clock as the limiters, if they have one.
	**/
	public function new(store:KVStore, prefix:String = DEFAULT_PREFIX, sweepEvery:Int = DEFAULT_SWEEP_EVERY, ?clock:() -> Float) {
		if (store == null) {
			throw new crossbyte.errors.ArgumentError("KVRateLimitStore needs a store.");
		}
		if (prefix == null || prefix.length == 0) {
			throw new crossbyte.errors.ArgumentError("KVRateLimitStore needs a prefix: a key of the store cannot be empty.");
		}
		this.store = store;
		this.prefix = prefix;
		this.sweepEvery = sweepEvery;
		__clock = clock;
	}

	public function get(key:String):Null<RateLimitBucket> {
		var record:Null<KVRecord> = store.get(__bucketKey(key));
		if (record == null || record.value.length < BUCKET_BYTES) {
			return null;
		}
		return new RateLimitBucket(record.value.getDouble(0), record.value.getDouble(8), record.revision);
	}

	public function compareAndSet(key:String, tokens:Float, updatedAt:Float, fullAt:Float, expected:Float):Bool {
		var value:Bytes = Bytes.alloc(BUCKET_BYTES);
		value.setDouble(0, tokens);
		value.setDouble(8, updatedAt);
		value.setDouble(16, fullAt);
		var written:Bool = store.compareAndSet(__bucketKey(key), value, expected) != null;
		if (written && sweepEvery > 0 && Math.random() * sweepEvery < 1) {
			__sweep(SWEEP_PAGE);
		}
		return written;
	}

	public function delete(key:String):Void {
		store.delete(__bucketKey(key));
	}

	/**
		Removes every bucket full again by `now` (seconds since the epoch, the
		time of day unless given), and the tombstones the store keeps of them,
		and answers how many buckets went.
	**/
	public function removeExpired(?now:Float):Int {
		var removed:Int = 0;
		var after:Null<String> = null;
		while (true) {
			var page = store.scan({prefix: prefix + BUCKETS, startAfter: after, limit: KVScanOptions.DEFAULT_LIMIT});
			removed += __removeFull(page, now);
			if (page.next == null) {
				break;
			}
			after = page.next;
		}
		__purge(now);
		return removed;
	}

	// Each bucket's: tokens, when they were counted, when it is full again.
	@:noCompletion private static inline var BUCKET_BYTES:Int = 24;

	// Under the prefix: the buckets, and where the last sweep stopped.
	@:noCompletion private static inline var BUCKETS:String = "b/";
	@:noCompletion private static inline var CURSOR:String = "sweep";

	@:noCompletion private function __bucketKey(key:String):String {
		if (key == null) {
			key = "";
		}
		return prefix + BUCKETS + (__plain(key) ? key : "#" + haxe.crypto.Sha256.encode(key));
	}

	/** Whether `key` is kept as it is: short, printable ASCII, and not starting as a hash does. **/
	@:noCompletion private static function __plain(key:String):Bool {
		if (key.length > PLAIN_KEY_MOST || StringTools.startsWith(key, "#")) {
			return false;
		}
		for (i in 0...key.length) {
			var code:Int = StringTools.fastCodeAt(key, i);
			if (code < 0x20 || code > 0x7E) {
				return false;
			}
		}
		return true;
	}

	/**
		A page of buckets from where the last sweep stopped, the full ones
		among them removed, and where this one stopped kept for the next: no
		write pays for more than a page, and in turn every bucket is looked
		at.
	**/
	@:noCompletion private function __sweep(limit:Int):Void {
		var cursorKey:String = prefix + CURSOR;
		var cursor:Null<KVRecord> = store.get(cursorKey);
		var after:Null<String> = cursor == null ? null : cursor.value.toString();
		var page = store.scan({prefix: prefix + BUCKETS, startAfter: after, limit: limit});
		__removeFull(page, null);
		if (page.next == null) {
			// The end: the next sweep starts again from the first bucket, and
			// the tombstones of the buckets removed on the way go.
			if (cursor != null) {
				store.delete(cursorKey);
			}
			__purge(null);
		} else {
			store.put(cursorKey, Bytes.ofString(page.next));
		}
	}

	@:noCompletion private function __removeFull(page:KVPage<KVRecord>, now:Null<Float>):Int {
		var at:Float = now != null ? now : __now();
		var removed:Int = 0;
		for (record in page.items) {
			var fullAt:Float = record.value.length >= BUCKET_BYTES ? record.value.getDouble(16) : Math.NEGATIVE_INFINITY;
			// At its revision, so a bucket spent from since the page was read stays.
			if (fullAt <= at && store.compareAndDelete(record.key, record.revision)) {
				removed++;
			}
		}
		return removed;
	}

	/**
		The tombstones of buckets removed a minute or more ago. A check holds
		a bucket's revision only between its read and its write, so nothing
		still names one of those.
	**/
	@:noCompletion private function __purge(now:Null<Float>):Void {
		store.purgeTombstones((now != null ? now : __now()) - 60);
	}

	@:noCompletion private inline function __now():Float {
		// time of day: the buckets' times are, so that processes share them.
		return __clock != null ? __clock() : Date.now().getTime() / 1000;
	}
}
