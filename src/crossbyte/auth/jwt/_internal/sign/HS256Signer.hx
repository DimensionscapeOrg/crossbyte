package crossbyte.auth.jwt._internal.sign;

import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.crypto.Hmac;
import haxe.crypto.Hmac.HashMethod;
import crossbyte.auth.jwt.JWT;
import crossbyte.auth.Secret;
import crossbyte.auth.jwt.JWTAlgorithm;

class HS256Signer implements IJWTSigner {
	public var algorithm(get, never):JWTAlgorithm;
	public var keys(get, never):StringMap<String>;
	public var signKeyId(get, never):String;

	private var __keys:StringMap<String>;
	private var __signKeyId:String;
	private var __hasSoleSecret:Bool;

	private inline function get_algorithm():JWTAlgorithm {
		return JWTAlgorithm.HS256;
	}

	private inline function get_keys():StringMap<String> {
		return __keys;
	}

	private inline function get_signKeyId():String {
		return __signKeyId;
	}

	public function new(secrets:Array<Secret>, ?signKeyId:String) {
		if (secrets == null || secrets.length == 0) {
			throw "Must include at least one JWT secret";
		}

		__hasSoleSecret = secrets.length == 1;

		__keys = new StringMap();

		for (i in 0...secrets.length) {
			var secret:Secret = secrets[i];
			var keyId:String = secret.key;
			if (keyId == null || keyId == "") {
				if (__hasSoleSecret) {
					keyId = "default";
				} else {
					throw 'HS256Signer: key missing for secret at index $i';
				}
			}

			if (__keys.exists(keyId)) {
				throw 'HS256Signer: duplicate key id "$keyId"';
			}
			if (secret.secret == null || secret.secret.length == 0) {
				throw 'HS256Signer: empty secret for key "$keyId"';
			}
			__keys.set(keyId, secret.secret);
		}

		if (signKeyId != null) {
			if (!__keys.exists(signKeyId)) {
				throw 'HS256Signer: unknown signKeyId "$signKeyId"';
			}
			__signKeyId = signKeyId;
		} else {
			__signKeyId = __hasSoleSecret ? __singleKeyId() : null;
			if (!__hasSoleSecret && __signKeyId == null) {
				throw "HS256Signer: multiple keys provided; signKeyId is required";
			}
		}
	}

	public function sign(input:String, ?keyId:String):String {
		keyId = keyId != null ? keyId : (__signKeyId != null ? __signKeyId : (__hasSoleSecret ? __singleKeyId() : null));

		if (keyId == null) {
			throw "HS256Signer.sign: no key id available";
		}
		var secret:String = __keys.get(keyId);
		if (secret == null) {
			throw 'HS256Signer.sign: unknown key id "$keyId"';
		}

		var mac:Bytes = new Hmac(HashMethod.SHA256).make(Bytes.ofString(secret), Bytes.ofString(input));
		return JWT.base64UrlEncodeBytes(mac);
	}

	public function verify(input:String, signature:String, ?keyId:String):Bool {
		if (keyId != null) {
			var secret:String = __keys.get(keyId);
			if (secret == null) {
				return false;
			}
			var mac:Bytes = new Hmac(HashMethod.SHA256).make(Bytes.ofString(secret), Bytes.ofString(input));

            return JWT.secureCompare(signature, JWT.base64UrlEncodeBytes(mac));
		}

		if (__hasSoleSecret) {
			var soleKeyId:String = __singleKeyId();
			if (soleKeyId == null) {
				return false;
			}
			var secret:String = __keys.get(soleKeyId);
			if (secret == null) {
				return false;
			}
			var mac:Bytes = new Hmac(HashMethod.SHA256).make(Bytes.ofString(secret), Bytes.ofString(input));

            return JWT.secureCompare(signature, JWT.base64UrlEncodeBytes(mac));
		}

		return false;
	}

	private inline function __singleKeyId():String {
		var k:String = null;
		var seen:Bool = false;
		for (id in __keys.keys()) {
			if (!seen) {
				k = id;
				seen = true;
			} else{
                k = null;
                break;
            }
		}
		return k;
	}
}
