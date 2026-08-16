package crossbyte.crypto;

import crossbyte.errors.ArgumentError;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
#if cpp
import cpp.Pointer;
import crossbyte.crypto._internal.NativePk;
import crossbyte.crypto._internal.SodiumGlue;
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
 * Keys are PEM text — the form providers publish and tools emit. They are
 * parsed on every call rather than held as handles, so there is no
 * lifetime to manage; a service verifying at high rates should cache
 * results at a higher level, such as by token or key id.
 *
 * Available on native `cpp` targets. mbedTLS ships with hxcpp and is
 * already linked for TLS, so no extra dependency is introduced.
 */
class PublicKeySignature {
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
		#if cpp
		if (keyPem == null || keyPem == "" || !NativePk.isAvailable()) {
			return UNKNOWN;
		}

		var pem:Bytes = Bytes.ofString(keyPem);
		return NativePk.keyType(SodiumGlue.cptr(pem), pem.length, isPrivate);
		#else
		return UNKNOWN;
		#end
	}

	/**
	 * Length in bytes of a JOSE-format ECDSA signature for this key —
	 * twice the curve's coordinate size, so 64 for P-256.
	 *
	 * @return The length, or `-1` when the key is not an EC key.
	 */
	public static function joseSignatureLength(keyPem:String, isPrivate:Bool = false):Int {
		#if cpp
		if (keyPem == null || keyPem == "" || !NativePk.isAvailable()) {
			return -1;
		}

		var pem:Bytes = Bytes.ofString(keyPem);
		var coordinate:Int = NativePk.ecCoordinateSize(SodiumGlue.cptr(pem), pem.length, isPrivate);
		return coordinate < 0 ? -1 : coordinate * 2;
		#else
		return -1;
		#end
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
		if (publicKeyPem == null || publicKeyPem == "" || message == null || signature == null || signature.length == 0) {
			return false;
		}

		#if cpp
		if (!NativePk.isAvailable()) {
			return false;
		}

		var pem:Bytes = Bytes.ofString(publicKeyPem);
		var hash:Bytes = Sha256.make(message);

		return NativePk.verifySha256(SodiumGlue.cptr(pem), pem.length, SodiumGlue.cptr(hash), SodiumGlue.cptr(signature), signature.length,
			format) == 0;
		#else
		return false;
		#end
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

		#if cpp
		if (!NativePk.isAvailable()) {
			throw "Public-key signing is only available on supported native cpp targets.";
		}

		var pem:Bytes = Bytes.ofString(privateKeyPem);
		var hash:Bytes = Sha256.make(message);
		// Comfortably above the largest signature mbedTLS will emit for
		// the key sizes this API handles.
		var scratch:Bytes = Bytes.alloc(1024);
		var producedLength:Array<Int> = [0];

		var rc:Int = NativePk.signSha256(SodiumGlue.cptr(pem), pem.length, SodiumGlue.cptr(hash), SodiumGlue.ptr(scratch), scratch.length,
			Pointer.arrayElem(producedLength, 0).raw, format);

		if (rc != 0) {
			throw 'Signing failed: ' + NativePk.errorMessage(rc) + ' (code $rc)';
		}

		var produced:Int = producedLength[0];
		if (produced <= 0) {
			throw "mbedTLS signing produced an empty signature.";
		}

		return scratch.sub(0, produced);
		#else
		throw "Public-key signing is only available on supported native cpp targets.";
		#end
	}
}
