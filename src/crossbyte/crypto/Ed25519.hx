package crossbyte.crypto;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;
#if !(cpp || php)
import crossbyte.crypto._internal.NativeOnly;
#end
#if php
import crossbyte.crypto._internal.PhpSodium;
#end
#if cpp
import cpp.ConstPointer;
import cpp.Pointer;
import cpp.RawPointer;
import cpp.UInt8;
import crossbyte.crypto._internal.NativeSodium;
#end

/**
 * Ed25519 signing and verification (RFC 8032), natively and on PHP.
 *
 * This API is intentionally small. It is suitable for signed control
 * messages, release manifests, trust records, connect tokens
 * (`JWTSigner.EdDSA`), and other application-layer authenticity checks.
 *
 * Natively it uses the statically linked libsodium, so applications do not
 * need to ship a separate runtime DLL. On PHP it uses the sodium extension,
 * which is libsodium too (`extension=sodium` in `php.ini`; it ships with PHP
 * 7.2 and later): keys and signatures are the same bytes on both, so a PHP
 * service can sign what a native server verifies.
 *
 * Every other target has no backend, and there `keypair`, `signDetached` and
 * `verifyDetached` throw an `IllegalOperationError` naming it; check
 * `isSupported` first.
 */
class Ed25519 {
	/**
	 * Length in bytes of an Ed25519 public key.
	 */
	public static inline final PUBLIC_KEY_BYTES:Int = 32;

	/**
	 * Length in bytes of an Ed25519 seed, the private key RFC 8032 and a JWK's
	 * `d` hold.
	 */
	public static inline final SEED_BYTES:Int = 32;

	/**
	 * Length in bytes of an Ed25519 secret key: the seed, then the public key.
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
	 * Whether Ed25519 is available here: natively when libsodium started,
	 * on PHP when the sodium extension is loaded. `false` on every other
	 * target.
	 */
	public static var isSupported(get, never):Bool;

	@:noCompletion private static function get_isSupported():Bool {
		#if cpp
		return NativeSodium.isAvailable();
		#elseif php
		return PhpSodiumStatus.loaded();
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
		#elseif php
		return PhpSodiumStatus.loaded() ? null : PhpSodiumStatus.reason("Ed25519");
		#else
		return crossbyte.crypto._internal.NativeOnly.reason("Ed25519");
		#end
	}

	/**
	 * Generates a fresh Ed25519 keypair.
	 *
	 * @return A signing keypair containing `publicKey` and `secretKey`.
	 * @throws IllegalOperationError Where `isSupported` is false.
	 */
	public static function keypair():SigningKeyPair {
		#if cpp
		__ensureAvailable();

		var publicKey = Bytes.alloc(PUBLIC_KEY_BYTES);
		var secretKey = Bytes.alloc(SECRET_KEY_BYTES);
		var rc = NativeSodium.ed25519Keypair(__ptr(publicKey), __ptr(secretKey));
		if (rc != 0) {
			throw new crossbyte.errors.Error("libsodium crypto_sign_keypair failed: " + rc);
		}
		return {publicKey: publicKey, secretKey: secretKey};
		#elseif php
		__ensureAvailable();
		var pair:String = PhpSodium.sodium_crypto_sign_keypair();
		return {
			publicKey: Bytes.ofData(PhpSodium.sodium_crypto_sign_publickey(pair)),
			secretKey: Bytes.ofData(PhpSodium.sodium_crypto_sign_secretkey(pair))
		};
		#else
		throw NativeOnly.error("Ed25519 keypair generation");
		#end
	}

	/**
	 * The keypair a 32-byte seed makes: the private key as RFC 8032 writes it,
	 * and as a JWK's `d` carries it. The same seed makes the same pair on every
	 * target, so a service can keep only the seed as its secret and derive the
	 * pair as it starts.
	 *
	 * ```haxe
	 * var pair = Ed25519.keypairFromSeed(haxe.io.Bytes.ofHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"));
	 * trace(pair.publicKey.toHex()); // d75a9801..., RFC 8032's first public key
	 * ```
	 *
	 * @param seed The 32-byte seed. Keep it as secret as the secret key, which
	 *        it is the first half of.
	 * @return The pair: `secretKey` is the seed followed by `publicKey`.
	 * @throws ArgumentError For a seed that is not 32 bytes.
	 * @throws IllegalOperationError Where `isSupported` is false.
	 */
	public static function keypairFromSeed(seed:Bytes):SigningKeyPair {
		#if (cpp || php)
		if (seed == null || seed.length != SEED_BYTES) {
			throw new ArgumentError("seed must be " + SEED_BYTES + " bytes");
		}

		__ensureAvailable();

		#if php
		var pair:String = PhpSodium.sodium_crypto_sign_seed_keypair(seed.getData());
		return {
			publicKey: Bytes.ofData(PhpSodium.sodium_crypto_sign_publickey(pair)),
			secretKey: Bytes.ofData(PhpSodium.sodium_crypto_sign_secretkey(pair))
		};
		#else
		var publicKey = Bytes.alloc(PUBLIC_KEY_BYTES);
		var secretKey = Bytes.alloc(SECRET_KEY_BYTES);
		var rc = NativeSodium.ed25519SeedKeypair(__ptr(publicKey), __ptr(secretKey), __cptr(seed));
		if (rc != 0) {
			throw new crossbyte.errors.Error("libsodium crypto_sign_seed_keypair failed: " + rc);
		}
		return {publicKey: publicKey, secretKey: secretKey};
		#end
		#else
		throw NativeOnly.error("Ed25519 keypair generation");
		#end
	}

	/**
	 * Produces a detached Ed25519 signature for the provided message bytes.
	 *
	 * @param message The message bytes to sign.
	 * @param secretKey The 64-byte Ed25519 secret key: the 32-byte seed
	 *        followed by the 32-byte public key, as libsodium has it.
	 * @return A 64-byte detached signature.
	 * @throws ArgumentError For a secret key that is not 64 bytes.
	 * @throws IllegalOperationError Where `isSupported` is false.
	 */
	public static function signDetached(message:Bytes, secretKey:Bytes):Bytes {
		#if (cpp || php)
		if (secretKey == null || secretKey.length != SECRET_KEY_BYTES) {
			throw new ArgumentError("secretKey must be " + SECRET_KEY_BYTES + " bytes");
		}

		__ensureAvailable();

		#if php
		return Bytes.ofData(PhpSodium.sodium_crypto_sign_detached(message == null ? "" : message.getData(), secretKey.getData()));
		#else
		var signature = Bytes.alloc(SIGNATURE_BYTES);
		var rc = NativeSodium.ed25519SignDetached(__ptr(signature), __cptrOrNull(message), __length(message), __cptr(secretKey));
		if (rc != 0) {
			throw new crossbyte.errors.Error("libsodium crypto_sign_detached failed: " + rc);
		}
		return signature;
		#end
		#else
		throw NativeOnly.error("Ed25519 signing");
		#end
	}

	/**
	 * Verifies a detached Ed25519 signature.
	 *
	 * @param signature The 64-byte detached signature to verify.
	 * @param message The signed message bytes.
	 * @param publicKey The 32-byte Ed25519 public key.
	 * @return `true` if the signature is valid for the given message and public
	 * key, otherwise `false`, including for a signature or key of the wrong
	 * length.
	 * @throws IllegalOperationError Where `isSupported` is false, whatever it
	 *         is handed, rather than answering `false`, the answer for a
	 *         forged signature: on a target with no backend, natively when
	 *         libsodium could not be started, and on PHP without the sodium
	 *         extension.
	 */
	public static function verifyDetached(signature:Bytes, message:Bytes, publicKey:Bytes):Bool {
		#if (cpp || php)
		__ensureAvailable();
		if (signature == null || signature.length != SIGNATURE_BYTES) {
			return false;
		}
		if (publicKey == null || publicKey.length != PUBLIC_KEY_BYTES) {
			return false;
		}
		#if php
		return PhpSodium.sodium_crypto_sign_verify_detached(signature.getData(), message == null ? "" : message.getData(), publicKey.getData());
		#else
		return NativeSodium.ed25519VerifyDetached(__cptr(signature), __cptrOrNull(message), __length(message), __cptr(publicKey)) == 0;
		#end
		#else
		throw NativeOnly.error("Ed25519 verification");
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
			throw new crossbyte.errors.IllegalOperationError(unsupportedReason);
		}
	}
	#end

	#if php
	@:noCompletion
	private static inline function __ensureAvailable():Void {
		if (!PhpSodiumStatus.loaded()) {
			throw PhpSodiumStatus.error("Ed25519");
		}
	}
	#end
}
