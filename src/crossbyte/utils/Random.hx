package crossbyte.utils;

#if (cpp || (hl && hl_ver >= version("1.13.0")) || java || cs)
import haxe.atomic.AtomicInt;
#elseif target.threaded
import sys.thread.Mutex;
#end
import crossbyte.utils.Hash;
import haxe.io.Bytes;

/**
 * Provides static and instance-based pseudo-random number generation utilities.
 *
 * Includes methods for generating integers, floats, booleans, bytes, strings, dates, and more.
 * Static methods use a shared `AtomicInt` seed and are thread-safe.
 * Instance methods use internal state and are not thread-safe, but offer reproducible results when seeded.
 *
 * **Security:** this is a fast, non-cryptographic PRNG. Its output is predictable
 * and MUST NOT be used for tokens, session ids, salts, keys, nonces, or any other
 * security-sensitive value. Use `crossbyte.crypto.SecureRandom` for those.
 */
final class Random {

	// The shared seed for the static methods.
	//
	// An AtomicInt where there are threads to race, and a plain Int where
	// there are not -- the same reasoning as NoMutex. That is not a
	// micro-optimisation: Haxe implements AtomicInt on js with a
	// SharedArrayBuffer, which a page is only given when it is cross-origin
	// isolated. This is a static initialiser, so an ordinary page did not get
	// a degraded Random -- it threw "SharedArrayBuffer is not defined" while
	// loading the bundle, before a line of application code ran. The
	// interpreter has no atomics either, which is why the one suite that runs
	// everything could not so much as name this class.
	//
	// Private now. It was public and nothing outside this class ever read it;
	// `reseed` is the supported way to set it, and it does not vary by target.
	//
	// hl has atomics from 1.13 only, and Haxe's AtomicInt refuses to compile
	// for an older one, which is the default -- so naming it for every hl
	// stopped this class compiling there at all. An hl without them, neko and
	// eval have threads and no atomics, and take a lock instead.
	#if (cpp || (hl && hl_ver >= version("1.13.0")) || java || cs)
	@:noCompletion private static var __shared:AtomicInt = new AtomicInt(defaultSeed());
	#else
	@:noCompletion private static var __shared:Int = defaultSeed();
	#end
	#if (!(cpp || (hl && hl_ver >= version("1.13.0")) || java || cs) && target.threaded)
	@:noCompletion private static final __sharedLock:Mutex = new Mutex();
	#end

	@:noCompletion private static inline function __takeSeed():Int {
		#if (cpp || (hl && hl_ver >= version("1.13.0")) || java || cs)
		// Fetch-and-add: the value before the increment.
		return __shared.add(1);
		#else
		#if target.threaded
		__sharedLock.acquire();
		#end
		var current:Int = __shared;
		__shared = (current + 1) | 0;
		#if target.threaded
		__sharedLock.release();
		#end
		return current;
		#end
	}

	/**
	 * Reseeds the shared static PRNG.
	 * 
	 * @param v The new seed value. If `0`, a default seed is used instead.
	 */
	public static inline function reseed(v:Int):Void {
		var value:Int = v != 0 ? v : 0x9E3779B9;

		#if (cpp || (hl && hl_ver >= version("1.13.0")) || java || cs)
		__shared.store(value);
		#else
		#if target.threaded
		__sharedLock.acquire();
		#end
		__shared = value;
		#if target.threaded
		__sharedLock.release();
		#end
		#end
	}

	/**
	 * Returns the next random unsigned 32-bit integer from the shared PRNG.
	 * 
	 * @return A 32-bit pseudo-random integer.
	 */
	public static inline function nextU32():Int {
		return __mix32(__takeSeed());
	}

	/**
	 * Returns a random float in the range [0.0, 1.0).
	 * 
	 * @return A float between 0.0 (inclusive) and 1.0 (exclusive).
	 */
	public static inline function float01():Float {
		return __float01(nextU32);
	}

	/**
	 * Returns a random float within a specified range.
	 * 
	 * @param min The minimum value.
	 * @param max The maximum value.
	 * @return A float between `min` (inclusive) and `max` (exclusive).
	 */
	public static inline function float(min:Float, max:Float):Float {
		return min + float01() * (max - min);
	}

	/**
	 * Returns a random integer within a specified range.
	 * 
	 * @param min The minimum value (inclusive).
	 * @param max The maximum value (inclusive).
	 * @return A random integer in the range [min, max].
	 */
	public static inline function int(min:Int, max:Int):Int {
		return __int(nextU32, min, max);
	}

	/**
	 * Returns a random boolean value.
	 * 
	 * @param p The probability of returning `true` (default is 0.5).
	 * @return `true` with probability `p`, otherwise `false`.
	 */
	public static inline function bool(p:Float = 0.5):Bool {
		return float01() < p;
	}

	/**
	 * Shuffles the elements of the array in-place using the Fisher–Yates algorithm.
	 * 
	 * @param a The array to shuffle.
	 */
	public static function shuffle<T>(a:Array<T>):Void {
		var i:Int = a.length;
		while (i > 1) {
			var j:Int = int(0, --i);
			var t:T = a[i];
			a[i] = a[j];
			a[j] = t;
		}
	}

	/**
	 * Chooses a random element from the array.
	 * 
	 * @param a The array to choose from.
	 * @return A random element from the array.
	 * @throws If the array is `null` or empty.
	 */
	public static inline function choose<T>(a:Array<T>):T {
		if (a == null || a.length == 0) {
			throw "Random.choose: empty array";
		}

		return a[int(0, a.length - 1)];
	}

	/**
	 * Chooses a random element from the array using weighted probabilities.
	 * 
	 * @param items The elements to choose from.
	 * @param w The weights associated with each item.
	 * @return A randomly chosen item, weighted by the associated probabilities.
	 * @throws If inputs are invalid or all weights are <= 0.
	 */
	public static inline function chooseWeighted<T>(items:Array<T>, w:Array<Float>):T {
		return __chooseWeighted(nextU32, items, w);
	}

	/**
	 * Generates a random alphanumeric string.
	 *
	 * **Security:** not cryptographically secure — do not use for tokens, ids, or
	 * secrets. Use `crossbyte.crypto.SecureRandom` for those.
	 *
	 * @param len The desired length of the string.
	 * @param alphabet Optional custom alphabet. Defaults to A-Z, a-z, 0-9.
	 * @return A pseudo-random string of the specified length.
	 */
	public static inline function randomString(len:Int, ?alphabet:String):String {
		var ab:String = (alphabet != null) ? alphabet : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
		return __randomString(nextU32, len, ab);
	}

	/**
	 * Generates a random hexadecimal string.
	 *
	 * **Security:** not cryptographically secure — do not use for tokens, ids, or
	 * secrets. Use `crossbyte.crypto.SecureRandom` for those.
	 *
	 * @param lenBytes The number of random bytes to encode (2 hex digits per byte).
	 * @return A hex string representing `lenBytes` random bytes.
	 */
	public static inline function hex(lenBytes:Int):String {
		return __hex(nextU32, lenBytes);
	}

	/**
	 * Generates a random RGB color as a packed 24-bit integer.
	 * 
	 * @return An `Int` of the form `0xRRGGBB`.
	 */
	public static inline function rgb():Int {
		var x:Int = nextU32();
		return __packRGB((x >>> 16) & 0xFF, (x >>> 8) & 0xFF, x & 0xFF);
	}

	/**
	 * Generates a random ARGB color as a packed 32-bit integer.
	 * 
	 * @param a Optional alpha channel (defaults to 0xFF).
	 * @return An `Int` of the form `0xAARRGGBB`.
	 */
	public static inline function argb(?a:Int = 0xFF):Int {
		var x:Int = nextU32();
		return ((a & 0xFF) << 24) | __packRGB((x >>> 16) & 0xFF, (x >>> 8) & 0xFF, x & 0xFF);
	}

	/**
	 * Returns a random date between two bounds.
	 * 
	 * @param min The lower bound date.
	 * @param max The upper bound date.
	 * @return A `Date` randomly chosen between `min` and `max`.
	 */
	public static inline function dateBetween(min:Date, max:Date):Date {
		var a:Float = min.getTime();
		var b:Float = max.getTime();
		if (b < a) {
			var t:Float = a;
			a = b;
			b = t;
		}
		return Date.fromTime(a + float01() * (b - a));
	}

	/**
	 * Fills a portion of a `Bytes` buffer with random data.
	 *
	 * **Security:** not cryptographically secure — do not use to generate keys,
	 * salts, or nonces. Use `crossbyte.crypto.SecureRandom` for those.
	 *
	 * @param buf The `Bytes` buffer to fill.
	 * @param pos Starting position in the buffer (default is 0).
	 * @param len Number of bytes to write (default fills to end).
	 */
	public static inline function fillBytes(buf:Bytes, pos:Int = 0, len:Int = -1):Void {
		if (len < 0) {
			len = buf.length - pos;
		}

		__nextBytes(nextU32, buf, pos, len);
	}

	/**
	 * Returns a normally distributed random number using Box-Muller transform.
	 * 
	 * @param mean The mean of the distribution (default: 0.0).
	 * @param std The standard deviation (default: 1.0).
	 * @return A normally distributed random float.
	 */
	public static inline function normal(mean:Float = 0.0, std:Float = 1.0):Float {
		return __normal(nextU32, mean, std);
	}

	@:pure
	@:noCompletion private static inline function __mix32(z:Int):Int {
		// Through mul32 rather than `*`, because these two constants are chosen
		// to overflow and the overflow is the mixing. Where an Int is 32 bits
		// that wrap is free; on JavaScript an Int is a double and there is no
		// wrap, so the same seed produced a different sequence -- which is the
		// one promise this class makes, in its own words: "reproducible
		// results when seeded". Measured at seed 12345, cpp and Node agreed on
		// nothing.
		z += 0x9E3779B9;
		z ^= (z >>> 16);
		z = Hash.mul32(z, 0x85EBCA6B);
		z ^= (z >>> 13);
		z = Hash.mul32(z, 0xC2B2AE35);
		z ^= (z >>> 16);
		return z;
	}

	/**
		The shared generator's seed when nobody gives one: the monotonic clock
		in microseconds, and the time of day, each taken modulo 2^32.

		It was `Std.int(stamp * 1e6)`, which past 2^31 microseconds -- 36
		minutes of uptime on the jvm, whose clock counts from boot -- saturated
		at 2147483647 there and came out INT_MIN on hl and neko: every run on
		those targets started from the one seed and drew one sequence.
	**/
	@:noCompletion private static function defaultSeed():Int {
		var micros:Float = haxe.Timer.stamp() * 1e6;
		// time of day: only to tell one run from another, never to time anything.
		var millis:Float = Date.now().getTime();
		return __low32(micros) ^ __low32(millis) ^ 0x9E3779B9;
	}

	// The low 32 bits of a non-negative whole-ish number, as an Int on every
	// target: reduced in Float, so nothing is converted out of Int's range.
	@:noCompletion private static inline function __low32(value:Float):Int {
		var low:Float = value % 4294967296.0;
		if (low < 0) {
			low += 4294967296.0;
		}
		if (low >= 2147483648.0) {
			low -= 4294967296.0;
		}
		return Std.int(low);
	}

	@:pure @:noCompletion private static inline function __u32ToFloat01(u:Int):Float {
		return ((u >>> 8) & 0x00FFFFFF) / 16777216.0;
	}

	@:pure @:noCompletion private static inline function __packRGB(r:Int, g:Int, b:Int):Int {
		return ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
	}

	@:noCompletion private static inline function __float01(next:() -> Int):Float {
		return __u32ToFloat01(next());
	}

	@:pure
	@:noCompletion private static inline function __nextPow2Minus1(n:Int):Int {
		var v = n - 1;
		v |= v >>> 1;
		v |= v >>> 2;
		v |= v >>> 4;
		v |= v >>> 8;
		v |= v >>> 16;
		return v;
	}

	// How many values [min, max] holds is counted in Float. Counted in Int it
	// overflowed from 2^31 values up: Random.int(0, 0x7FFFFFFF) came out 0
	// every time on eval and the jvm, and half of Node's answers fell outside
	// the range. Up to 2^31 - 1 values -- every range that ever worked -- the
	// draw is the one it always was, so a seeded sequence reads the same.
	@:noCompletion private static inline function __int(next:() -> Int, min:Int, max:Int):Int {
		var result:Int = min;
		// `+ 0.0`, not a cast: eval keeps Int arithmetic for an Int typed as Float.
		var span:Float = (max + 0.0) - (min + 0.0) + 1.0;
		if (span <= 0) {
			// An empty range, as it always answered.
		} else if (span <= 2147483647.0) {
			var count:Int = Std.int(span);
			var mask:Int = __nextPow2Minus1(count);
			// Not `mask + 1 == count`, which overflows past 2^30 values.
			if (mask == count - 1) {
				result = min + (next() & mask);
			} else {
				var x:Int = next() & mask;
				while (x >= count) {
					x = next() & mask;
				}
				result = min + x;
			}
		} else {
			// 2^31 to 2^32 values: every bit of a draw, read unsigned, and
			// at least half of the draws land inside.
			var u:Float = __unsigned(next());
			while (u >= span) {
				u = __unsigned(next());
			}
			result = Std.int(min + u);
		}
		return result;
	}

	@:pure @:noCompletion private static inline function __unsigned(u:Int):Float {
		return u < 0 ? u + 4294967296.0 : u + 0.0;
	}

	@:noCompletion private static inline function __randomString(next:() -> Int, len:Int, ab:String):String {
		var out:StringBuf = new StringBuf();
		var l:Int = ab.length;
		for (i in 0...len) {
			out.add(ab.charAt(__int(next, 0, l - 1)));
		}

		return out.toString();
	}

	@:noCompletion private static inline function __hex(next:() -> Int, lenBytes:Int):String {
		var out:StringBuf = new StringBuf();
		var i:Int = 0;
		var x:Int = 0;
		var shift:Int = 0;
		while (i < lenBytes) {
			if (shift == 0) {
				x = next();
				shift = 32;
			}
			var b:Int = (x & 0xFF);
			x >>>= 8;
			shift -= 8;
			out.add(StringTools.hex(b, 2));
			i++;
		}
		return out.toString();
	}

	@:noCompletion private static inline function __chooseWeighted<T>(next:() -> Int, items:Array<T>, weights:Array<Float>):T {
		if (items == null || weights == null || items.length == 0 || items.length != weights.length) {
			throw "Random.chooseWeighted: invalid inputs";
		}

		var sum:Float = 0.0;
		for (w in weights) {
			sum += (w <= 0 ? 0 : w);
		}

		if (sum <= 0) {
			throw "Random.chooseWeighted: all weights <= 0";
		}

		var r:Float = __float01(next) * sum;
		var acc:Float = 0.0;
		var idx:Int = -1;

		for (i in 0...items.length) {
			var wi:Float = (weights[i] <= 0 ? 0 : weights[i]);
			acc += wi;
			if (r < acc) {
				idx = i;
				break;
			}
		}

		if (idx == -1) {
			idx = items.length - 1;
		}

		return items[idx];
	}

	@:noCompletion private static function __nextBytes(next:() -> Int, buf:Bytes, pos:Int, len:Int):Void {
		var i:Int = 0;
		while (i + 4 <= len) {
			var v:Int = next();
			buf.set(pos + i, v & 0xFF);
			buf.set(pos + i + 1, (v >>> 8) & 0xFF);
			buf.set(pos + i + 2, (v >>> 16) & 0xFF);
			buf.set(pos + i + 3, (v >>> 24) & 0xFF);
			i += 4;
		}
		if (i < len) {
			var y:Int = next();
			while (i < len) {
				buf.set(pos + i, y & 0xFF);
				y >>>= 8;
				i++;
			}
		}
	}

	@:noCompletion private static inline function __normal(next:() -> Int, mean:Float, std:Float):Float {
		var u1:Float = 1.0 - __float01(next);
		var u2:Float = 1.0 - __float01(next);
		var r:Float = Math.sqrt(-2.0 * Math.log(u1));
		var z:Float = r * Math.cos(2.0 * Math.PI * u2);
		return mean + std * z;
	}

	@:noCompletion private var __seed:Int;

	/**
	 * Creates a new instance-based random generator.
	 * 
	 * @param seed Optional seed. If `0`, a default constant is used.
	 */
	public inline function new(seed:Int = 0) {
		__seed = ((seed != 0) ? seed : 0x9E3779B9);
	}

	/**
	 * Returns a random float in the range [0.0, 1.0) using the instance PRNG.
	 * 
	 * @return A float between 0.0 and 1.0.
	 */
	public inline function float01i():Float {
		return __float01(__next32);
	}

	/**
	 * Returns a random float between the given bounds using the instance PRNG.
	 * 
	 * @param min The minimum value.
	 * @param max The maximum value.
	 * @return A float in [min, max).
	 */
	public inline function floati(min:Float, max:Float):Float {
		return min + float01i() * (max - min);
	}

	/**
	 * Returns a random integer between the given bounds using the instance PRNG.
	 * 
	 * @param min The minimum value (inclusive).
	 * @param max The maximum value (inclusive).
	 * @return A random integer in the range [min, max].
	 */
	public inline function inti(min:Int, max:Int):Int {
		return __int(__next32, min, max);
	}

	/**
	 * Returns a random boolean with probability `p` using the instance PRNG.
	 * 
	 * @param p The chance of returning `true`. Default is 0.5.
	 * @return `true` with probability `p`, otherwise `false`.
	 */
	public inline function booli(p:Float = 0.5):Bool {
		return float01i() < p;
	}

	/**
	 * Shuffles the elements of the array using the instance PRNG.
	 * 
	 * @param a The array to shuffle.
	 */
	public inline function shufflei<T>(a:Array<T>):Void {
		var i:Int = a.length;
		while (i > 1) {
			var j:Int = inti(0, --i);
			var t:T = a[i];
			a[i] = a[j];
			a[j] = t;
		}
	}

	/**
	 * Reseeds the instance PRNG.
	 * 
	 * @param v The new seed. If `0`, a default constant is used.
	 */
	public inline function reseedi(v:Int):Void {
		__seed = (v == 0 ? 0x9E3779B9 : v);
	}

	/**
	 * Chooses a random element from the array using the instance PRNG.
	 * 
	 * @param a The array to choose from.
	 * @return A random element from the array.
	 * @throws If the array is null or empty.
	 */
	public inline function choosei<T>(a:Array<T>):T {
		if (a == null || a.length == 0) {
			throw "Random.choose: empty array";
		}

		return a[inti(0, a.length - 1)];
	}

	/**
	 * Chooses a weighted random element using the instance PRNG.
	 * 
	 * @param items The items to choose from.
	 * @param w The weights corresponding to each item.
	 * @return A random element based on weights.
	 * @throws If input is invalid or weights are non-positive.
	 */
	public inline function chooseWeightedi<T>(items:Array<T>, w:Array<Float>):T {
		return __chooseWeighted(__next32, items, w);
	}

	/**
	 * Generates a random string using the instance PRNG.
	 * 
	 * @param len Desired string length.
	 * @param alphabet Optional character set to use.
	 * @return A random string.
	 */
	public inline function randomStringi(len:Int, ?alphabet:String):String {
		var ab:String = (alphabet != null) ? alphabet : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
		return __randomString(__next32, len, ab);
	}

	/**
	 * Generates a hexadecimal string of random bytes using the instance PRNG.
	 * 
	 * @param lenBytes Number of random bytes.
	 * @return A hexadecimal string.
	 */
	public inline function hexi(lenBytes:Int):String {
		return __hex(__next32, lenBytes);
	}

	/**
	 * Generates a random RGB value using the instance PRNG.
	 * 
	 * @return A packed 0xRRGGBB color value.
	 */
	public inline function rgbi():Int {
		var x:Int = __next32();
		return __packRGB((x >>> 16) & 0xFF, (x >>> 8) & 0xFF, x & 0xFF);
	}

	/**
	 * Generates a random ARGB value using the instance PRNG.
	 * 
	 * @param a Optional alpha value (default: 0xFF).
	 * @return A packed 0xAARRGGBB color value.
	 */
	public inline function argbi(?a:Int = 0xFF):Int {
		var x:Int = __next32();
		return ((a & 0xFF) << 24) | __packRGB((x >>> 16) & 0xFF, (x >>> 8) & 0xFF, x & 0xFF);

	}

	/**
	 * Returns a random date between `min` and `max` using the instance PRNG.
	 * 
	 * @param min Lower bound.
	 * @param max Upper bound.
	 * @return A random date between `min` and `max`.
	 */
	public inline function dateBetweeni(min:Date, max:Date):Date {
		var a:Float = min.getTime();
		var b:Float = max.getTime();
		if (b < a) {
			var t:Float = a;
			a = b;
			b = t;
		}
		return Date.fromTime(a + float01i() * (b - a));
	}

	/**
	 * Fills a buffer with random bytes using the instance PRNG.
	 * 
	 * @param buf The buffer to fill.
	 * @param pos Start position (default: 0).
	 * @param len Number of bytes (default: remaining).
	 */
	public inline function fillBytesi(buf:Bytes, pos:Int = 0, len:Int = -1):Void {
		if (len < 0) {
			len = buf.length - pos;
		}

		__nextBytes(__next32, buf, pos, len);
	}

	/**
	 * Returns a normally distributed random number using the instance PRNG.
	 * 
	 * @param mean Mean of the distribution.
	 * @param std Standard deviation.
	 * @return A normally distributed float.
	 */
	public inline function normali(mean:Float = 0.0, std:Float = 1.0):Float {
		return __normal(__next32, mean, std);
	}

	@:noCompletion private inline function __step():Int {
		var x = __xorshift32Step(__seed);
		__seed = x;
		return x;
	}

	@:pure
	@:noCompletion private inline function __xorshift32Step(x:Int):Int {
		x ^= (x << 13);
		x ^= (x >>> 17);
		x ^= (x << 5);
		return x;
	}

	@:noCompletion private inline function __next32():Int {
		return __mix32(__step());
	}
}
