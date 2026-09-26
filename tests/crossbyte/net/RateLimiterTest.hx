package crossbyte.net;

import utest.Assert;

class RateLimiterTest extends utest.Test {
	private var now:Float;

	private function clock():Float {
		return now;
	}

	public function setup():Void {
		now = 0.0;
	}

	public function testBurstUpToCapacityThenDenies():Void {
		var limiter = new RateLimiter(10, 60.0, clock);

		for (_ in 0...10) {
			Assert.isTrue(limiter.tryAcquire("client"));
		}
		Assert.isFalse(limiter.tryAcquire("client"));
		Assert.isTrue(limiter.isRateLimited("client"));
	}

	public function testPartialRefillGrantsExactlyRefilledAmount():Void {
		// 10 tokens per 10 seconds = 1 token/second.
		var limiter = new RateLimiter(10, 10.0, clock);
		for (_ in 0...10) {
			Assert.isTrue(limiter.tryAcquire("client"));
		}
		Assert.isFalse(limiter.tryAcquire("client"));

		now = 2.5;
		Assert.isTrue(limiter.tryAcquire("client"));
		Assert.isTrue(limiter.tryAcquire("client"));
		Assert.isFalse(limiter.tryAcquire("client"));
	}

	public function testNoDoubleBurstAcrossPeriodBoundary():Void {
		var limiter = new RateLimiter(10, 1.0, clock);
		for (_ in 0...10) {
			Assert.isTrue(limiter.tryAcquire("client"));
		}

		// A full idle period refills to capacity — exactly 10 more, never 20.
		now = 1.0;
		for (_ in 0...10) {
			Assert.isTrue(limiter.tryAcquire("client"));
		}
		Assert.isFalse(limiter.tryAcquire("client"));
	}

	public function testKeysAreIsolated():Void {
		var limiter = new RateLimiter(1, 60.0, clock);
		Assert.isTrue(limiter.tryAcquire("a"));
		Assert.isFalse(limiter.tryAcquire("a"));
		Assert.isTrue(limiter.tryAcquire("b"));
	}

	public function testCostAcquisition():Void {
		var limiter = new RateLimiter(10, 60.0, clock);

		Assert.isTrue(limiter.tryAcquire("client", 5));
		Assert.isTrue(limiter.tryAcquire("client", 5));
		Assert.isFalse(limiter.tryAcquire("client", 5));
		// Smaller cost also fails once tokens are exhausted.
		Assert.isFalse(limiter.tryAcquire("client"));

		// Cost above capacity can never succeed and consumes nothing.
		Assert.isFalse(limiter.tryAcquire("fresh", 11));
		Assert.equals(10, limiter.remaining("fresh"));

		Assert.raises(() -> limiter.tryAcquire("client", 0));
	}

	public function testRemainingReflectsRefillWithoutConsuming():Void {
		var limiter = new RateLimiter(10, 10.0, clock);
		Assert.equals(10, limiter.remaining("client"));

		for (_ in 0...10) {
			limiter.tryAcquire("client");
		}
		Assert.equals(0, limiter.remaining("client"));

		now = 3.0;
		Assert.equals(3, limiter.remaining("client"));
		Assert.equals(3, limiter.remaining("client"));
	}

	public function testResetRestoresFullCapacity():Void {
		var limiter = new RateLimiter(1, 60.0, clock);
		Assert.isTrue(limiter.tryAcquire("client"));
		Assert.isFalse(limiter.tryAcquire("client"));

		limiter.reset("client");
		Assert.isTrue(limiter.tryAcquire("client"));
	}

	public function testIdleBucketsAreEvicted():Void {
		var limiter = new RateLimiter(2, 1.0, clock);
		limiter.tryAcquire("idle");
		Assert.equals(1, limiter.activeKeyCount());

		// After a full refill period of inactivity the bucket is
		// indistinguishable from fresh state, and two periods of it drop it.
		now = 2.0;
		limiter.tryAcquire("active");
		Assert.equals(1, limiter.activeKeyCount());
	}

	public function testIdleKeysGoWithinTwoPeriods():Void {
		var limiter = new RateLimiter(2, 1.0, clock);
		limiter.tryAcquire("idle");
		now = 0.5;
		limiter.tryAcquire("active");
		Assert.equals(2, limiter.activeKeyCount());

		// Kept while it could still be short of tokens; gone once two
		// periods have passed without it. The one in use stays.
		now = 1.0;
		limiter.tryAcquire("active");
		now = 2.0;
		limiter.tryAcquire("active");
		Assert.equals(1, limiter.activeKeyCount());
		Assert.equals(2, limiter.remaining("idle"));
	}

	public function testADrainedKeyStaysDrainedAcrossAGeneration():Void {
		// One token a second, and a generation changes every ten.
		var limiter = new RateLimiter(10, 10.0, clock);
		now = 9.5;
		for (_ in 0...10) {
			Assert.isTrue(limiter.tryAcquire("client"));
		}

		// The first call past the change moves the bucket, and must not
		// refill it: half a second has earned half a token.
		now = 10.0;
		Assert.isFalse(limiter.tryAcquire("client"));
		Assert.equals(0, limiter.remaining("client"));

		now = 11.0;
		Assert.isTrue(limiter.tryAcquire("client"));
		Assert.isFalse(limiter.tryAcquire("client"));
		Assert.equals(1, limiter.activeKeyCount());
	}

	public function testTheKeyCountIsCapped():Void {
		var limiter = new RateLimiter(1, 60.0, clock, 3);
		for (key in ["a", "b", "c"]) {
			Assert.isTrue(limiter.tryAcquire(key));
		}

		// Past the cap new keys share one bucket, spent by the first of them.
		Assert.isTrue(limiter.tryAcquire("d"));
		Assert.isFalse(limiter.tryAcquire("e"));
		Assert.isFalse(limiter.tryAcquire("f"));
		Assert.equals(0, limiter.remaining("g"));
		Assert.equals(3, limiter.activeKeyCount());

		// The keys held keep their own.
		Assert.isFalse(limiter.tryAcquire("a"));
		limiter.reset("a");
		Assert.equals(2, limiter.activeKeyCount());
		Assert.isTrue(limiter.tryAcquire("h"));
		Assert.isFalse(limiter.tryAcquire("h"));
		Assert.equals(3, limiter.activeKeyCount());
	}

	public function testHeldKeysKeepTheirBucketsThroughAFlood():Void {
		var limiter = new RateLimiter(2, 60.0, clock, 2);
		Assert.isTrue(limiter.tryAcquire("a"));
		Assert.isTrue(limiter.tryAcquire("b"));
		now = 30.0;
		Assert.isTrue(limiter.tryAcquire("b"));

		// A generation later both are still held, so the table is still
		// full: new keys share the overflow bucket, and a held key is
		// carried forward without counting twice.
		now = 60.0;
		Assert.isTrue(limiter.tryAcquire("x"));
		Assert.isTrue(limiter.tryAcquire("y"));
		Assert.isFalse(limiter.tryAcquire("z"));
		Assert.isTrue(limiter.tryAcquire("a"));
		Assert.isTrue(limiter.tryAcquire("a"));
		Assert.isFalse(limiter.tryAcquire("a"));
		Assert.equals(2, limiter.activeKeyCount());

		// "b" went unused for a period, so the next change drops it and a
		// new key gets a bucket of its own.
		now = 90.0;
		Assert.isTrue(limiter.tryAcquire("a"));
		now = 120.0;
		Assert.isTrue(limiter.tryAcquire("x"));
		Assert.isTrue(limiter.tryAcquire("x"));
		Assert.isFalse(limiter.tryAcquire("x"));
		Assert.equals(2, limiter.activeKeyCount());
	}

	public function testAnIdleGenerationMakesRoomBeforeItsTurn():Void {
		var limiter = new RateLimiter(1, 60.0, clock, 2);
		limiter.tryAcquire("a");
		limiter.tryAcquire("b");
		now = 59.0;
		limiter.tryAcquire("a");

		// Full of keys used a moment ago: a new one shares the overflow.
		now = 60.0;
		Assert.isTrue(limiter.tryAcquire("c"));
		Assert.isFalse(limiter.tryAcquire("d"));

		// A period after their last use those keys hold full buckets, so
		// they make way though their generation is not due to go until 120.
		now = 119.0;
		Assert.isTrue(limiter.tryAcquire("e"));
		Assert.equals(1, limiter.activeKeyCount());
	}

	public function testTheDefaultCapHolds():Void {
		// Keys are whatever a client sends: account names, addresses. They
		// were all kept, and swept inside whichever call found the sweep due.
		var limiter = new RateLimiter(1, 60.0, clock);
		for (i in 0...RateLimiter.DEFAULT_MAX_KEYS + 1000) {
			limiter.tryAcquire("user" + i);
		}
		Assert.equals(RateLimiter.DEFAULT_MAX_KEYS, limiter.activeKeyCount());
	}

	public function testBackwardsClockDoesNotMintTokens():Void {
		var limiter = new RateLimiter(2, 60.0, clock);
		now = 10.0;
		Assert.isTrue(limiter.tryAcquire("client"));

		now = 5.0;
		Assert.isTrue(limiter.tryAcquire("client"));
		Assert.isFalse(limiter.tryAcquire("client"));
	}

	public function testConstructorValidation():Void {
		Assert.raises(() -> new RateLimiter(0, 60.0));
		Assert.raises(() -> new RateLimiter(10, 0));
		Assert.raises(() -> new RateLimiter(10, -1));
		Assert.raises(() -> new RateLimiter(10, 60.0, null, 0));
	}
}
