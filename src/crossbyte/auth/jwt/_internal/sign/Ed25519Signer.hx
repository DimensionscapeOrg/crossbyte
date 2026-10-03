package crossbyte.auth.jwt._internal.sign;

import crossbyte.auth.jwt.JWTAlgorithm;
import crossbyte.auth.jwt._internal.Base64Url;
import crossbyte.crypto.ConstantTime;
import crossbyte.crypto.Ed25519;
import haxe.ds.StringMap;
import haxe.io.Bytes;
#if !cpp
import crossbyte.crypto._internal.NativeOnly;
#end

/**
 * EdDSA (Ed25519) JWT signer per RFC 8037.
 *
 * Verification keys are 32-byte Ed25519 public keys keyed by `kid`. The
 * optional private key is a 64-byte libsodium-format secret key
 * (seed || public key); holders of a bare 32-byte seed can concatenate the
 * matching public key. A signer without a private key is verify-only.
 *
 * Requires the native Ed25519 backend; construction throws on targets where
 * `Ed25519.isAvailable()` is false -- an `IllegalOperationError` naming the
 * target off native cpp.
 */
class Ed25519Signer implements IJWTSigner {
	public var algorithm(get, never):JWTAlgorithm;
	public var signKeyId(get, never):String;

	private var __publicKeys:StringMap<Bytes>;
	private var __privateKey:Bytes;
	private var __signKeyId:String;

	private inline function get_algorithm():JWTAlgorithm {
		return JWTAlgorithm.EdDSA;
	}

	private inline function get_signKeyId():String {
		return __signKeyId;
	}

	public function new(publicKeys:StringMap<Bytes>, ?privateKey:Bytes, ?signKeyId:String) {
		if (!Ed25519.isAvailable()) {
			#if cpp
			throw "Ed25519Signer requires the native Ed25519 backend: " + Ed25519.availabilityMessage();
			#else
			throw NativeOnly.error("EdDSA JWT signing and verification");
			#end
		}
		if (publicKeys == null) {
			throw "Ed25519Signer: publicKeys must not be null";
		}

		__publicKeys = new StringMap();
		var keyCount:Int = 0;
		var soleKeyId:String = null;
		for (keyId in publicKeys.keys()) {
			if (keyId == null || keyId == "") {
				throw "Ed25519Signer: empty key id";
			}
			var publicKey:Bytes = publicKeys.get(keyId);
			if (publicKey == null || publicKey.length != Ed25519.PUBLIC_KEY_BYTES) {
				throw 'Ed25519Signer: public key "$keyId" must be ' + Ed25519.PUBLIC_KEY_BYTES + " bytes";
			}
			__publicKeys.set(keyId, publicKey);
			soleKeyId = keyId;
			keyCount++;
		}
		if (keyCount == 0) {
			throw "Ed25519Signer: at least one public key is required";
		}

		if (privateKey != null) {
			if (privateKey.length != Ed25519.SECRET_KEY_BYTES) {
				throw "Ed25519Signer: private key must be " + Ed25519.SECRET_KEY_BYTES + " bytes (libsodium seed||public format)";
			}
			__privateKey = privateKey;
		}

		if (signKeyId != null) {
			if (!__publicKeys.exists(signKeyId)) {
				throw 'Ed25519Signer: unknown signKeyId "$signKeyId"';
			}
			__signKeyId = signKeyId;
		} else if (keyCount == 1) {
			__signKeyId = soleKeyId;
		} else if (__privateKey != null) {
			throw "Ed25519Signer: multiple public keys provided; signKeyId is required to sign";
		}

		// A libsodium secret key embeds its public key in the last 32 bytes;
		// a mismatch with the declared signing key is a configuration error
		// that would produce tokens no holder of the published key can verify.
		if (__privateKey != null && __signKeyId != null) {
			var declared:Bytes = __publicKeys.get(__signKeyId);
			var embedded:Bytes = __privateKey.sub(Ed25519.SECRET_KEY_BYTES - Ed25519.PUBLIC_KEY_BYTES, Ed25519.PUBLIC_KEY_BYTES);
			if (!ConstantTime.equals(declared, embedded)) {
				throw 'Ed25519Signer: private key does not match public key "' + __signKeyId + '"';
			}
		}
	}

	public function sign(input:String, ?keyId:String):String {
		if (__privateKey == null) {
			throw "Ed25519Signer.sign: no private key configured (verify-only signer)";
		}
		if (keyId != null && keyId != __signKeyId) {
			throw 'Ed25519Signer.sign: unknown signing key id "$keyId"';
		}
		if (input == null) {
			throw "Ed25519Signer.sign: input must not be null";
		}

		var signature:Bytes = Ed25519.signDetached(Bytes.ofString(input), __privateKey);
		return Base64Url.encode(signature);
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
		var publicKey:Bytes = (keyId != null) ? __publicKeys.get(keyId) : (__signKeyId != null ? __publicKeys.get(__signKeyId) : null);
		if (publicKey == null) {
			return false;
		}

		var rawSignature:Null<Bytes> = Base64Url.decode(text, signatureStart, text.length);
		if (rawSignature == null || rawSignature.length != Ed25519.SIGNATURE_BYTES) {
			return false;
		}

		return Ed25519.verifyDetached(rawSignature, Bytes.ofString(input), publicKey);
	}
}
