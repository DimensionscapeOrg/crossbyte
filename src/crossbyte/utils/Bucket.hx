package crossbyte.utils;

/**
 * Utility methods for working with discrete buckets.
 *
 * This class provides pure, allocation-free helpers for:
 * - Calculating how many buckets fit into a given window or stride.
 * - Mapping hashes and keys into bounded bucket indices.
 * - Computing phase offsets within a window using bucketed hashing.
 *
 * Buckets may represent time slices, hash partitions, shards,
 * or any other discrete grouping.
 */
final class Bucket {
	/**
	 * Calculates the number of buckets that fit within a window.
	 *
	 * Ensures a minimum of 1 bucket is returned.
	 *
	 * @param window The total size of the window or range (e.g., milliseconds, slots, capacity).
	 * @param bucketSize The size of each individual bucket (must be > 0).
	 * @return The number of buckets, at least 1.
	 */
	@:pure public static inline function bucketCount(window:Int, bucketSize:Int):Int {
		var step:Int = (bucketSize <= 0 ? 1 : bucketSize);
		var w:Int = (window <= 0 ? 0 : window);
		var k:Int = Std.int(w / step);
		return (k <= 0 ? 1 : k);
	}

	/**
	 * Maps a hash value to a bucket index within a fixed count.
	 *
	 * Guarantees a uniform distribution across buckets and avoids modulo bias
	 * by using a fallback mixing loop if the count is not a power of two.
	 *
	 * @param hash The input hash value.
	 * @param count The number of buckets to distribute into.
	 * @return A bucket index in the range `[0, count - 1]`.
	 */
	@:pure public static inline function toBucketIndex(hash:Int, count:Int):Int {
		if (count <= 1) {
			return 0;
		}

		var mask:Int = nextPow2Mask(count);

		if ((mask + 1) == count) {
			return hash & mask;
		}

		var x:Int = hash;
		var v:Int = x & mask;

		while (v >= count) {
			x = Hash.fmix32(x + Hash.PHI32);
			v = x & mask;
		}
		return v;
	}

	/**
	 * Computes the bitmask for the next highest power-of-two minus one.
	 *
	 * Useful for fast modulo operations when the bucket count is a power of two.
	 *
	 * @param n The input integer.
	 * @return A bitmask `(2^k - 1)` where `2^k >= n`.
	 */
	@:pure public static inline function nextPow2Mask(n:Int):Int {
		var v:Int = n - 1;
		v |= v >>> 1;
		v |= v >>> 2;
		v |= v >>> 4;
		v |= v >>> 8;
		v |= v >>> 16;
		return v;
	}

	/**
	 * Computes a phase offset from a hash within a windowed range of buckets.
	 *
	 * Typically used to stagger repeated tasks, distribute work across time,
	 * or derive an offset for partitioned scheduling.
	 *
	 * @param hash The hash value to derive the phase from.
	 * @param window The total window or range size.
	 * @param bucket The bucket size or stride.
	 * @return A phase offset in the range `[0, window)`, aligned to bucket size.
	 */
	@:pure public static inline function phaseFromHash(hash:Int, window:Int, bucket:Int):Int {
		var k:Int = bucketCount(window, bucket);
		var i:Int = toBucketIndex(hash, k);
		var step:Int = (bucket <= 0 ? 1 : bucket);
		return i * step;
	}

	/**
	 * Computes a phase offset from a salt/key combination within a window.
	 *
	 * This is a convenience wrapper around `phaseFromHash` that first
	 * hashes a `(salt, key)` pair into a 32-bit hash value.
	 *
	 * @param salt A salt value used to decorrelate key domains.
	 * @param key The input key to bucket (e.g., peer ID, partition ID).
	 * @param window The total window or range size.
	 * @param bucket The bucket size or stride.
	 * @return A phase offset in the range `[0, window)`, aligned to bucket size.
	 */
	@:pure public static inline function phaseFromKey(salt:Int, key:Int, window:Int, bucket:Int):Int {
		return phaseFromHash(Hash.combineHash32(salt, key), window, bucket);
	}
}
