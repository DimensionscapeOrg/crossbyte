package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end

/**
 * Best-effort wiping of secret material.
 *
 * `wipe` zeroes a buffer after use so keys and passwords do not linger in
 * process memory longer than needed. On supported native `cpp` targets it
 * uses libsodium's `sodium_memzero`, which resists being optimized away.
 *
 * This is defense in depth, not a guarantee: garbage collectors may have
 * copied the bytes during earlier operations, and swapped memory is outside
 * the process's control.
 */
class SecureMemory {
	/**
	 * Returns `true` when the hardened native wipe backend is in use.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Overwrites every byte of `bytes` with zero. `null` and empty buffers
	 * are ignored.
	 */
	public static function wipe(bytes:Bytes):Void {
		if (bytes == null || bytes.length == 0) {
			return;
		}

		#if cpp
		NativeSodium.memzero(SodiumGlue.ptr(bytes), bytes.length);
		#else
		bytes.fill(0, bytes.length, 0);
		#end
	}
}
