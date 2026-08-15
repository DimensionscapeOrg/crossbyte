package crossbyte.crypto.password;

import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativeSodium;
import crossbyte.crypto._internal.SodiumGlue;
#end

/**
 * Argon2id password hashing and password-based key derivation (libsodium
 * `crypto_pwhash`, algorithm fixed to Argon2id v1.3).
 *
 * `hash`/`verify` operate on the self-describing PHC string format
 * (`$argon2id$...`), which embeds the salt and cost parameters. `derive`
 * produces raw key material for a caller-managed salt.
 *
 * Prefer this over `BCrypt` for new designs. Available on supported native
 * `cpp` targets via the statically linked libsodium backend.
 */
class Argon2id {
	/**
	 * Length in bytes of a `derive` salt.
	 */
	public static inline final SALT_BYTES:Int = 16;

	/**
	 * Minimum length in bytes of raw derived output.
	 */
	public static inline final BYTES_MIN:Int = 16;

	/**
	 * Maximum length in bytes of a PHC hash string, including terminator.
	 */
	public static inline final STR_BYTES:Int = 128;

	/**
	 * Minimum operations limit.
	 */
	public static inline final OPSLIMIT_MIN:Int = 1;

	/**
	 * Operations limit for interactive logins.
	 */
	public static inline final OPSLIMIT_INTERACTIVE:Int = 2;

	/**
	 * Operations limit for moderate offline resistance.
	 */
	public static inline final OPSLIMIT_MODERATE:Int = 3;

	/**
	 * Operations limit for highly sensitive material.
	 */
	public static inline final OPSLIMIT_SENSITIVE:Int = 4;

	/**
	 * Minimum memory limit in bytes (8 KiB).
	 */
	public static inline final MEMLIMIT_MIN:Int = 8192;

	/**
	 * Memory limit for interactive logins (64 MiB).
	 */
	public static inline final MEMLIMIT_INTERACTIVE:Int = 67108864;

	/**
	 * Memory limit for moderate offline resistance (256 MiB).
	 */
	public static inline final MEMLIMIT_MODERATE:Int = 268435456;

	/**
	 * Memory limit for highly sensitive material (1 GiB).
	 */
	public static inline final MEMLIMIT_SENSITIVE:Int = 1073741824;

	/**
	 * Returns `true` when the native Argon2id backend is available.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Hashes `password` into a self-describing PHC string.
	 */
	public static function hash(password:String, opslimit:Int = OPSLIMIT_INTERACTIVE, memlimit:Int = MEMLIMIT_INTERACTIVE):String {
		if (password == null) {
			throw "password must not be null";
		}
		__validateLimits(opslimit, memlimit);

		#if cpp
		SodiumGlue.ensureAvailable();

		var passwordBytes = Bytes.ofString(password);
		var out = Bytes.alloc(STR_BYTES);
		var rc = NativeSodium.pwhashStr(SodiumGlue.ptr(out), SodiumGlue.cptrOrEmpty(passwordBytes), passwordBytes.length, opslimit, memlimit);
		if (rc != 0) {
			throw "libsodium crypto_pwhash_str failed (out of memory?): " + rc;
		}

		var terminator = 0;
		while (terminator < STR_BYTES && out.get(terminator) != 0) {
			terminator++;
		}
		return out.getString(0, terminator);
		#else
		throw "Argon2id is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Verifies `password` against a PHC hash string.
	 *
	 * @return `true` only when the string parses and the password matches.
	 * Returns `false` (never throws) for malformed strings, mismatches, and
	 * unavailable targets.
	 */
	public static function verify(hashStr:String, password:String):Bool {
		if (hashStr == null || password == null || hashStr.length >= STR_BYTES) {
			return false;
		}

		#if cpp
		if (!NativeSodium.isAvailable()) {
			return false;
		}

		var passwordBytes = Bytes.ofString(password);
		return NativeSodium.pwhashStrVerify(SodiumGlue.cptr(__nulTerminated(hashStr)), SodiumGlue.cptrOrEmpty(passwordBytes), passwordBytes.length) == 0;
		#else
		return false;
		#end
	}

	/**
	 * Returns `true` when `hashStr` should be recomputed because it does not
	 * match the supplied cost parameters (or cannot be parsed).
	 */
	public static function needsRehash(hashStr:String, opslimit:Int, memlimit:Int):Bool {
		__validateLimits(opslimit, memlimit);
		if (hashStr == null || hashStr.length >= STR_BYTES) {
			return true;
		}

		#if cpp
		SodiumGlue.ensureAvailable();

		return NativeSodium.pwhashStrNeedsRehash(SodiumGlue.cptr(__nulTerminated(hashStr)), opslimit, memlimit) != 0;
		#else
		throw "Argon2id is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Derives `length` bytes of raw key material from a password and a
	 * caller-managed `SALT_BYTES` salt. Deterministic for identical inputs.
	 */
	public static function derive(password:String, salt:Bytes, length:Int, opslimit:Int, memlimit:Int):Bytes {
		if (password == null) {
			throw "password must not be null";
		}
		if (salt == null || salt.length != SALT_BYTES) {
			throw "salt must be " + SALT_BYTES + " bytes";
		}
		if (length < BYTES_MIN) {
			throw "derived length must be at least " + BYTES_MIN + " bytes";
		}
		__validateLimits(opslimit, memlimit);

		#if cpp
		SodiumGlue.ensureAvailable();

		var passwordBytes = Bytes.ofString(password);
		var out = Bytes.alloc(length);
		var rc = NativeSodium.pwhashDerive(SodiumGlue.ptr(out), length, SodiumGlue.cptrOrEmpty(passwordBytes), passwordBytes.length,
			SodiumGlue.cptr(salt), opslimit, memlimit);
		if (rc != 0) {
			throw "libsodium crypto_pwhash failed (out of memory?): " + rc;
		}
		return out;
		#else
		throw "Argon2id is only available on supported native cpp targets.";
		#end
	}

	@:noCompletion
	private static function __validateLimits(opslimit:Int, memlimit:Int):Void {
		if (opslimit < OPSLIMIT_MIN) {
			throw "opslimit must be at least " + OPSLIMIT_MIN;
		}
		if (memlimit < MEMLIMIT_MIN) {
			throw "memlimit must be at least " + MEMLIMIT_MIN + " bytes";
		}
	}

	#if cpp
	@:noCompletion
	private static function __nulTerminated(value:String):Bytes {
		var raw = Bytes.ofString(value);
		var terminated = Bytes.alloc(raw.length + 1);
		terminated.blit(0, raw, 0, raw.length);
		terminated.set(raw.length, 0);
		return terminated;
	}
	#end
}
