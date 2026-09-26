package crossbyte.cluster;

import crossbyte.errors.ArgumentError;
import haxe.Int64;
import utest.Assert;

/**
	Identifiers that stay unique across machines.

	Pure arithmetic on an injected clock, so every target runs these and none
	of them waits for real time to pass.
**/
class SnowflakeIdTest extends utest.Test {
	/** Two nodes minting in the same millisecond do not collide. **/
	public function testTwoNodesInTheSameMillisecondDoNotCollide():Void {
		var now:Float = SnowflakeId.DEFAULT_EPOCH_MS + 1000;
		var clock = function():Float return now;

		var one = new SnowflakeId(1, SnowflakeId.DEFAULT_EPOCH_MS, clock);
		var two = new SnowflakeId(2, SnowflakeId.DEFAULT_EPOCH_MS, clock);

		var seen = new Map<String, Bool>();
		var duplicates:Int = 0;

		for (_ in 0...500) {
			for (id in [one.next(), two.next()]) {
				var key = Int64.toStr(id);

				if (seen.exists(key)) {
					duplicates++;
				}

				seen.set(key, true);
			}
		}

		Assert.equals(0, duplicates, "two nodes minted the same identifier " + duplicates + " times");
		Assert.equals(1, SnowflakeId.nodeOf(one.next()));
		Assert.equals(2, SnowflakeId.nodeOf(two.next()));
	}

	/**
		A clock that goes backwards does not reissue anything.

		Something adjusts the clock, or the machine resumes from sleep, and a
		generator that trusted it would hand out a range it had already spent.
	**/
	public function testAClockGoingBackwardsReissuesNothing():Void {
		var now:Float = SnowflakeId.DEFAULT_EPOCH_MS + 10000;
		var ids = new SnowflakeId(7, SnowflakeId.DEFAULT_EPOCH_MS, function():Float return now);

		var seen = new Map<String, Bool>();
		var duplicates:Int = 0;

		for (i in 0...200) {
			// Forwards, then a long way back, then forwards again.
			now = SnowflakeId.DEFAULT_EPOCH_MS + 10000 + (i % 3 == 0 ? -5000 : i);

			var key = Int64.toStr(ids.next());

			if (seen.exists(key)) {
				duplicates++;
			}

			seen.set(key, true);
		}

		Assert.equals(0, duplicates, "a backward clock produced " + duplicates + " repeats");
	}

	/**
		A millisecond's worth running out does not block and does not repeat.

		A server's loop is the worst place to sleep, so the generator moves
		on to the next millisecond instead and may run briefly ahead of the
		wall clock. What it may not do is hand the same number out twice.
	**/
	public function testExhaustingAMillisecondRollsForwardRatherThanRepeating():Void {
		var now:Float = SnowflakeId.DEFAULT_EPOCH_MS + 500;
		var ids = new SnowflakeId(3, SnowflakeId.DEFAULT_EPOCH_MS, function():Float return now);

		var seen = new Map<String, Bool>();
		var duplicates:Int = 0;
		var wanted:Int = (SnowflakeId.MAX_SEQUENCE + 1) * 3;

		// The clock never moves, so this is three milliseconds of capacity
		// asked for inside one.
		for (_ in 0...wanted) {
			var key = Int64.toStr(ids.next());

			if (seen.exists(key)) {
				duplicates++;
			}

			seen.set(key, true);
		}

		Assert.equals(0, duplicates, "a standing clock produced " + duplicates + " repeats");
	}

	/** Identifiers minted later sort after ones minted earlier. **/
	public function testIdentifiersSortByWhenTheyWereMinted():Void {
		var now:Float = SnowflakeId.DEFAULT_EPOCH_MS + 1;
		var ids = new SnowflakeId(5, SnowflakeId.DEFAULT_EPOCH_MS, function():Float return now);

		var previous:Int64 = ids.next();
		var outOfOrder:Int = 0;

		for (i in 0...200) {
			now = SnowflakeId.DEFAULT_EPOCH_MS + 1 + i;
			var id = ids.next();

			if (id <= previous) {
				outOfOrder++;
			}

			previous = id;
		}

		Assert.equals(0, outOfOrder, "identifiers went backwards " + outOfOrder + " times");
	}

	/**
		When an identifier says it was minted, for any time its forty one bits
		can hold. It was read through an Int, and threw Overflow for every
		identifier minted more than 24.8 days after the epoch.
	**/
	public function testTimestampOfReadsBackWhenAnIdWasMinted():Void {
		var day:Float = 24.0 * 60 * 60 * 1000;
		// A day in, a month in (past what an Int holds), a date in 2026, and
		// the last millisecond forty one bits reach.
		for (offset in [day, 31.0 * day, 1782864000000.0 - SnowflakeId.DEFAULT_EPOCH_MS, 2199023255551.0]) {
			var now:Float = SnowflakeId.DEFAULT_EPOCH_MS + offset;
			var ids = new SnowflakeId(9, SnowflakeId.DEFAULT_EPOCH_MS, function():Float return now);
			var id = ids.next();
			var read:Float = -1;
			try {
				read = SnowflakeId.timestampOf(id);
			} catch (e:Dynamic) {
				Assert.fail('timestampOf threw for $offset ms after the epoch: $e');
				continue;
			}
			Assert.equals(now, read, 'read back ${read - now} ms off, $offset ms after the epoch');
			Assert.equals(9, SnowflakeId.nodeOf(id));
		}
	}

	/** A node number outside the field it has to fit in is refused. **/
	public function testANodeNumberThatDoesNotFitIsRefused():Void {
		Assert.raises(function():Void {
			new SnowflakeId(SnowflakeId.MAX_NODE + 1);
		}, ArgumentError);

		Assert.raises(function():Void {
			new SnowflakeId(-1);
		}, ArgumentError);
	}
}
