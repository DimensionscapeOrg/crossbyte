package crossbyte.net;

import crossbyte.db.kv.KVRateLimitStore;
import crossbyte.db.kv.MemoryKVStore;
import utest.Assert;

/**
	`RateLimiter` over a `RateLimitStore`: limiters on one store limit
	together, as separate processes on one database do (separate PHP
	requests, say), a bucket refills with time, `consume` says what a 429
	says, and buckets full again are swept. In memory on every target, and
	on an SQLite file, opened twice, natively and on PHP.
**/
class RateLimitStoreTest extends utest.Test {
	public function testLimitersOnOneStoreLimitTogether():Void {
		var now:Float = 1000.0;
		var store = new KVRateLimitStore(new MemoryKVStore());
		__limitTogether(new RateLimiter(3, 60.0, () -> now, store), new RateLimiter(3, 60.0, () -> now, store), () -> now += 20);
	}

	public function testConsumeSaysWhatAResponseSays():Void {
		var now:Float = 1000.0;
		var limiter = new RateLimiter(3, 60.0, () -> now, new KVRateLimitStore(new MemoryKVStore()));
		var first = limiter.consume("a");
		Assert.isTrue(first.allowed);
		Assert.equals(3, first.limit);
		Assert.equals(2, first.remaining);
		Assert.equals(0.0, first.retryAfter);
		Assert.floatEquals(20.0, first.resetAfter);
		limiter.consume("a");
		limiter.consume("a");
		var refused = limiter.consume("a");
		Assert.isFalse(refused.allowed);
		Assert.equals(0, refused.remaining);
		Assert.floatEquals(20.0, refused.retryAfter, "a refusal did not say when one token would be back");
		Assert.floatEquals(60.0, refused.resetAfter);
		Assert.equals(Math.POSITIVE_INFINITY, limiter.consume("a", 4).retryAfter, "a cost past the limit can never be spent");

		// And the same from the limiter in memory.
		var memory = new RateLimiter(3, 60.0, () -> now);
		var inMemory = memory.consume("a");
		Assert.isTrue(inMemory.allowed);
		Assert.equals(2, inMemory.remaining);
		Assert.floatEquals(20.0, inMemory.resetAfter);
	}

	public function testBucketsFullAgainAreSwept():Void {
		var now:Float = 1000.0;
		var kv = new MemoryKVStore({clock: () -> now});
		var store = new KVRateLimitStore(kv, KVRateLimitStore.DEFAULT_PREFIX, 0, () -> now);
		var limiter = new RateLimiter(2, 10.0, () -> now, store);
		Assert.isTrue(limiter.tryAcquire("spent"));
		Assert.isTrue(limiter.tryAcquire("other"));
		Assert.equals(0, store.removeExpired(), "a bucket not yet full again was swept");
		now += 5;
		Assert.equals(2, store.removeExpired(), "buckets full again were kept");
		Assert.isNull(store.get("spent"));
		Assert.equals(2, limiter.remaining("spent"), "a swept bucket was not full");
		// A key the store would refuse as it is (a NUL, say) is kept as its hash.
		Assert.isTrue(limiter.tryAcquire("na\u0000me"));
		Assert.equals(1, limiter.remaining("na\u0000me"));
		limiter.reset("na\u0000me");
		Assert.equals(2, limiter.remaining("na\u0000me"));
	}

	#if (cpp || php)
	/** Two connections to one SQLite file: two processes, or two PHP requests. **/
	public function testLimitersOnOneSQLiteFileLimitTogether():Void {
		var directory:String = haxe.io.Path.join([Sys.getCwd(), "export"]);
		if (!sys.FileSystem.exists(directory)) {
			sys.FileSystem.createDirectory(directory);
		}
		var path:String = haxe.io.Path.join([directory, "ratelimit-" + Std.random(0x7FFFFFF) + ".db"]);
		var now:Float = 1000.0;
		var first = crossbyte.db.kv.SQLiteKVStore.open(path, {table: "rate_limits"});
		var second = crossbyte.db.kv.SQLiteKVStore.open(path, {table: "rate_limits"});
		try {
			__limitTogether(new RateLimiter(3, 60.0, () -> now, new KVRateLimitStore(first)),
				new RateLimiter(3, 60.0, () -> now, new KVRateLimitStore(second)), () -> now += 20);
		} catch (e:Dynamic) {
			first.close();
			second.close();
			throw e;
		}
		first.close();
		second.close();
		for (suffix in ["", "-wal", "-shm", "-journal"]) {
			try {
				if (sys.FileSystem.exists(path + suffix)) {
					sys.FileSystem.deleteFile(path + suffix);
				}
			} catch (_:Dynamic) {}
		}
	}
	#end

	/** Two limiters spend one bucket between them, and it refills for both. **/
	private static function __limitTogether(a:RateLimiter, b:RateLimiter, wait:Void->Void):Void {
		Assert.isTrue(a.tryAcquire("client"));
		Assert.isTrue(b.tryAcquire("client"));
		Assert.isTrue(a.tryAcquire("client"));
		Assert.isFalse(b.tryAcquire("client"), "the second limiter spent tokens the first had spent");
		Assert.isFalse(a.tryAcquire("client"));
		Assert.isTrue(a.tryAcquire("another"), "one key's limit reached another's");
		Assert.floatEquals(20.0, b.secondsUntil("client"));
		Assert.equals(0, b.remaining("client"));

		// A token a third of the period later, seen by both.
		wait();
		Assert.equals(1, a.remaining("client"));
		Assert.isTrue(b.tryAcquire("client"), "a token refilled was not there");
		Assert.isFalse(a.tryAcquire("client"), "one token refilled was spent twice");

		b.reset("client");
		Assert.equals(3, a.remaining("client"), "a reset through one limiter was not seen by the other");
	}
}
