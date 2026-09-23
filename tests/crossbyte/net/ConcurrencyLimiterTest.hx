package crossbyte.net;

import crossbyte.test.Require;
import utest.Assert;

class ConcurrencyLimiterTest extends utest.Test {
	private var now:Float;

	private function clock():Float {
		return now;
	}

	public function setup():Void {
		now = 0.0;
	}

	public function testCapacityIsGrantedUpToTheLimitAndNoFurther():Void {
		var limiter = new ConcurrencyLimiter(2, 0, 0, clock);
		var a = limiter.tryAcquire();
		var b = limiter.tryAcquire();
		Require.notNull(a);
		Require.notNull(b);
		Assert.isNull(limiter.tryAcquire());
		Assert.equals(2, limiter.inFlight);
		Assert.equals(0, limiter.available);

		Assert.isTrue(a.release());
		Assert.equals(1, limiter.inFlight);
		Assert.equals(1, limiter.available);
		Assert.notNull(limiter.tryAcquire());
	}

	public function testReleasingTwiceReturnsTheCapacityOnce():Void {
		// A counter that trusted every release would come out of this with a
		// slot that was never returned, and the limit would stop holding.
		var limiter = new ConcurrencyLimiter(1, 0, 0, clock);
		var permit = limiter.tryAcquire();
		Require.notNull(permit);

		Assert.isTrue(permit.release());
		Assert.isFalse(permit.release());
		Assert.equals(0, limiter.inFlight);
		Assert.notNull(limiter.tryAcquire());
		Assert.isNull(limiter.tryAcquire());
	}

	public function testAFreeSlotIsGrantedBeforeAcquireReturns():Void {
		var limiter = new ConcurrencyLimiter(1, 0, 0, clock);
		var seen:ConcurrencyPermit = null;
		var permit = limiter.acquire(p -> seen = p);

		Assert.equals(permit, seen);
		Assert.isTrue(permit.held);
		Assert.isFalse(permit.waiting);
		Assert.isNull(permit.rejection);
	}

	public function testWithoutAQueueASaturatedLimiterRefusesAtOnce():Void {
		var limiter = new ConcurrencyLimiter(1, 0, 0, clock);
		limiter.tryAcquire();
		var reasons:Array<String> = [];

		var permit = limiter.acquire(_ -> Assert.fail("granted past the limit"), r -> reasons.push(r));

		Assert.same(["saturated"], reasons);
		Assert.equals(ConcurrencyRejection.SATURATED, permit.rejection);
		Assert.isFalse(permit.held);
		Assert.isFalse(permit.waiting);
		Assert.isFalse(permit.release());
		Assert.equals(0, limiter.queued);
	}

	public function testWaitersAreGrantedInArrivalOrderAsCapacityReturns():Void {
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);
		var granted:Array<String> = [];
		var permits:Map<String, ConcurrencyPermit> = new Map();

		for (name in ["a", "b", "c"]) {
			limiter.acquire(p -> {
				granted.push(name);
				permits.set(name, p);
			});
		}
		Assert.equals(3, limiter.queued);
		Assert.same([], granted);

		holder.release();
		Assert.same(["a"], granted);
		permits.get("a").release();
		Assert.same(["a", "b"], granted);
		permits.get("b").release();
		Assert.same(["a", "b", "c"], granted);
		Assert.equals(0, limiter.queued);
		Assert.equals(1, limiter.inFlight);
	}

	public function testARequestFindingTheQueueFullIsRefused():Void {
		var limiter = new ConcurrencyLimiter(1, 2, 5.0, clock);
		limiter.tryAcquire();
		var reasons:Array<String> = [];

		limiter.acquire(_ -> {}, r -> reasons.push(r));
		limiter.acquire(_ -> {}, r -> reasons.push(r));
		var third = limiter.acquire(_ -> Assert.fail("granted from a full queue"), r -> reasons.push(r));

		Assert.same(["saturated"], reasons);
		Assert.equals(ConcurrencyRejection.SATURATED, third.rejection);
		Assert.equals(2, limiter.queued);
	}

	public function testAWaiterIsRefusedAtTheFirstSweepAfterItsDeadline():Void {
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		limiter.tryAcquire();
		var outcome:Array<String> = [];

		now = 1.0;
		var permit = limiter.acquire(_ -> outcome.push("granted"), r -> outcome.push(r));

		now = 5.9;
		Assert.equals(0, limiter.sweep());
		Assert.same([], outcome);
		Assert.isTrue(permit.waiting);

		now = 6.0;
		Assert.equals(1, limiter.sweep());
		Assert.same(["timed-out"], outcome);
		Assert.equals(ConcurrencyRejection.TIMED_OUT, permit.rejection);
		Assert.equals(0, limiter.queued);
	}

	public function testCapacityFreedAfterADeadlinePassesOverTheOverdueWaiter():Void {
		// Nothing swept between the first waiter's deadline and the release,
		// so it is still queued. It was due a refusal at 5; granting it at 6
		// would hand capacity to a caller that may already have given up.
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);
		var outcome:Array<String> = [];

		limiter.acquire(_ -> outcome.push("first granted"), r -> outcome.push('first $r'));
		now = 4.0;
		limiter.acquire(_ -> outcome.push("second granted"), r -> outcome.push('second $r'));

		now = 6.0;
		holder.release();
		Assert.same(["first timed-out", "second granted"], outcome);
	}

	public function testAWithdrawnWaiterHearsNothingAndGivesUpItsPlace():Void {
		var limiter = new ConcurrencyLimiter(1, 1, 5.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);

		var withdrawn = limiter.acquire(_ -> Assert.fail("granted after withdrawal"), _ -> Assert.fail("refused after withdrawal"));
		Assert.isTrue(withdrawn.release());
		Assert.isFalse(withdrawn.waiting);
		Assert.equals(0, limiter.queued);

		var next = limiter.acquire(_ -> {}, _ -> Assert.fail("its place was not freed"));
		Assert.isTrue(next.waiting);
		holder.release();
		Assert.isTrue(next.held);

		now = 100.0;
		Assert.equals(0, limiter.sweep());
	}

	public function testWithdrawnWaitersDoNotAccumulate():Void {
		// One waiter sits at the head the whole time, so nothing reaches it to
		// skip the withdrawn ones behind it. Without compaction every one of
		// these would still be in the array.
		var limiter = new ConcurrencyLimiter(1, 4, 60.0, clock);
		limiter.tryAcquire();
		var stuck = limiter.acquire(_ -> {});
		Assert.isTrue(stuck.waiting);

		for (_ in 0...100000) {
			limiter.acquire(_ -> {}).release();
		}

		Assert.equals(1, limiter.queued);
		var held:Int = @:privateAccess limiter.__queue.length;
		Assert.isTrue(held <= 2 * 4 + 64, 'the queue array holds $held entries for 1 waiter');
	}

	public function testALargeRequestIsNotOvertakenBySmallerOnes():Void {
		var limiter = new ConcurrencyLimiter(4, 10, 5.0, clock);
		var three = limiter.tryAcquire(3);
		Require.notNull(three);
		var granted:Array<String> = [];
		var permits:Map<String, ConcurrencyPermit> = new Map();

		limiter.acquire(p -> {
			granted.push("big");
			permits.set("big", p);
		}, 4);
		limiter.acquire(p -> granted.push("small"), 1);

		// One unit is free, but it is spoken for by the requests ahead.
		Assert.equals(1, limiter.available);
		Assert.isNull(limiter.tryAcquire(1));
		Assert.same([], granted);

		three.release();
		Assert.same(["big"], granted);
		permits.get("big").release();
		Assert.same(["big", "small"], granted);
	}

	public function testACostAboveTheWholeLimitIsRefusedWithoutWaiting():Void {
		var limiter = new ConcurrencyLimiter(4, 10, 5.0, clock);
		var reasons:Array<String> = [];

		var permit = limiter.acquire(_ -> Assert.fail("granted beyond the limit"), r -> reasons.push(r), 5);

		Assert.same(["exceeds-limit"], reasons);
		Assert.equals(ConcurrencyRejection.EXCEEDS_LIMIT, permit.rejection);
		Assert.equals(0, limiter.queued);
		Assert.isNull(limiter.tryAcquire(5));
	}

	public function testRaisingTheLimitAdmitsWaitersAndLoweringItRevokesNothing():Void {
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);
		var granted:Int = 0;
		limiter.acquire(_ -> granted++);
		limiter.acquire(_ -> granted++);

		limiter.limit = 3;
		Assert.equals(2, granted);
		Assert.equals(3, limiter.inFlight);

		limiter.limit = 1;
		Assert.equals(3, limiter.inFlight);
		Assert.equals(0, limiter.available);
		Assert.isNull(limiter.tryAcquire());

		// Still two in flight against a limit of one: nothing new gets in.
		holder.release();
		Assert.equals(2, limiter.inFlight);
		Assert.isNull(limiter.tryAcquire());
	}

	public function testAWaiterSurvivesTheLimitDippingBelowItsCost():Void {
		var limiter = new ConcurrencyLimiter(4, 10, 5.0, clock);
		var holder = limiter.tryAcquire(4);
		Require.notNull(holder);
		var outcome:Array<String> = [];
		limiter.acquire(_ -> outcome.push("granted"), r -> outcome.push(r), 3);

		limiter.limit = 2;
		holder.release();
		Assert.same([], outcome);
		Assert.equals(1, limiter.queued);

		limiter.limit = 3;
		Assert.same(["granted"], outcome);
	}

	public function testClosingRefusesEveryWaiterAndEveryRequestAfter():Void {
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);
		var reasons:Array<String> = [];
		limiter.acquire(_ -> Assert.fail("granted by a closed limiter"), r -> reasons.push(r));
		limiter.acquire(_ -> Assert.fail("granted by a closed limiter"), r -> reasons.push(r));

		limiter.close();
		Assert.same(["closed", "closed"], reasons);
		Assert.equals(0, limiter.queued);
		Assert.isTrue(limiter.closed);

		limiter.acquire(_ -> Assert.fail("granted after close"), r -> reasons.push(r));
		Assert.same(["closed", "closed", "closed"], reasons);
		Assert.isNull(limiter.tryAcquire());

		// What was already held drains as normal.
		Assert.equals(1, limiter.inFlight);
		Assert.isTrue(holder.release());
		Assert.equals(0, limiter.inFlight);
	}

	public function testGrantsReleasingInsideTheirCallbackDoNotNest():Void {
		// Each grant releases at once, which admits the next waiter. Delivered
		// nested, this would be 20000 frames deep; delivered in turn, never
		// more than one.
		var count:Int = 20000;
		var limiter = new ConcurrencyLimiter(1, count, 60.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);
		var order:Array<Int> = [];
		var depth:Int = 0;
		var deepest:Int = 0;

		for (i in 0...count) {
			limiter.acquire(permit -> {
				depth++;
				if (depth > deepest) {
					deepest = depth;
				}
				order.push(i);
				permit.release();
				depth--;
			});
		}

		holder.release();
		Assert.equals(count, order.length);
		Assert.equals(1, deepest);
		var inOrder:Bool = true;
		for (i in 0...order.length) {
			if (order[i] != i) {
				inOrder = false;
				break;
			}
		}
		Assert.isTrue(inOrder);
		Assert.equals(0, limiter.inFlight);
		Assert.equals(0, limiter.queued);
	}

	public function testAGrantCallbackMayAcquireAgain():Void {
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		var events:Array<String> = [];

		limiter.acquire(first -> {
			events.push("first granted");
			var second = limiter.acquire(_ -> events.push("second granted"));
			events.push(second.waiting ? "second queued" : "second not queued");
			first.release();
			events.push("first released");
		});

		Assert.same(["first granted", "second queued", "first released", "second granted"], events);
	}

	public function testReleaseDropsAGrantDecidedButNotYetDelivered():Void {
		// One limit change admits both waiters. The first one's callback
		// releases the second before the second has heard it was granted.
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);
		var second:ConcurrencyPermit = null;
		var heard:Array<String> = [];

		limiter.acquire(_ -> {
			heard.push("first");
			second.release();
		});
		second = limiter.acquire(_ -> heard.push("second"));
		Assert.equals(2, limiter.queued);

		limiter.limit = 3;
		Assert.same(["first"], heard);
		Assert.isFalse(second.held);
		Assert.equals(2, limiter.inFlight);
	}

	public function testAThrowingCallbackLosesNothing():Void {
		var limiter = new ConcurrencyLimiter(1, 10, 5.0, clock);
		var holder = limiter.tryAcquire();
		Require.notNull(holder);
		var heard:Array<String> = [];
		var first = limiter.acquire(_ -> throw "a callback's own bug");
		limiter.acquire(_ -> heard.push("second"));

		Assert.raises(() -> limiter.limit = 3);
		// Both were decided before either was told: the thrower holds its
		// capacity, and the other is waiting only to be delivered.
		Assert.isTrue(first.held);
		Assert.equals(3, limiter.inFlight);
		Assert.same([], heard);

		limiter.sweep();
		Assert.same(["second"], heard);
	}

	public function testConfigurationThatCannotWorkIsRefused():Void {
		Assert.raises(() -> new ConcurrencyLimiter(-1));
		Assert.raises(() -> new ConcurrencyLimiter(1, -1));
		Assert.raises(() -> new ConcurrencyLimiter(1, 10, 0));
		Assert.raises(() -> new ConcurrencyLimiter(1, 10, Math.NaN));
		Assert.raises(() -> new ConcurrencyLimiter(1).tryAcquire(0));
		Assert.raises(() -> new ConcurrencyLimiter(1).acquire(null));
	}

	public function testAnUnboundedWaitIsSpelledOutAndHonoured():Void {
		var limiter = new ConcurrencyLimiter(1, 10, Math.POSITIVE_INFINITY, clock);
		limiter.tryAcquire();
		var permit = limiter.acquire(_ -> {});

		now = 1e12;
		Assert.equals(0, limiter.sweep());
		Assert.isTrue(permit.waiting);
	}
}
