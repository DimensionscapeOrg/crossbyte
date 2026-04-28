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

		var second:PooledState = {id: 2, state: "second"};
		var third:PooledState = {id: 3, state: "third"};
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
