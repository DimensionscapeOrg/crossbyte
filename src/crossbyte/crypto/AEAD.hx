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
 * Authenticated encryption with associated data using
 * XChaCha20-Poly1305-IETF in combined mode: the 16-byte Poly1305 tag is
 * appended to the ciphertext.
 *
 * The 24-byte nonce is large enough to be chosen randomly per message
 * (`generateNonce()`); a (key, nonce) pair must never encrypt two different
 * messages.
 *
 * Available on supported native `cpp` targets via the statically linked
 * libsodium backend. Elsewhere every member but `isSupported` throws an
 * `IllegalOperationError` naming the target.
 */
class AEAD {
	/**
	 * Length in bytes of an encryption key.
	 */
	public static inline final KEY_BYTES:Int = 32;

	/**
	 * Length in bytes of a nonce.
	 */
	public static inline final NONCE_BYTES:Int = 24;

	/**
	 * Length in bytes of the authentication tag appended to ciphertext.
	 */
	public static inline final TAG_BYTES:Int = 16;

	/**
	 * Whether the native AEAD backend is available.
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
	 * Generates a fresh random encryption key from `SecureRandom`.
	 */
	public static function generateKey():Bytes {
		__ensureAvailable();
		return SecureRandom.getSecureRandomBytes(KEY_BYTES);
	}

	/**
	 * Generates a fresh random nonce from `SecureRandom`.
	 */
	public static function generateNonce():Bytes {
		__ensureAvailable();
		return SecureRandom.getSecureRandomBytes(NONCE_BYTES);
	}

	/**
	 * Encrypts and authenticates `plaintext`, additionally authenticating
	 * `associatedData` when provided.
	 *
	 * @return Ciphertext with the tag appended (`plaintext.length + TAG_BYTES`).
	 */
	public static function encrypt(plaintext:Bytes, nonce:Bytes, key:Bytes, ?associatedData:Bytes):Bytes {
		#if cpp
		__validateNonceAndKey(nonce, key);
		SodiumGlue.ensureAvailable();

		var plaintextLength = SodiumGlue.len(plaintext);
		var sealed = Bytes.alloc(plaintextLength + TAG_BYTES);
		var rc = NativeSodium.aeadEncrypt(SodiumGlue.ptr(sealed), SodiumGlue.cptrOrEmpty(plaintext), plaintextLength,
			SodiumGlue.cptrOrEmpty(associatedData), SodiumGlue.len(associatedData), SodiumGlue.cptr(nonce), SodiumGlue.cptr(key));
		if (rc != 0) {
			throw new crossbyte.errors.Error("libsodium crypto_aead_xchacha20poly1305_ietf_encrypt failed: " + rc);
		}
		return sealed;
		#else
		throw NativeOnly.error("AEAD encryption");
		#end
	}

	/**
	 * Verifies and decrypts combined-mode ciphertext produced by `encrypt`.
	 *
	 * @return The plaintext, or `null` when authentication fails. Malformed
	 * nonce/key lengths throw.
	 * @throws IllegalOperationError On a target other than native cpp, rather
	 *         than answering `null`, the answer for a forged message.
	 */
	public static function decrypt(ciphertext:Bytes, nonce:Bytes, key:Bytes, ?associatedData:Bytes):Null<Bytes> {
		#if cpp
		__validateNonceAndKey(nonce, key);
		SodiumGlue.ensureAvailable();

		if (ciphertext == null || ciphertext.length < TAG_BYTES) {
			return null;
		}

		var plaintextLength = ciphertext.length - TAG_BYTES;
		// The native call needs a non-empty output buffer even for tag-only input.
		var opened = Bytes.alloc(plaintextLength > 0 ? plaintextLength : 1);
		var rc = NativeSodium.aeadDecrypt(SodiumGlue.ptr(opened), SodiumGlue.cptr(ciphertext), ciphertext.length,
			SodiumGlue.cptrOrEmpty(associatedData), SodiumGlue.len(associatedData), SodiumGlue.cptr(nonce), SodiumGlue.cptr(key));
		if (rc != 0) {
			return null;
		}
		return (plaintextLength > 0) ? opened : Bytes.alloc(0);
		#else
		throw NativeOnly.error("AEAD decryption");
		#end
	}

	@:noCompletion
	private static function __validateNonceAndKey(nonce:Bytes, key:Bytes):Void {
		if (nonce == null || nonce.length != NONCE_BYTES) {
			throw new ArgumentError("nonce must be " + NONCE_BYTES + " bytes");
		}
		if (key == null || key.length != KEY_BYTES) {
			throw new ArgumentError("key must be " + KEY_BYTES + " bytes");
		}
	}

	@:noCompletion
	private static function __ensureAvailable():Void {
		#if cpp
		SodiumGlue.ensureAvailable();
		#else
		throw NativeOnly.error("AEAD");
		#end
	}
}
