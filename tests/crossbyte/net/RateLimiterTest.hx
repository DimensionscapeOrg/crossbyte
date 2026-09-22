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
		// indistinguishable from fresh state and gets swept on the next call.
		now = 2.0;
		limiter.tryAcquire("active");
		Assert.equals(1, limiter.activeKeyCount());
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
	}
}
