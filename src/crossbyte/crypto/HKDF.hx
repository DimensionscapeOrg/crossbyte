package crossbyte.crypto;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;
#if !cpp
import crossbyte.crypto._internal.NativeOnly;
#end
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
 * libsodium backend. Elsewhere every member but `isSupported` throws an
 * `IllegalOperationError` naming the target.
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
	 * Whether the native HKDF backend is available.
	 */
	public static var isSupported(get, never):Bool;

	@:noCompletion private static function get_isSupported():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Why this class cannot be used here: what its members say when they
	 * refuse, as `isSupported` is false. `null` where `isSupported` is true.
	 */
	public static var unsupportedReason(get, never):Null<String>;

	@:noCompletion private static function get_unsupportedReason():Null<String> {
		#if cpp
		return crossbyte.crypto._internal.NativeSodium.isAvailable() ? null : crossbyte.crypto._internal.SodiumGlue.availabilityMessage();
		#else
		return crossbyte.crypto._internal.NativeOnly.reason("HKDF");
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
			throw new crossbyte.errors.Error("libsodium crypto_kdf_hkdf_sha256_extract failed: " + rc);
		}
		return prk;
		#else
		throw NativeOnly.error("HKDF");
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
		#if cpp
		if (prk == null || prk.length != SHA256_PRK_BYTES) {
			throw new ArgumentError("prk must be " + SHA256_PRK_BYTES + " bytes");
		}
		if (length <= 0 || length > SHA256_EXPAND_MAX_BYTES) {
			throw new ArgumentError("output length must be between 1 and " + SHA256_EXPAND_MAX_BYTES + " bytes");
		}

		SodiumGlue.ensureAvailable();

		var okm = Bytes.alloc(length);
		var rc = NativeSodium.hkdfSha256Expand(SodiumGlue.ptr(okm), length, SodiumGlue.cptrOrEmpty(info), SodiumGlue.len(info), SodiumGlue.cptr(prk));
		if (rc != 0) {
			throw new crossbyte.errors.Error("libsodium crypto_kdf_hkdf_sha256_expand failed: " + rc);
		}
		return okm;
		#else
		throw NativeOnly.error("HKDF");
		#end
	}

	/**
	 * One-shot extract-then-expand.
	 */
	public static function sha256(ikm:Bytes, ?salt:Bytes, ?info:Bytes, length:Int):Bytes {
		return sha256Expand(sha256Extract(salt, ikm), info, length);
	}
}
