package crossbyte.net;

import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	`PeerClock` against exchanges whose truth is known: a peer clock a fixed
	offset from this one, and delays on each leg chosen by the case.
**/
class PeerClockTest extends utest.Test {
	// Where the peer's clock stands against this one in every case below.
	static inline var TRUTH:Float = 1000.25;

	// One exchange: asked at `at`, out for `there`, back for `back`, the peer
	// reading its clock the moment the question arrives.
	static function exchange(clock:PeerClock, at:Float, there:Float, back:Float):Bool {
		return clock.sample(at, at + there + TRUTH, at + there + back);
	}

	public function testNothingIsKnownBeforeAnExchange():Void {
		var clock = new PeerClock(4, () -> 7.0);
		Assert.isFalse(clock.synced);
		Assert.equals(0.0, clock.offset);
		Assert.equals(-1.0, clock.roundTrip);
		Assert.equals(Math.POSITIVE_INFINITY, clock.error);
		Assert.equals(0.0, clock.jitter);
		Assert.equals(0, clock.samples);
		Assert.equals(7.0, clock.now());
	}

	public function testASymmetricExchangeGivesTheOffsetExactly():Void {
		var clock = new PeerClock();
		Assert.isTrue(exchange(clock, 10, 0.05, 0.05));
		Assert.isTrue(clock.synced);
		Assert.floatEquals(TRUTH, clock.offset);
		Assert.floatEquals(0.1, clock.roundTrip);
		Assert.floatEquals(0.05, clock.error);
		Assert.equals(1, clock.samples);
	}

	public function testALopsidedExchangeIsOutByNoMoreThanItsError():Void {
		// All the delay on the way there: the peer read its clock as late as
		// it could have, which is the worst case the bound allows.
		var clock = new PeerClock();
		exchange(clock, 10, 0.3, 0);
		Assert.floatEquals(0.15, clock.error);
		Assert.floatEquals(TRUTH + 0.15, clock.offset);
		Assert.isTrue(Math.abs(clock.offset - TRUTH) <= clock.error + 1e-9);
	}

	public function testTheShortestRoundTripInTheWindowIsTheOneUsed():Void {
		var clock = new PeerClock(8);
		// Queueing on the way back makes each of these read the offset low.
		exchange(clock, 10, 0.01, 0.2);
		exchange(clock, 11, 0.01, 0.01);
		var best = clock.offset;
		// Longer, so not taken, though newer.
		Assert.isFalse(exchange(clock, 12, 0.01, 0.4));
		Assert.isFalse(exchange(clock, 13, 0.2, 0.01));
		Assert.floatEquals(best, clock.offset);
		Assert.floatEquals(0.02, clock.roundTrip);
		Assert.floatEquals(TRUTH, clock.offset);
		Assert.equals(4, clock.samples);
	}

	public function testATieGoesToTheNewer():Void {
		// Equal round trips, differently split: the newer is the one taken,
		// since its offset has had less time to drift. Delays a binary
		// fraction can hold, so the two round trips are equal exactly.
		var clock = new PeerClock(4);
		exchange(clock, 10, 0.375, 0.125);
		Assert.equals(TRUTH + 0.125, clock.offset);
		Assert.isTrue(exchange(clock, 11, 0.125, 0.375));
		Assert.equals(0.5, clock.roundTrip);
		Assert.equals(TRUTH - 0.125, clock.offset);

		// And when the shortest leaves and the window is searched instead: the
		// newer of the tie has taken the slot the shortest had, ahead of the
		// older one in the ring's storage, and still wins.
		var scanned = new PeerClock(3);
		exchange(scanned, 10, 0.0625, 0.0625); // the shortest, to be pushed out
		exchange(scanned, 11, 0.375, 0.125); // 0.5
		exchange(scanned, 12, 0.5, 0.5); // 1.0
		Assert.isTrue(exchange(scanned, 13, 0.125, 0.375)); // 0.5 again, in the shortest's slot
		Assert.equals(0.5, scanned.roundTrip);
		Assert.equals(TRUTH - 0.125, scanned.offset);
	}

	public function testWhenTheShortestLeavesTheWindowTheNextShortestTakesOver():Void {
		var clock = new PeerClock(3);
		exchange(clock, 10, 0.01, 0.01); // 0.02, the shortest
		exchange(clock, 11, 0.02, 0.03); // 0.05
		exchange(clock, 12, 0.02, 0.02); // 0.04, next shortest
		Assert.floatEquals(0.02, clock.roundTrip);

		// Pushes the first out. The window is now 0.05, 0.04 and this 0.08.
		Assert.isTrue(exchange(clock, 13, 0.06, 0.02));
		Assert.floatEquals(0.04, clock.roundTrip);
		Assert.floatEquals(TRUTH, clock.offset);
		Assert.equals(3, clock.samples);

		// And the 0.05 goes, which changes nothing: the 0.04 is still held.
		Assert.isFalse(exchange(clock, 14, 0.05, 0.05));
		Assert.floatEquals(0.04, clock.roundTrip);

		// Then the 0.04 goes too, and 0.08, 0.1 and this 0.09 are what is left.
		Assert.isTrue(exchange(clock, 15, 0.05, 0.04));
		Assert.floatEquals(0.08, clock.roundTrip);
		Assert.floatEquals(TRUTH + 0.02, clock.offset);
	}

	public function testAWindowOfOneFollowsEveryExchange():Void {
		var clock = new PeerClock(1);
		exchange(clock, 10, 0.01, 0.01);
		Assert.isTrue(exchange(clock, 11, 0.1, 0.1));
		Assert.floatEquals(0.2, clock.roundTrip);
		Assert.equals(1, clock.samples);
	}

	public function testAnExchangeThatCannotHaveHappenedIsNotTaken():Void {
		var clock = new PeerClock();
		exchange(clock, 10, 0.05, 0.05);
		var offset = clock.offset;

		Assert.isFalse(clock.sample(10, 10 + TRUTH, 9.9), "an answer before its question");
		Assert.isFalse(clock.sample(Math.NaN, 10 + TRUTH, 11));
		Assert.isFalse(clock.sample(10, Math.NaN, 11));
		Assert.isFalse(clock.sample(10, 10 + TRUTH, Math.NaN));
		Assert.isFalse(clock.sample(10, Math.POSITIVE_INFINITY, 11));
		Assert.isFalse(clock.sample(Math.NEGATIVE_INFINITY, 10, 11));
		Assert.isFalse(clock.sample(10, 10, Math.POSITIVE_INFINITY));

		Assert.equals(offset, clock.offset);
		Assert.equals(1, clock.samples);
		Assert.floatEquals(0.1, clock.roundTrip);
		Assert.equals(0.0, clock.jitter, "a refused exchange moved the jitter");
	}

	public function testAnInstantAnswerIsAnExchange():Void {
		var clock = new PeerClock();
		Assert.isTrue(clock.sample(10, 10 + TRUTH, 10));
		Assert.equals(0.0, clock.roundTrip);
		Assert.equals(0.0, clock.error);
		Assert.floatEquals(TRUTH, clock.offset);
	}

	public function testJitterIsSmoothedFromOneRoundTripToTheNext():Void {
		var clock = new PeerClock();
		exchange(clock, 10, 0.05, 0.05); // 0.1: nothing to compare with yet
		Assert.equals(0.0, clock.jitter);
		exchange(clock, 11, 0.1, 0.1); // 0.2: differs by 0.1
		Assert.floatEquals(0.1 / 16, clock.jitter);
		exchange(clock, 12, 0.1, 0.1); // 0.2 again: differs by nothing
		var steady = 0.1 / 16 * 15 / 16;
		Assert.floatEquals(steady, clock.jitter);
		exchange(clock, 13, 0.05, 0.05); // 0.1: differs by 0.1, falling
		Assert.floatEquals(steady + (0.1 - steady) / 16, clock.jitter);
	}

	public function testThePeersTimeIsReadThroughTheOffset():Void {
		var local = 50.0;
		var clock = new PeerClock(4, () -> local);
		exchange(clock, 10, 0.05, 0.05);
		Assert.floatEquals(50 + TRUTH, clock.now());
		local = 60;
		Assert.floatEquals(60 + TRUTH, clock.now());
		Assert.floatEquals(3 + TRUTH, clock.toPeer(3));
		Assert.floatEquals(3, clock.toLocal(3 + TRUTH));
		Assert.floatEquals(42, clock.toLocal(clock.toPeer(42)));
	}

	public function testResetForgetsEverything():Void {
		var clock = new PeerClock(2);
		exchange(clock, 10, 0.01, 0.01);
		exchange(clock, 11, 0.2, 0.2);
		clock.reset();

		Assert.isFalse(clock.synced);
		Assert.equals(0.0, clock.offset);
		Assert.equals(-1.0, clock.roundTrip);
		Assert.equals(Math.POSITIVE_INFINITY, clock.error);
		Assert.equals(0.0, clock.jitter);
		Assert.equals(0, clock.samples);

		// Nothing from before comes back: a longer exchange than the old best
		// is taken, with no jitter against the last round trip before the
		// reset, and the old best does not return when the slots turn over.
		exchange(clock, 20, 0.1, 0.1);
		Assert.floatEquals(0.2, clock.roundTrip);
		Assert.equals(0.0, clock.jitter);
		exchange(clock, 21, 0.15, 0.15);
		exchange(clock, 22, 0.15, 0.15);
		Assert.floatEquals(0.3, clock.roundTrip);
	}

	public function testAWindowOfNothingIsRefused():Void {
		Assert.raises(() -> new PeerClock(0), ArgumentError);
		Assert.raises(() -> new PeerClock(-3), ArgumentError);
	}

	public function testTheTruthIsAlwaysWithinTheError():Void {
		// Random exchanges, each leg delayed anywhere from nothing to 200 ms,
		// the peer reading its clock the moment a question arrives. Whatever
		// the window has chosen, the truth must lie within the bound.
		var clock = new PeerClock(8);
		// Park and Miller's generator, in floats: exact and the same on every
		// target, where an Int product would wrap on some and not on others.
		// Seeded with a float literal, because eval keeps an Int assigned to
		// a Float as an Int, and multiplies it as one.
		var seed:Float = 12345.0;
		var outside = 0;
		for (i in 0...2000) {
			seed = (seed * 16807) % 2147483647;
			var there = (seed % 2000) / 10000;
			seed = (seed * 16807) % 2147483647;
			var back = (seed % 2000) / 10000;
			exchange(clock, i, there, back);
			if (Math.abs(clock.offset - TRUTH) > clock.error + 1e-9) {
				outside++;
			}
		}
		Assert.equals(0, outside);
		Assert.isTrue(clock.error < 0.15, "a window of eight held no short exchange: " + clock.error);
	}
}
