package crossbyte.ds;

import utest.Assert;

class InterestSetTest extends utest.Test {
	private var seed:Int;

	public function setup():Void {
		seed = 0x68E31DA4;
	}

	private function random(bound:Int):Int {
		seed ^= seed << 13;
		seed ^= seed >>> 17;
		seed ^= seed << 5;
		return (seed & 0x7FFFFFFF) % bound;
	}

	private static function round(set:InterestSet, ids:Array<Int>):{entered:Array<Int>, left:Array<Int>} {
		for (id in ids) {
			set.add(id);
		}
		var entered:Array<Int> = [];
		var left:Array<Int> = [];
		set.commit(id -> entered.push(id), id -> left.push(id));
		return {entered: entered, left: left};
	}

	public function testTheFirstCommitReportsEverythingAsEntering():Void {
		var set = new InterestSet();
		var changes = round(set, [7, 3, 12]);

		Assert.same([7, 3, 12], changes.entered);
		Assert.same([], changes.left);
		Assert.equals(3, set.length);
	}

	public function testStayingIsSilentAndOnlyChangesAreReported():Void {
		var set = new InterestSet();
		round(set, [1, 2, 3, 4]);

		var changes = round(set, [2, 3, 9, 4, 10]);
		Assert.same([9, 10], changes.entered);
		Assert.same([1], changes.left);

		var unchanged = round(set, [10, 9, 4, 3, 2]);
		Assert.same([], unchanged.entered);
		Assert.same([], unchanged.left);

		// In the order the view they left was gathered in.
		var emptied = round(set, []);
		Assert.same([], emptied.entered);
		Assert.same([10, 9, 4, 3, 2], emptied.left);
		Assert.equals(0, set.length);
	}

	public function testAddingTwiceInARoundCountsOnce():Void {
		var set = new InterestSet();
		var changes = round(set, [5, 5, 6, 5]);

		Assert.same([5, 6], changes.entered);
		Assert.equals(2, set.length);
	}

	public function testTheViewIsTheRoundCommittedNotTheOneBeingGathered():Void {
		var set = new InterestSet();
		round(set, [1, 2]);

		set.add(3);
		Assert.isFalse(set.has(3));
		Assert.isTrue(set.has(1));
		Assert.equals(2, set.length);
		Assert.same([1, 2], [for (id in set) id]);

		set.commit();
		Assert.isTrue(set.has(3));
		Assert.isFalse(set.has(1));
		Assert.same([3], [for (id in set) id]);
	}

	public function testAReusedIdIsNoChangeUntilItIsForgotten():Void {
		// Slot 5 holds one entity, which is destroyed, and then another which
		// takes the same slot, in view both times. As bits nothing moved.
		var set = new InterestSet();
		round(set, [5]);
		var unnoticed = round(set, [5]);
		Assert.same([], unnoticed.entered);

		// Forgotten when the first one was destroyed, the second enters.
		Assert.isTrue(set.forget(5));
		Assert.isFalse(set.has(5));
		Assert.equals(0, set.length);
		var noticed = round(set, [5]);
		Assert.same([5], noticed.entered);
		Assert.same([], noticed.left);
	}

	public function testAForgottenIdOutOfViewIsNotReportedAsLeaving():Void {
		var set = new InterestSet();
		round(set, [1, 2, 3]);
		set.forget(2);

		var changes = round(set, [1]);
		Assert.same([3], changes.left);
		Assert.isFalse(set.forget(2));
	}

	public function testClearingForgetsWithoutReporting():Void {
		var set = new InterestSet();
		round(set, [1, 2]);
		set.add(3);
		set.clear();

		Assert.equals(0, set.length);
		var changes = round(set, [2, 4]);
		Assert.same([2, 4], changes.entered);
		Assert.same([], changes.left);
	}

	public function testIdsFarApartCostNothingBetweenThem():Void {
		var set = new InterestSet();
		var changes = round(set, [0, 1000000]);
		Assert.same([0, 1000000], changes.entered);

		var next = round(set, [1000000, 2000000]);
		Assert.same([2000000], next.entered);
		Assert.same([0], next.left);
	}

	public function testManyRandomRoundsMatchPlainSetDifferences():Void {
		var set = new InterestSet();
		var previous:Array<Int> = [];
		var mismatches:Array<String> = [];

		for (r in 0...500) {
			var current:Array<Int> = [];
			var seen:Map<Int, Bool> = new Map();
			for (_ in 0...random(40)) {
				var id:Int = random(200);
				if (!seen.exists(id)) {
					seen.set(id, true);
					current.push(id);
				}
			}

			var inPrevious:Map<Int, Bool> = [for (id in previous) id => true];
			var expectedLeft:Array<Int> = [for (id in previous) if (!seen.exists(id)) id];
			var expectedEntered:Array<Int> = [for (id in current) if (!inPrevious.exists(id)) id];

			var changes = round(set, current);
			if (changes.entered.join(",") != expectedEntered.join(",") || changes.left.join(",") != expectedLeft.join(",")) {
				mismatches.push('round $r');
			}
			if (set.length != current.length) {
				mismatches.push('length at round $r');
			}
			previous = current;
		}

		Assert.same([], mismatches);
		// What is held is what is in view, however many rounds came before.
		var held:Int = @:privateAccess set.__viewIds.length;
		Assert.equals(previous.length, held);
	}

	public function testAnAddFromACallbackGoesIntoTheNextRound():Void {
		var set = new InterestSet();
		set.add(1);
		set.commit(id -> set.add(id + 100));

		Assert.same([1], [for (id in set) id]);
		var changes = round(set, []);
		Assert.same([101], changes.entered);
		Assert.same([1], changes.left);
	}

	public function testCommitFromInsideItsOwnCallbackIsRefused():Void {
		var set = new InterestSet();
		set.add(1);
		Assert.raises(() -> set.commit(_ -> set.commit()));

		// And the set is usable afterwards.
		var changes = round(set, [2]);
		Assert.same([2], changes.entered);
	}

	public function testANegativeIdIsRefused():Void {
		var set = new InterestSet();
		Assert.raises(() -> set.add(-1));
		Assert.isFalse(set.has(-1));
	}
}
