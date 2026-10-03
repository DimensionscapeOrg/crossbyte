package crossbyte.crypto;

import haxe.io.Bytes;
import utest.Assert;

/**
	`SecureRandom` natively hands out a thread's bytes from a pool it refills
	4 KB at a time, and draws of 1 KB or more straight from the system.

	These hold the pool to what one system call per draw gave: every length
	asked for, no draw repeating another, across refills, and between
	threads drawing at once, which would share bytes if the pool were not
	each thread's own, and none handing back the zeros a used range is
	wiped to.
**/
class SecureRandomTest extends utest.Test {
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
