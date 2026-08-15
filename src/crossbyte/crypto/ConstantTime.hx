package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end

/**
 * Timing-safe byte comparison.
 *
 * Use this instead of `Bytes` equality whenever comparing secrets: MAC tags,
 * API tokens, session identifiers, derived keys. Ordinary comparisons return
 * early on the first mismatching byte, which leaks position information to an
 * attacker who can measure latency.
 *
 * On supported native `cpp` targets this delegates to libsodium's
 * `sodium_memcmp`; elsewhere a best-effort constant-time accumulation loop is
 * used. Length mismatch returns `false` immediately — hiding length is the
 * caller's concern (compare digests of the values when lengths are secret).
 */
class ConstantTime {
	/**
	 * Returns `true` when the hardened native comparison backend is in use.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Compares two byte sequences without early exit on mismatch.
	 *
	 * @return `true` only when both are non-null, equal length, and equal
	 * content.
	 */
	public static function equals(a:Bytes, b:Bytes):Bool {
		if (a == null || b == null || a.length != b.length) {
			return false;
		}
		if (a.length == 0) {
			return true;
		}

		#if cpp
		if (NativeSodium.isAvailable()) {
			return NativeSodium.memcmp(SodiumGlue.cptr(a), SodiumGlue.cptr(b), a.length) == 0;
		}
		#end

		var difference = 0;
		for (i in 0...a.length) {
			difference |= a.get(i) ^ b.get(i);
		}
		return difference == 0;
	}
}
