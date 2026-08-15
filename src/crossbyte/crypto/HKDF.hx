package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end

/**
 * HKDF-SHA-256 key derivation (RFC 5869) via libsodium's
 * `crypto_kdf_hkdf_sha256` API.
 *
 * Use `sha256Extract` to condense input keying material into a PRK,
 * `sha256Expand` to derive labeled output keys from it, or the one-shot
 * `sha256` for the full extract-then-expand flow.
 *
 * Available on supported native `cpp` targets via the statically linked
 * libsodium backend.
 */
class HKDF {
	/**
	 * Length in bytes of an extracted pseudorandom key (PRK).
	 */
	public static inline final SHA256_PRK_BYTES:Int = 32;

	/**
	 * Maximum output length of a single expand call (255 * 32).
	 */
	public static inline final SHA256_EXPAND_MAX_BYTES:Int = 8160;

	/**
	 * Returns `true` when the native HKDF backend is available.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Extracts a 32-byte PRK from input keying material.
	 *
	 * @param salt Optional salt; `null` uses the RFC 5869 zero salt.
	 * @param ikm Input keying material.
	 */
	public static function sha256Extract(?salt:Bytes, ikm:Bytes):Bytes {
		#if cpp
		SodiumGlue.ensureAvailable();

		var prk = Bytes.alloc(SHA256_PRK_BYTES);
		var rc = NativeSodium.hkdfSha256Extract(SodiumGlue.ptr(prk), SodiumGlue.cptrOrEmpty(salt), SodiumGlue.len(salt),
			SodiumGlue.cptrOrEmpty(ikm), SodiumGlue.len(ikm));
		if (rc != 0) {
			throw "libsodium crypto_kdf_hkdf_sha256_extract failed: " + rc;
		}
		return prk;
		#else
		throw "HKDF is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Expands a PRK into `length` bytes of output keying material.
	 *
	 * @param prk A 32-byte PRK from `sha256Extract`.
	 * @param info Optional context/label bytes.
	 * @param length Output length, 1–`SHA256_EXPAND_MAX_BYTES`.
	 */
	public static function sha256Expand(prk:Bytes, ?info:Bytes, length:Int):Bytes {
		if (prk == null || prk.length != SHA256_PRK_BYTES) {
			throw "prk must be " + SHA256_PRK_BYTES + " bytes";
		}
		if (length <= 0 || length > SHA256_EXPAND_MAX_BYTES) {
			throw "output length must be between 1 and " + SHA256_EXPAND_MAX_BYTES + " bytes";
		}

		#if cpp
		SodiumGlue.ensureAvailable();

		var okm = Bytes.alloc(length);
		var rc = NativeSodium.hkdfSha256Expand(SodiumGlue.ptr(okm), length, SodiumGlue.cptrOrEmpty(info), SodiumGlue.len(info), SodiumGlue.cptr(prk));
		if (rc != 0) {
			throw "libsodium crypto_kdf_hkdf_sha256_expand failed: " + rc;
		}
		return okm;
		#else
		throw "HKDF is only available on supported native cpp targets.";
		#end
	}

	/**
	 * One-shot extract-then-expand.
	 */
	public static function sha256(ikm:Bytes, ?salt:Bytes, ?info:Bytes, length:Int):Bytes {
		return sha256Expand(sha256Extract(salt, ikm), info, length);
	}
}
