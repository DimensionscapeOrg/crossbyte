package crossbyte.crypto;

import haxe.io.Bytes;
import utest.Assert;

/**
	`SecureRandom` natively hands out a thread's bytes from a pool it refills
	4 KB at a time, and draws of 1 KB or more straight from the system.

	These hold the pool to what one system call per draw gives: every length
	asked for, no draw repeating another (across refills, and between
	threads drawing at once, which would share bytes if the pool were not
	each thread's own), and none handing back the zeros a used range is
	wiped to.
**/
class SecureRandomTest extends utest.Test {
	/**
		`fill` writes random bytes into the range it is given and nowhere
		else, leaves the ByteArray's length and position as they were, and
		refuses a range outside it, or a null ByteArray, before touching
		anything.
	**/
	public function testFillWritesOnlyTheRangeItIsGiven():Void {
		var bytes = crossbyte.io.ByteArray.fromBytes(Bytes.alloc(4096));
		if (!SecureRandom.isSupported) {
			Assert.raises(() -> SecureRandom.fill(bytes));
			return;
		}

		for (range in [[0, 4096], [0, 1], [5, 3], [100, 1000], [1024, 2048], [4095, 1], [4096, 0], [17, 4079]]) {
			var offset:Int = range[0];
			var length:Int = range[1];
			var data:Bytes = bytes;
			data.fill(0, data.length, 0xA5);
			bytes.position = 7;
			SecureRandom.fill(bytes, offset, length);
			Assert.equals(4096, bytes.length, 'the length changed filling $length from $offset');
			Assert.equals(7, bytes.position, 'the position changed filling $length from $offset');
			var outside:Int = 0;
			for (i in 0...data.length) {
				if ((i < offset || i >= offset + length) && data.get(i) != 0xA5) {
					outside++;
				}
			}
			Assert.equals(0, outside, '$outside bytes outside $length from $offset were written');
			if (length >= 64) {
				// Random bytes keep 0xA5 at about 1 in 256 places.
				var kept:Int = 0;
				for (i in offset...offset + length) {
					if (data.get(i) == 0xA5) {
						kept++;
					}
				}
				Assert.isTrue(kept < length / 32, '$kept of $length bytes from $offset were left as they were');
			}
		}

		// All of it by default, and from an offset to the end.
		var whole = crossbyte.io.ByteArray.fromBytes(Bytes.alloc(256));
		SecureRandom.fill(whole);
		var other = crossbyte.io.ByteArray.fromBytes(Bytes.alloc(256));
		SecureRandom.fill(other);
		Assert.notEquals((whole : Bytes).toHex(), (other : Bytes).toHex(), "two fills drew the same bytes");
		var tail = crossbyte.io.ByteArray.fromBytes(Bytes.alloc(256));
		SecureRandom.fill(tail, 200);
		var zeroed:Int = 0;
		for (i in 0...200) {
			if ((tail : Bytes).get(i) != 0) {
				zeroed++;
			}
		}
		Assert.equals(0, zeroed, "a fill from an offset wrote before it");

		for (bad in [[-1, 1], [0, 4097], [4096, 1], [10, -2], [4097, -1]]) {
			var data:Bytes = bytes;
			data.fill(0, data.length, 0x5A);
			Assert.raises(() -> SecureRandom.fill(bytes, bad[0], bad[1]), crossbyte.errors.RangeError, '${bad[1]} bytes from ${bad[0]} were not refused');
			var touched:Int = 0;
			for (i in 0...data.length) {
				if (data.get(i) != 0x5A) {
					touched++;
				}
			}
			Assert.equals(0, touched, 'a refused fill of ${bad[1]} from ${bad[0]} wrote $touched bytes');
		}
		Assert.raises(() -> SecureRandom.fill(null), crossbyte.errors.ArgumentError);
	}

	public function testDrawsAcrossThePoolAreUniqueAndUnwiped():Void {
		if (!SecureRandom.isSupported) {
			Assert.raises(() -> SecureRandom.getSecureRandomBytes(4));
			return;
		}

		// Lengths either side of the direct-draw threshold and the pool size.
		for (length in [1, 3, 4, 16, 1023, 1024, 4095, 4096, 4097, 10000]) {
			Assert.equals(length, SecureRandom.getSecureRandomBytes(length).length, 'length $length');
		}

		// 64 KB through the pool in 16-byte draws: sixteen refills, and each
		// draw's end lands on a refill now and then.
		var seen:Map<String, Bool> = new Map();
		var zeros:Int = 0;
		var total:Int = 0;
		var repeated:Int = 0;
		for (_ in 0...4096) {
			var draw:Bytes = SecureRandom.getSecureRandomBytes(16);
			var hex:String = draw.toHex();
			if (seen.exists(hex)) {
				repeated++;
			}
			seen.set(hex, true);
			for (i in 0...draw.length) {
				if (draw.get(i) == 0) {
					zeros++;
				}
			}
			total += draw.length;
		}
		Assert.equals(0, repeated, "a 16-byte draw repeated");
		// About 1 in 256 of random bytes is zero: 256 of these 65,536. A pool
		// handing out wiped bytes would give tens of thousands.
		Assert.isTrue(zeros < total / 64, '$zeros zero bytes of $total');

		// A draw that straddles a refill: odd sizes walk the boundary.
		for (size in [3, 5, 7, 11, 13, 1021]) {
			var straddle:Bytes = SecureRandom.getSecureRandomBytes(size);
			var run:Int = 0;
			var longest:Int = 0;
			for (i in 0...straddle.length) {
				run = straddle.get(i) == 0 ? run + 1 : 0;
				longest = run > longest ? run : longest;
			}
			Assert.isTrue(longest < 8, 'a run of $longest zero bytes in a draw of $size');
		}
	}

	#if (target.threaded && !eval)
	public function testThreadsDrawingAtOnceGetDifferentBytes():Void {
		if (!SecureRandom.isSupported) {
			Assert.pass();
			return;
		}

		var threads:Int = 4;
		var perThread:Int = 2000;
		var results:sys.thread.Deque<Array<String>> = new sys.thread.Deque();
		for (_ in 0...threads) {
			sys.thread.Thread.create(() -> {
				var mine:Array<String> = [];
				for (_ in 0...perThread) {
					var draw:Bytes = SecureRandom.getSecureRandomBytes(8);
					mine.push(draw.toHex());
				}
				results.add(mine);
			});
		}

		var seen:Map<String, Bool> = new Map();
		var repeated:Int = 0;
		var count:Int = 0;
		var deadline:Float = haxe.Timer.stamp() + 60;
		for (_ in 0...threads) {
			var batch:Null<Array<String>> = null;
			while (batch == null && haxe.Timer.stamp() < deadline) {
				batch = results.pop(false);
				if (batch == null) {
					crossbyte.sys.System.sleep(0.001);
				}
			}
			if (batch == null) {
				Assert.fail("a drawing thread did not finish within 60 s");
				return;
			}
			for (hex in batch) {
				if (seen.exists(hex)) {
					repeated++;
				}
				seen.set(hex, true);
				count++;
			}
		}
		Assert.equals(threads * perThread, count);
		Assert.equals(0, repeated, "two threads were handed the same bytes");
	}
	#end
}
