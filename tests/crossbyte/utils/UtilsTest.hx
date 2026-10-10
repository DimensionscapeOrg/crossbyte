package crossbyte.utils;

import crossbyte.utils.Bucket;
import crossbyte.utils.ChecksumAlgorithm;
import crossbyte.utils.EnumUtil;
import crossbyte.utils.Hash;
import crossbyte.utils.MathUtil;
import crossbyte.utils.ObjectPool;
import crossbyte.utils.ObjectRecycler;
#if cpp
import crossbyte.utils.Random;
#end
import crossbyte.utils.ThreadPriority;
import crossbyte.utils.Version;
import haxe.io.Bytes;
import utest.Assert;

private enum UtilsTestEnum {
	Plain;
	Pair(left:Int, right:String);
}

private typedef PooledState = {
	id:Int,
	state:String
}

class UtilsTest extends utest.Test {
	public function testASeededRandomGivesTheSameSequenceOnEveryTarget():Void {
		// The one promise this class makes ("reproducible results when seeded",
		// in its own documentation). Its mixer multiplies by two constants chosen
		// to overflow, and on js nothing overflows unless wrapped, so seed 12345
		// would produce a different sequence there than anywhere else.
		// Reproducible per target is not reproducible; a replay, a procedural
		// world or a shared simulation crossing targets would diverge silently.
		Random.reseed(12345);

		Assert.equals(1200724404, Random.nextU32());
		Assert.equals(-372313751, Random.nextU32());
		Assert.equals(-1711358538, Random.nextU32());
		Assert.equals(1611630670, Random.nextU32());
		Assert.equals(-1896865725, Random.nextU32());
	}

	/**
		A range of more than 2^31 values draws from all of it.

		How many values a range holds is not counted in Int, which overflows
		from 2^31 up: counted that way, Random.int(0, 0x7FFFFFFF) would come out
		0 every time on eval and the jvm, and the full Int range would give only
		negative numbers everywhere. The counts are known answers: every target
		draws the same ones.
	**/
	public function testAWideRangeDrawsFromAllOfIt():Void {
		var random = new Random(99);
		var zero:Int = 0;
		var upperHalf:Int = 0;
		for (_ in 0...2000) {
			var x:Int = random.inti(0, 0x7FFFFFFF);
			if (x < 0) {
				Assert.fail("drew " + x + " from [0, 0x7FFFFFFF]");
				return;
			}
			if (x == 0) {
				zero++;
			}
			if (x >= 0x40000000) {
				upperHalf++;
			}
		}
		Assert.isTrue(zero < 2, zero + " of 2000 draws were 0");
		Assert.equals(1016, upperHalf);

		var negative:Int = 0;
		for (_ in 0...2000) {
			if (random.inti(0x80000000, 0x7FFFFFFF) < 0) {
				negative++;
			}
		}
		Assert.equals(979, negative);

		Random.reseed(4242);
		var staticZero:Int = 0;
		for (_ in 0...200) {
			if (Random.int(0, 0x7FFFFFFF) == 0) {
				staticZero++;
			}
		}
		Assert.isTrue(staticZero < 2, staticZero + " of 200 static draws were 0");
	}

	/**
		Every range narrow enough not to overflow draws exactly the known values
		it always has, so a seeded sequence (a replay, a generated world) still
		reads the same.
	**/
	public function testANarrowRangeDrawsWhatItAlwaysDid():Void {
		Random.reseed(12345);
		Assert.equals("52,54,78,67,47,72", [for (_ in 0...6) Random.int(0, 99)].join(","));
		var random = new Random(777);
		Assert.equals("502,-856,244,-791,16,557", [for (_ in 0...6) random.inti(-1000, 1000)].join(","));
		Assert.equals("960454248,910322303,270330903,1030871650", [for (_ in 0...4) random.inti(0, 0x3FFFFFFF)].join(","));
		Assert.equals("1038264881,1828833615,626482905,945631671", [for (_ in 0...4) random.inti(-5, 0x7FFFFFF0)].join(","));
		Assert.equals(5, random.inti(5, 4), "an empty range answers its minimum");
		Assert.equals(7, random.inti(7, 7));
	}

	/**
		The shared generator's own seed differs from one moment to the next.

		It is not `Std.int(stamp * 1e6)`, which saturates on the jvm once its
		boot-relative clock passes 2^31 microseconds (36 minutes), so every jvm
		run would start from 0x7FFFFFFF and draw one sequence; hl and neko would
		get INT_MIN the same way.
	**/
	public function testTheUnseededSeedMovesWithTheClock():Void {
		var first:Int = @:privateAccess Random.defaultSeed();
		var until:Float = haxe.Timer.stamp() + 0.003;
		while (haxe.Timer.stamp() < until) {}
		var second:Int = @:privateAccess Random.defaultSeed();
		Assert.notEquals(first, second, "two seeds 3 ms apart were both " + first);
	}

	public function testHashesAreTheSameNumberOnEveryTarget():Void {
		// Known answers, not self-consistency. Every hash here multiplies by a
		// constant chosen to overflow, and that overflow is the mixing step,
		// so a target that does not wrap computes a different function while
		// looking perfectly healthy from inside. On JavaScript, unwrapped,
		// fnv1a32 of "sendData" comes back as -20905118279726560 rather than
		// 622618135, which shows only once two targets have to agree on an RPC
		// opcode.
		//
		// A test that hashed something and compared it to itself would pass
		// regardless. These are the values every other target produces.
		Assert.equals(622618135, Hash.fnv1a32String("sendData"));
		Assert.equals(1603980681, Hash.fnv1a32String("crossbyte"));
		Assert.equals(-2128831035, Hash.fnv1a32String("")); // the FNV offset basis, unchanged by an empty input
		Assert.equals(1200724404, Hash.fmix32(12345));
		Assert.equals(432767108, Hash.combineHash32(7, 99));
	}

	public function testBucketHelpersClampAndMapDeterministically():Void {
		Assert.equals(1, Bucket.bucketCount(0, 5));
		Assert.equals(10, Bucket.bucketCount(10, 0));
		Assert.equals(4, Bucket.bucketCount(16, 4));

		for (hash in [0, 1, 2, 123456789, -123456789]) {
			var bucket = Bucket.toBucketIndex(hash, 3);
			Assert.isTrue(bucket >= 0);
			Assert.isTrue(bucket < 3);
		}

		Assert.equals(0, Bucket.toBucketIndex(99, 1));

		var phase = Bucket.phaseFromKey(7, 42, 100, 10);
		Assert.isTrue(phase >= 0);
		Assert.isTrue(phase < 100);
		Assert.equals(0, phase % 10);
	}

	public function testEnumUtilExtractsNamesAndParameters():Void {
		Assert.equals("Plain", EnumUtil.getValueName(Plain));
		Assert.same([], EnumUtil.getValue(Plain));

		var pair = Pair(3, "hi");
		Assert.equals("Pair", EnumUtil.getValueName(pair));
		Assert.same([3, "hi"], EnumUtil.getValue(pair));

		var info = EnumUtil.getNameValuePair(pair);
		Assert.equals("Pair", info.name);
		Assert.same([3, "hi"], info.value);
	}

	/**
		Each `ChecksumAlgorithm`, computed, against the published check values.
	**/
	public function testChecksumComputesEachAlgorithm():Void {
		var digits = haxe.io.Bytes.ofString("123456789");
		Assert.equals("cbf43926", Checksum.hex(CRC32, digits));
		Assert.equals("11e60398", Checksum.hex(ADLER32, haxe.io.Bytes.ofString("Wikipedia")));
		Assert.equals("d41d8cd98f00b204e9800998ecf8427e", Checksum.hex(MD5, haxe.io.Bytes.alloc(0)));
		Assert.equals("900150983cd24fb0d6963f7d28e17f72", Checksum.hex(MD5, haxe.io.Bytes.ofString("abc")));
		Assert.equals("a9993e364706816aba3e25717850c26c9cd0d89d", Checksum.hex(SHA1, haxe.io.Bytes.ofString("abc")));

		var xor = haxe.io.Bytes.alloc(3);
		xor.set(0, 0x01);
		xor.set(1, 0x02);
		xor.set(2, 0x84);
		Assert.equals("87", Checksum.hex(XOR, xor));

		// The value's bytes, most significant first, as it prints.
		var crc:haxe.io.Bytes = Checksum.compute(CRC32, digits);
		Assert.equals(4, crc.length);
		Assert.equals(0xCB, crc.get(0));
		Assert.equals(0x26, crc.get(3));
		Assert.equals(1, Checksum.compute(XOR, xor).length);
		Assert.equals(16, Checksum.compute(MD5, digits).length);
		Assert.equals(20, Checksum.compute(SHA1, digits).length);
	}

	public function testChecksumTakesARangeAndRefusesOneOutside():Void {
		var framed = haxe.io.Bytes.ofString("xx123456789yy");
		for (algorithm in [CRC32, ADLER32, MD5, SHA1, XOR]) {
			Assert.equals(Checksum.hex(algorithm, haxe.io.Bytes.ofString("123456789")), Checksum.hex(algorithm, framed, 2, 9), 'range for $algorithm');
			Assert.equals(Checksum.hex(algorithm, haxe.io.Bytes.ofString("123456789yy")), Checksum.hex(algorithm, framed, 2), 'to the end for $algorithm');
		}
		Assert.raises(() -> Checksum.compute(CRC32, framed, -1, 2), crossbyte.errors.RangeError);
		Assert.raises(() -> Checksum.compute(CRC32, framed, 12, 2), crossbyte.errors.RangeError);
		Assert.raises(() -> Checksum.compute(CRC32, framed, 14), crossbyte.errors.RangeError);
		Assert.raises(() -> Checksum.compute(CRC32, null), crossbyte.errors.ArgumentError);
		Assert.equals(Checksum.hex(CRC32, haxe.io.Bytes.alloc(0)), Checksum.hex(CRC32, framed, 13));
	}

	public function testUtilityEnumsExposeStableConstructors():Void {
		Assert.equals("CRC32", Type.enumConstructor(ChecksumAlgorithm.CRC32));
		Assert.equals("ADLER32", Type.enumConstructor(ChecksumAlgorithm.ADLER32));
		Assert.equals("SHA1", Type.enumConstructor(ChecksumAlgorithm.SHA1));
		Assert.equals("MD5", Type.enumConstructor(ChecksumAlgorithm.MD5));
		Assert.equals("XOR", Type.enumConstructor(ChecksumAlgorithm.XOR));

		Assert.equals("IDLE", Type.enumConstructor(ThreadPriority.IDLE));
		Assert.equals("NORMAL", Type.enumConstructor(ThreadPriority.NORMAL));
		Assert.equals("CRITICAL", Type.enumConstructor(ThreadPriority.CRITICAL));
		Assert.isFalse(ThreadPriority.IDLE == ThreadPriority.NORMAL);
		Assert.isTrue(ThreadPriority.NORMAL == ThreadPriority.NORMAL);
	}

	public function testHashHelpersAreDeterministic():Void {
		var bytes = Bytes.ofString("crossbyte");
		Assert.equals(Hash.fnv1a32(bytes), Hash.fnv1a32String("crossbyte"));
		Assert.notEquals(Hash.fnv1a32String("crossbyte"), Hash.fnv1a32String("crossbyte!"));
		Assert.equals(Hash.combineHash32(1, 2), Hash.combineHash32(1, 2));
		Assert.notEquals(Hash.combineHash32(1, 2), Hash.combineHash32(2, 1));
		Assert.notEquals(12345, Hash.fmix32(12345));
	}

	public function testMathUtilCoversCoreHelpers():Void {
		Assert.equals(5.0, MathUtil.clamp(7.0, 1.0, 5.0));
		Assert.equals(2.5, MathUtil.lerp(0.0, 10.0, 0.25));
		Assert.equals(0.25, MathUtil.invLerp(0, 20, 5));
		Assert.equals(8, MathUtil.nextPow2(5));
		Assert.isTrue(MathUtil.isPowerOfTwo(8));
		Assert.isFalse(MathUtil.isPowerOfTwo(10));
		Assert.equals(-1, MathUtil.sign(-5));
		Assert.equals(0, MathUtil.sign(0));
		Assert.equals(1, MathUtil.sign(5));
		Assert.equals(50.0, MathUtil.remap(0, 10, 0, 100, 5));
		Assert.equals(9, MathUtil.wrap(-1, 0, 10));
		Assert.equals(2, MathUtil.wrap(12, 0, 10));
	}

	/**
		`nextPow2` answers the same on every target at the top of the range.
		Past 2^30 the answer is 2^31, which native targets wrap to -2147483648
		and JavaScript, whose Int does not wrap, gives as 2147483648.
		`INT32_MIN` answers 0, as all below zero do, rather than 2^31 by
		wrapping `n - 1`, which C++ leaves undefined.
	**/
	public function testNextPow2AgreesAcrossTargetsAtTheTop():Void {
		Assert.equals(1, MathUtil.nextPow2(1));
		Assert.equals(2, MathUtil.nextPow2(2));
		Assert.equals(4, MathUtil.nextPow2(3));
		Assert.equals(1 << 30, MathUtil.nextPow2((1 << 29) + 1));
		Assert.equals(1 << 30, MathUtil.nextPow2(1 << 30));
		Assert.equals(1 << 31, MathUtil.nextPow2((1 << 30) + 1));
		Assert.equals(1 << 31, MathUtil.nextPow2(0x7FFFFFFF));
		Assert.equals(0, MathUtil.nextPow2(0));
		Assert.equals(0, MathUtil.nextPow2(-5));
		Assert.equals(0, MathUtil.nextPow2(MathUtil.INT32_MIN));
	}

	public function testMathUtilWrapHandlesWideRangesWithoutCollapsing():Void {
		// Normal range still wraps correctly.
		Assert.equals(0, MathUtil.wrap(10, 0, 10));
		Assert.equals(5, MathUtil.wrap(5, 0, 10));

		// Wide range where (max - min) overflows 32-bit Int when computed naively:
		// it must wrap correctly, not collapse to `min`.
		var min:Int = MathUtil.INT32_MIN;
		var max:Int = MathUtil.INT32_MAX;
		Assert.isFalse(MathUtil.wrap(0, min, max) == min);
		Assert.equals(0, MathUtil.wrap(0, min, max));
		Assert.equals(min, MathUtil.wrap(min, min, max));
		Assert.equals(-1, MathUtil.wrap(-1, min, max));

		// Inverted/degenerate range still returns min.
		Assert.equals(5, MathUtil.wrap(7, 5, 5));
		Assert.equals(5, MathUtil.wrap(7, 5, 3));
	}

	public function testVersionHandlesShortAndMalformedStrings():Void {
		// Short string: missing segments resolve to 0 instead of crashing.
		var short:Version = "1.2";
		Assert.equals(1, short.major);
		Assert.equals(2, short.minor);
		Assert.equals(0, short.patch);
		Assert.equals(1002000, short.hash);

		// Malformed / non-numeric segments resolve to 0.
		var malformed:Version = "x.y";
		Assert.equals(0, malformed.major);
		Assert.equals(0, malformed.minor);
		Assert.equals(0, malformed.patch);
		Assert.equals(0, malformed.hash);

		// Empty string is fully robust.
		var empty:Version = "";
		Assert.equals(0, empty.major);
		Assert.equals(0, empty.hash);

		// Comparison semantics remain consistent with the constructed form.
		Assert.isTrue(short == new Version(1, 2, 0));
		Assert.isTrue(short < new Version(1, 2, 1));
		Assert.isTrue(short > new Version(1, 1, 9));
	}

	public function testAVersionSegmentTooBigForAnIntReadsTheSameOnEveryTarget():Void {
		// Std.parseInt gives 0 on Linux native, 2147483647 on Windows native,
		// throws on the jvm and gives a wider-than-Int number on JavaScript.
		var huge:Version = "1.4294967296.0";
		Assert.equals(1, huge.major);
		Assert.equals(999, huge.minor);
		Assert.isTrue(huge > new Version(1, 998, 0));

		// A suffix after the digits still reads as the digits.
		var suffixed:Version = "1.2.3-beta";
		Assert.equals(3, suffixed.patch);
	}

	public function testVersionHashIsStableAfterPerfChange():Void {
		// Verify the direct-component hash matches the legacy padded-concat values
		// and preserves ordering/equality across operators.
		Assert.equals(1002003, new Version(1, 2, 3).hash);
		Assert.equals(0, new Version(0, 0, 0).hash);
		Assert.equals(999999999, new Version(999, 999, 999).hash);

		Assert.isTrue(new Version(1, 9, 10) > new Version(1, 2, 99));
		Assert.isTrue(new Version(1, 2, 0) < new Version(1, 2, 1));
		Assert.isTrue(new Version(2, 0, 0) == new Version(2, 0, 0));
		Assert.isTrue(new Version(1, 9, 10) >= new Version(1, 9, 10));
		Assert.isTrue(new Version(1, 2, 0) <= new Version(1, 2, 0));
	}

	public function testObjectPoolTracksCapacityReuseAndReset():Void {
		var resets = [];
		var nextId = 0;
		var pool = new ObjectPool<{id:Int, tag:String}>(
			() -> {id: nextId++, tag: "fresh"},
			obj -> {
				obj.tag = "reset";
				resets.push(obj.id);
			}
		);

		var first = pool.acquire();
		Assert.equals(1, pool.capacity);
		Assert.equals(1, pool.inUse);
		Assert.equals(0, pool.freeCount);

		first.tag = "used";
		pool.release(first);
		Assert.equals(0, pool.inUse);
		Assert.equals(1, pool.freeCount);
		Assert.equals("reset", first.tag);

		var again = pool.acquire();
		Assert.equals(first, again);
		Assert.equals(1, pool.capacity);

		pool.reserve(3);
		Assert.equals(3, pool.freeCount);
		Assert.equals(4, pool.capacity);

		var resized = pool.resizeCapacity(2);
		Assert.equals(2, resized);
		Assert.equals(2, pool.capacity);
		Assert.equals(1, pool.inUse);
	}

	/**
		An object released twice is not lent to two owners: a release build does
		not keep both releases, which would make the next two acquires return
		one object. Debug builds check every release and throw.
	**/
	public function testADoubleReleaseDoesNotLendOneObjectTwice():Void {
		var pool = new ObjectPool<{id:Int}>(() -> {id: 0});
		var a = pool.acquire();
		pool.release(a);
		#if debug
		Assert.raises(() -> pool.release(a));
		#else
		pool.release(a);
		#end
		var x = pool.acquire();
		var y = pool.acquire();
		Assert.isFalse(x == y, "one object was lent twice");
		Assert.equals(2, pool.inUse);

		#if !debug
		// A release when everything the pool made is free is refused too.
		pool.release(x);
		pool.release(y);
		Assert.isFalse(pool.release({id: 99}), "a release past everything the pool made was kept");
		Assert.equals(2, pool.freeCount);
		#end
	}

	/** A burst leaves behind no more free objects than `maxFree`. **/
	public function testMaxFreeBoundsWhatABurstLeavesBehind():Void {
		var pool = new ObjectPool<{id:Int}>(() -> {id: 0});
		var burst = [for (_ in 0...1000) pool.acquire()];
		Assert.equals(1000, pool.capacity);
		pool.maxFree = 16;
		for (o in burst) {
			Assert.isTrue(pool.release(o));
		}
		Assert.equals(16, pool.freeCount);
		Assert.equals(16, pool.capacity, "objects let go still counted as made");
		Assert.equals(0, pool.inUse);
		var again = [for (_ in 0...20) pool.acquire()];
		Assert.equals(20, pool.capacity);
		Assert.equals(0, pool.freeCount);
		Assert.equals(20, again.length);
	}

	/**
		A pool keeps 10,000 free objects unless told otherwise, rather than
		every one released, which would leave a whole burst behind for the
		collector to walk at every collection from then on.
	**/
	public function testAPoolOfNegativeSizeIsRefused():Void {
		// As a stack is: the size goes to one. It ended the interpreter.
		try {
			new ObjectPool<{id:Int}>(() -> {id: 0}, null, -2);
			Assert.fail("a pool of -2 was made");
		} catch (e:crossbyte.errors.ArgumentError) {
			Assert.pass();
		}
	}

	public function testAPoolKeepsTenThousandFreeByDefault():Void {
		var pool = new ObjectPool<{id:Int}>(() -> {id: 0});
		Assert.equals(10000, pool.maxFree);

		var burst = [for (_ in 0...10050) pool.acquire()];
		for (o in burst) {
			pool.release(o);
		}

		Assert.equals(10000, pool.freeCount, "a burst of 10,050 left " + pool.freeCount + " behind");
		Assert.equals(10000, pool.capacity);
	}

	/**
		What is reserved is kept: a reservation past `maxFree` raises it, so
		objects made in advance are not let go after their first use.
	**/
	public function testAReservationIsKeptPastTheDefault():Void {
		var pool = new ObjectPool<{id:Int}>(() -> {id: 0}, null, 12000);
		Assert.equals(12000, pool.maxFree);

		var all = [for (_ in 0...12000) pool.acquire()];
		Assert.equals(12000, pool.capacity, "objects were made past the reservation");
		for (o in all) {
			pool.release(o);
		}
		Assert.equals(12000, pool.freeCount);

		pool.reserve(15000);
		Assert.equals(15000, pool.maxFree);
		Assert.equals(20000, pool.resizeCapacity(20000));
		Assert.equals(20000, pool.maxFree);

		// Lowered afterwards, it lets go of what is released past it; what
		// is free already stays until it is taken.
		pool.maxFree = 100;
		var some = [for (_ in 0...200) pool.acquire()];
		for (o in some) {
			pool.release(o);
		}
		Assert.equals(19800, pool.freeCount);
		Assert.equals(19800, pool.capacity);
	}

	/** A negative bound is refused, not read as "keep nothing" without a word. **/
	public function testANegativeMaxFreeIsRefused():Void {
		var pool = new ObjectPool<{id:Int}>(() -> {id: 0});
		Assert.raises(() -> pool.maxFree = -1, crossbyte.errors.ArgumentError);
		Assert.equals(10000, pool.maxFree);
		pool.maxFree = 0;
		var o = pool.acquire();
		pool.release(o);
		Assert.equals(0, pool.freeCount, "maxFree 0 kept an object");
	}

	public function testObjectRecyclerCachesLocallyAndDrainsToPool():Void {
		var pool:ObjectPool<PooledState> = new ObjectPool<PooledState>(
			() -> {id: 1, state: "fresh"},
			obj -> obj.state = "reset"
		);
		var recycler:ObjectRecycler<PooledState> = new ObjectRecycler<PooledState>(pool);

		var first = recycler.get();
		first.state = "used";
		recycler.recycle(first);
		Assert.equals(1, recycler.localSize());
		Assert.equals(0, pool.freeCount);
		Assert.equals("reset", first.state);

		var reused = recycler.get();
		Assert.equals(first, reused);
		Assert.equals(0, recycler.localSize());

		// Acquired from the pool, not built here. A pool only accepts back what
		// it handed out (`release` checks that), so recycling a foreign object
		// throws "foreign or already-released object". The check is `#if debug`,
		// so a foreign object would pass in release builds and make the whole
		// suite unrunnable in a debug one, which is where a GC investigation
		// most needs it.
		var second:PooledState = pool.acquire();
		var third:PooledState = pool.acquire();
		recycler.recycle(reused);
		recycler.recycle(second);
		recycler.recycle(third);
		Assert.equals(2, recycler.localSize());
		Assert.equals(1, pool.freeCount);

		recycler.drain();
		Assert.equals(0, recycler.localSize());
		Assert.equals(3, pool.freeCount);
	}

	#if cpp
	public function testRandomInstanceHelpersAreDeterministicAndValidateInputs():Void {
		var a = new Random(1234);
		var b = new Random(1234);

		Assert.equals(a.inti(0, 1000), b.inti(0, 1000));
		Assert.equals(a.randomStringi(8), b.randomStringi(8));
		Assert.equals(a.hexi(4), b.hexi(4));
		Assert.equals(a.argbi(), b.argbi());

		var items = ["a", "b", "c"];
		Assert.raises(() -> Random.choose([]));
		Assert.equals("a", a.chooseWeightedi(["a"], [1.0]));
		Assert.raises(() -> a.chooseWeightedi(items, [0.0, 0.0, 0.0]));

		var bytes = Bytes.alloc(6);
		a.fillBytesi(bytes);
		var nonZero = false;
		for (i in 0...bytes.length) {
			if (bytes.get(i) != 0) {
				nonZero = true;
				break;
			}
		}
		Assert.isTrue(nonZero);
	}
	#end

	public function testVersionSupportsComparisonMutationAndValidation():Void {
		var version = new Version(1, 2, 3);
		Assert.equals(1, version.major);
		Assert.equals(2, version.minor);
		Assert.equals(3, version.patch);
		Assert.equals(1002003, version.hash);

		version.minor = 9;
		version.patch = 10;
		Assert.equals("1.9.10", version);

		Assert.isTrue(new Version(1, 9, 10) > new Version(1, 2, 99));
		Assert.isTrue(new Version(1, 9, 10) >= new Version(1, 9, 10));
		Assert.isTrue(new Version(1, 2, 0) < new Version(1, 2, 1));
		Assert.isTrue(new Version(1, 2, 0) <= new Version(1, 2, 0));
		Assert.isTrue(new Version(2, 0, 0) == new Version(2, 0, 0));

		Assert.raises(() -> new Version(1000, 0, 0));
		Assert.raises(() -> new Version(1, 1000, 0));
		Assert.raises(() -> new Version(1, 0, 1000));
	}
}
