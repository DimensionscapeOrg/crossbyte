package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end

/**
 * BLAKE2b hashing (libsodium `crypto_generichash`), optionally keyed.
 *
 * Complements `Blake3`: use this when interoperating with systems that speak
 * BLAKE2b, when a keyed MAC-style digest is needed, or when output sizes
 * between 16 and 64 bytes must match libsodium peers.
 *
 * Available on supported native `cpp` targets via the statically linked
 * libsodium backend.
 */
class GenericHash {
	/**
	 * Minimum digest length in bytes.
	 */
	public static inline final BYTES_MIN:Int = 16;

	/**
	 * Default digest length in bytes.
	 */
	public static inline final BYTES_DEFAULT:Int = 32;

	/**
	 * Maximum digest length in bytes.
	 */
	public static inline final BYTES_MAX:Int = 64;

	/**
	 * Minimum key length in bytes when a key is supplied.
	 */
	public static inline final KEY_BYTES_MIN:Int = 16;

	/**
	 * Maximum key length in bytes.
	 */
	public static inline final KEY_BYTES_MAX:Int = 64;

	/**
	 * Returns `true` when the native BLAKE2b backend is available.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Hashes `data`, optionally keyed, producing a `length`-byte digest.
	 *
	 * @param data The input bytes; `null` hashes the empty message.
	 * @param key Optional key of `KEY_BYTES_MIN`–`KEY_BYTES_MAX` bytes.
	 * @param length Digest length, `BYTES_MIN`–`BYTES_MAX`.
	 */
	public static function hash(data:Bytes, ?key:Bytes, length:Int = BYTES_DEFAULT):Bytes {
		if (length < BYTES_MIN || length > BYTES_MAX) {
			throw "digest length must be between " + BYTES_MIN + " and " + BYTES_MAX + " bytes";
		}
		if (key != null && (key.length < KEY_BYTES_MIN || key.length > KEY_BYTES_MAX)) {
			throw "key length must be between " + KEY_BYTES_MIN + " and " + KEY_BYTES_MAX + " bytes";
		}

		#if cpp
		SodiumGlue.ensureAvailable();

		var digest = Bytes.alloc(length);
		var rc = NativeSodium.genericHash(SodiumGlue.ptr(digest), length, SodiumGlue.cptrOrEmpty(data), SodiumGlue.len(data),
			SodiumGlue.cptrOrEmpty(key), SodiumGlue.len(key));
		if (rc != 0) {
			throw "libsodium crypto_generichash failed: " + rc;
		}
		return digest;
		#else
		throw "GenericHash is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Convenience wrapper returning the digest as lowercase hex.
	 */
	public static function hashHex(data:Bytes, ?key:Bytes, length:Int = BYTES_DEFAULT):String {
		return hash(data, key, length).toHex();
	}
}
