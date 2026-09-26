package crossbyte.crypto;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;
#if cpp
import crossbyte.crypto._internal.NativePk;
#end

/**
 * Key kinds understood by `PublicKeySignature`.
 */
enum abstract PublicKeyType(Int) from Int to Int {
	/** The key could not be parsed, or is a kind not handled here. */
	var UNKNOWN:Int = 0;

	/** RSA, as used by `RS256`. */
	var RSA:Int = 1;

	/** Elliptic curve, as used by `ES256`. */
	var EC:Int = 2;
}

/**
 * Signature encodings.
 */
enum abstract SignatureFormat(Int) from Int to Int {
	/**
	 * The algorithm's own encoding: PKCS#1 v1.5 for RSA, ASN.1 DER for
	 * ECDSA. What X.509 and most protocols use.
	 */
	var NATIVE:Int = 0;

	/**
	 * Fixed-width `r || s` with no ASN.1 wrapper, which is what JWS
	 * carries for `ES256`. Meaningful only for EC keys.
	 */
	var JOSE:Int = 1;
}

/**
 * RSA and ECDSA signatures over SHA-256, backed by mbedTLS.
 *
 * This is what lets a CrossByte service verify `RS256` tokens from an
 * OpenID Connect provider, and `ES256` tokens from providers and
 * WebAuthn authenticators.
 *
 * Keys are PEM text, the form providers publish and tools emit. These
 * functions parse the key, use it once and wipe it again, which suits a key
 * used once. For a key used repeatedly, parse it once into a `SignatureKey`:
 * that is faster, and leaves no copy of a private key behind per call.
 *
 * Available on native `cpp` targets. mbedTLS ships with hxcpp and is
 * already linked for TLS, so no extra dependency is introduced.
 */
class PublicKeySignature {
	@:noCompletion @:allow(crossbyte.crypto.SignatureKey)
	private static inline final UNAVAILABLE:String = "Public-key signing is only available on supported native cpp targets.";

	/**
	 * Returns `true` when the native backend is available.
	 */
	public static function isAvailable():Bool {
		#if cpp
		return NativePk.isAvailable();
		#else
		return false;
		#end
	}

	/**
	 * Reports the kind of key a PEM document contains.
	 *
	 * @param keyPem PEM text.
	 * @param isPrivate Whether `keyPem` is a private key.
	 */
	public static function keyType(keyPem:String, isPrivate:Bool = false):PublicKeyType {
		var key:Null<SignatureKey> = @:privateAccess SignatureKey.__load(keyPem, isPrivate, false);
		if (key == null) {
			return UNKNOWN;
		}

		var type:PublicKeyType = key.type;
		key.dispose();
		return type;
	}

	/**
	 * Length in bytes of a JOSE-format ECDSA signature for this key,
	 * twice the curve's coordinate size, so 64 for P-256.
	 *
	 * @return The length, or `-1` when the key is not an EC key.
	 */
	public static function joseSignatureLength(keyPem:String, isPrivate:Bool = false):Int {
		var key:Null<SignatureKey> = @:privateAccess SignatureKey.__load(keyPem, isPrivate, false);
		if (key == null) {
			return -1;
		}

		var length:Int = key.joseSignatureLength();
		key.dispose();
		return length;
	}

	/**
	 * Verifies a signature over `message`.
	 *
	 * @param publicKeyPem PEM public key (RSA or EC).
	 * @param message The signed message bytes.
	 * @param signature The signature to check.
	 * @param format Encoding of `signature`. Use `JOSE` for `ES256` JWTs.
	 * @return `true` only when the signature is valid. Malformed keys,
	 *         wrong-length signatures, and unavailable backends return
	 *         `false` rather than throwing, so a hostile token cannot
	 *         raise out of a verification path.
	 */
	public static function verify(publicKeyPem:String, message:Bytes, signature:Bytes, format:SignatureFormat = NATIVE):Bool {
		if (message == null || signature == null || signature.length == 0) {
			return false;
		}

		var key:Null<SignatureKey> = @:privateAccess SignatureKey.__load(publicKeyPem, false, false);
		if (key == null) {
			return false;
		}

		var valid:Bool = key.verify(message, signature, format);
		key.dispose();
		return valid;
	}

	/**
	 * Signs `message`.
	 *
	 * @param privateKeyPem PEM private key, unencrypted.
	 * @param message The message bytes to sign.
	 * @param format Encoding to produce. Use `JOSE` for `ES256` JWTs.
	 * @return The signature.
	 * @throws ArgumentError When arguments are missing.
	 */
	public static function sign(privateKeyPem:String, message:Bytes, format:SignatureFormat = NATIVE):Bytes {
		if (privateKeyPem == null || privateKeyPem == "") {
			throw new ArgumentError("A PEM private key is required to sign.");
		}
		if (message == null) {
			throw new ArgumentError("A message is required to sign.");
		}

		var key:SignatureKey = SignatureKey.fromPrivatePem(privateKeyPem);
		var signature:Bytes;
		try {
			signature = key.sign(message, format);
		} catch (error:Dynamic) {
			key.dispose();
			throw error;
		}
		// Wiped now rather than whenever the collector gets to it.
		key.dispose();
		return signature;
	}
}
