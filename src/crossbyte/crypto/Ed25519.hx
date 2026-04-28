package crossbyte.crypto;

import haxe.io.Bytes;
#if cpp
import cpp.ConstPointer;
import cpp.Pointer;
import cpp.RawPointer;
import cpp.UInt8;
import crossbyte.crypto._internal.NativeSodium;
#end

/**
 * Native Ed25519 signing and verification helpers.
 *
 * This API is intentionally small and native-focused. It is suitable for
 * signed control messages, release manifests, trust records, and other
 * application-layer authenticity checks.
 *
 * On supported native `cpp` targets the implementation uses a statically
 * linked libsodium backend, so applications do not need to ship a separate
 * runtime DLL in order to use Ed25519.
 */
class Ed25519 {
	/**
	 * Length in bytes of an Ed25519 public key.
	 */
	public static inline final PUBLIC_KEY_BYTES:Int = 32;

	/**
	 * Length in bytes of an Ed25519 secret key.
	 */
	public static inline final SECRET_KEY_BYTES:Int = 64;

	/**
	 * Length in bytes of an Ed25519 detached signature.
	 */
	public static inline final SIGNATURE_BYTES:Int = 64;

	#if cpp
	@:noCompletion
	private static final __emptyBytes:Bytes = Bytes.alloc(1);
	#end

	/**
	 * Returns `true` when the native Ed25519 backend is available on the current
	 * process and target.
	 *
	 * On unsupported targets this returns `false`.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Returns a short diagnostic string describing whether the native Ed25519
	 * backend is available.
	 */
	public static function availabilityMessage():String {
		#if cpp
		var message = NativeSodium.statusMessage();
		return (message == null || message == "") ? "libsodium status is unavailable." : message;
		#else
		return "Ed25519 is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Generates a fresh Ed25519 keypair.
	 *
	 * @return A signing keypair containing `publicKey` and `secretKey`.
	 */
	public static function keypair():SigningKeyPair {
		#if cpp
		__ensureAvailable();

		var publicKey = Bytes.alloc(PUBLIC_KEY_BYTES);
		var secretKey = Bytes.alloc(SECRET_KEY_BYTES);
		var rc = NativeSodium.ed25519Keypair(__ptr(publicKey), __ptr(secretKey));
		if (rc != 0) {
			throw "libsodium crypto_sign_keypair failed: " + rc;
		}
		return {publicKey: publicKey, secretKey: secretKey};
		#else
		throw "Ed25519 keypair generation is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Produces a detached Ed25519 signature for the provided message bytes.
	 *
	 * @param message The message bytes to sign.
	 * @param secretKey The 64-byte Ed25519 secret key.
	 * @return A 64-byte detached signature.
	 */
	public static function signDetached(message:Bytes, secretKey:Bytes):Bytes {
		if (secretKey == null || secretKey.length != SECRET_KEY_BYTES) {
			throw "secretKey must be " + SECRET_KEY_BYTES + " bytes";
		}

		#if cpp
		__ensureAvailable();

		var signature = Bytes.alloc(SIGNATURE_BYTES);
		var rc = NativeSodium.ed25519SignDetached(__ptr(signature), __cptrOrNull(message), __length(message), __cptr(secretKey));
		if (rc != 0) {
			throw "libsodium crypto_sign_detached failed: " + rc;
		}
		return signature;
		#else
		throw "Ed25519 signing is only available on supported native cpp targets.";
		#end
	}

	/**
	 * Verifies a detached Ed25519 signature.
	 *
	 * @param signature The 64-byte detached signature to verify.
	 * @param message The signed message bytes.
	 * @param publicKey The 32-byte Ed25519 public key.
	 * @return `true` if the signature is valid for the given message and public
	 * key, otherwise `false`.
	 */
	public static function verifyDetached(signature:Bytes, message:Bytes, publicKey:Bytes):Bool {
		if (signature == null || signature.length != SIGNATURE_BYTES) {
			return false;
		}
		if (publicKey == null || publicKey.length != PUBLIC_KEY_BYTES) {
			return false;
		}

		#if cpp
		if (!isAvailable()) {
			return false;
		}
		return NativeSodium.ed25519VerifyDetached(__cptr(signature), __cptrOrNull(message), __length(message), __cptr(publicKey)) == 0;
		#else
		return false;
		#end
	}

	#if cpp
	@:noCompletion
	private static inline function __ptr(bytes:Bytes):RawPointer<UInt8> {
		return cast Pointer.arrayElem(bytes.getData(), 0);
	}

	@:noCompletion
	private static inline function __cptr(bytes:Bytes):ConstPointer<UInt8> {
		return Pointer.arrayElem(bytes.getData(), 0);
	}

	@:noCompletion
	private static inline function __cptrOrNull(bytes:Bytes):ConstPointer<UInt8> {
		return (bytes == null || bytes.length == 0) ? Pointer.arrayElem(__emptyBytes.getData(), 0) : Pointer.arrayElem(bytes.getData(), 0);
	}

	@:noCompletion
	private static inline function __length(bytes:Bytes):Int {
		return bytes == null ? 0 : bytes.length;
	}

	@:noCompletion
	private static inline function __ensureAvailable():Void {
		if (!NativeSodium.isAvailable()) {
			throw availabilityMessage();
		}
	}
	#end
}
