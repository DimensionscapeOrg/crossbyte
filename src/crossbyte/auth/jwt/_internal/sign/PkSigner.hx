package crossbyte.auth.jwt._internal.sign;

import crossbyte.auth.jwt.JWTAlgorithm;
import crossbyte.auth.jwt._internal.Base64Url;
import crossbyte.crypto.PublicKeySignature;
import crossbyte.crypto.PublicKeySignature.PublicKeyType;
import crossbyte.crypto.PublicKeySignature.SignatureFormat;
import crossbyte.crypto.SignatureKey;
import haxe.ds.StringMap;
import haxe.io.Bytes;
#if !cpp
import crossbyte.crypto._internal.NativeOnly;
#end

/**
 * JWT signer for the asymmetric SHA-256 algorithms backed by mbedTLS:
 * `RS256` (RSA PKCS#1 v1.5) and `ES256` (ECDSA P-256).
 *
 * Verification keys are PEM public keys held by `kid`, which is the shape
 * an OpenID Connect provider's JWKS converts into. Supplying a private key
 * is optional; without one the signer verifies only, which is the usual
 * arrangement for a service consuming someone else's tokens.
 *
 * `ES256` signatures are carried by JWS as fixed-width `r || s`, not the
 * ASN.1 DER that ECDSA implementations normally emit; that conversion
 * happens in the native layer.
 *
 * Every key is parsed once, here, into a `SignatureKey`, so no copy of the
 * private key is left in freed memory for each token signed, and an EC
 * key's tables are not rebuilt for each one checked.
 */
class PkSigner implements IJWTSigner {
	public var algorithm(get, never):JWTAlgorithm;
	public var signKeyId(get, never):String;

	private var __algorithm:JWTAlgorithm;
	private var __format:SignatureFormat;
	private var __publicKeys:StringMap<SignatureKey>;
	private var __privateKey:SignatureKey;
	private var __signKeyId:String;

	private inline function get_algorithm():JWTAlgorithm {
		return __algorithm;
	}

	private inline function get_signKeyId():String {
		return __signKeyId;
	}

	/**
	 * @param algorithm Either `RS256` or `ES256`.
	 * @param publicKeys PEM public keys by key id.
	 * @param privateKey Optional PEM private key used for signing.
	 * @param signKeyId Key id to sign under; required when several keys
	 *        are present and a private key is supplied.
	 */
	public function new(algorithm:JWTAlgorithm, publicKeys:StringMap<String>, ?privateKey:String, ?signKeyId:String) {
		if (algorithm != JWTAlgorithm.RS256 && algorithm != JWTAlgorithm.ES256) {
			throw 'PkSigner supports RS256 and ES256, not "$algorithm"';
		}
		if (!PublicKeySignature.isAvailable()) {
			#if cpp
			throw "PkSigner requires the native mbedTLS backend, which this hxcpp does not expose.";
			#else
			throw NativeOnly.error(algorithm + " JWT signing and verification");
			#end
		}
		if (publicKeys == null) {
			throw "PkSigner: publicKeys must not be null";
		}

		__algorithm = algorithm;
		// ES256 carries r||s; RS256 uses PKCS#1 v1.5 as-is.
		__format = (algorithm == JWTAlgorithm.ES256) ? SignatureFormat.JOSE : SignatureFormat.NATIVE;
		__publicKeys = new StringMap();

		var expectedType:PublicKeyType = (algorithm == JWTAlgorithm.ES256) ? PublicKeyType.EC : PublicKeyType.RSA;
		var keyCount:Int = 0;
		var soleKeyId:String = null;

		for (keyId in publicKeys.keys()) {
			if (keyId == null || keyId == "") {
				throw "PkSigner: empty key id";
			}

			var pem:String = publicKeys.get(keyId);
			if (pem == null || pem == "") {
				throw 'PkSigner: empty public key for "$keyId"';
			}
			// A key of the wrong kind would fail every verification at
			// runtime with no indication why; reject it at construction.
			var key:Null<SignatureKey> = @:privateAccess SignatureKey.__load(pem, false, false);
			if (key == null || key.type != expectedType) {
				throw 'PkSigner: public key "$keyId" is not a valid $algorithm key';
			}

			__publicKeys.set(keyId, key);
			soleKeyId = keyId;
			keyCount++;
		}

		if (keyCount == 0) {
			throw "PkSigner: at least one public key is required";
		}

		if (privateKey != null && privateKey != "") {
			var key:Null<SignatureKey> = @:privateAccess SignatureKey.__load(privateKey, true, false);
			if (key == null || key.type != expectedType) {
				if (key != null) {
					key.dispose();
				}
				throw 'PkSigner: private key is not a valid $algorithm key';
			}
			__privateKey = key;
		}

		if (signKeyId != null) {
			if (!__publicKeys.exists(signKeyId)) {
				throw 'PkSigner: unknown signKeyId "$signKeyId"';
			}
			__signKeyId = signKeyId;
		} else if (keyCount == 1) {
			__signKeyId = soleKeyId;
		} else if (__privateKey != null) {
			throw "PkSigner: multiple public keys provided; signKeyId is required to sign";
		}
	}

	public function sign(input:String, ?keyId:String):String {
		if (__privateKey == null) {
			throw "PkSigner.sign: no private key configured (verify-only signer)";
		}
		if (keyId != null && keyId != __signKeyId) {
			throw 'PkSigner.sign: unknown signing key id "$keyId"';
		}
		if (input == null) {
			throw "PkSigner.sign: input must not be null";
		}

		return Base64Url.encode(__privateKey.sign(Bytes.ofString(input), __format));
	}

	public function hasKey(keyId:Null<String>):Bool {
		return keyId != null ? __publicKeys.exists(keyId) : __signKeyId != null;
	}

	public function verify(input:String, signature:String, ?keyId:String):Bool {
		if (input == null || signature == null) {
			return false;
		}
		return __verify(input, signature, 0, keyId);
	}

	public function verifyToken(token:String, inputEnd:Int, keyId:Null<String>):Bool {
		return __verify(token.substring(0, inputEnd), token, inputEnd + 1, keyId);
	}

	/** The signature is `text` from `signatureStart` to its end. **/
	private function __verify(input:String, text:String, signatureStart:Int, keyId:Null<String>):Bool {
		var key:Null<SignatureKey> = (keyId != null) ? __publicKeys.get(keyId) : (__signKeyId != null ? __publicKeys.get(__signKeyId) : null);
		if (key == null) {
			return false;
		}

		var raw:Null<Bytes> = Base64Url.decode(text, signatureStart, text.length);
		if (raw == null) {
			return false;
		}

		return key.verify(Bytes.ofString(input), raw, __format);
	}
}
