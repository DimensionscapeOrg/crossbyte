package crossbyte.auth.jwt._internal.sign;

import haxe.ds.StringMap;
import haxe.io.Bytes;
import crossbyte.auth.Secret;
import crossbyte.auth.jwt.JWTAlgorithm;
import crossbyte.auth.jwt._internal.Base64Url;
import crossbyte.crypto._internal.HmacSha256;

/**
 * HS256: HMAC-SHA-256 under shared secrets, by key id.
 *
 * Each secret's HMAC key blocks are hashed once, here, and kept
 * (`HmacSha256`), and a token is checked in place: the MAC is taken over
 * the token's own characters and compared, in constant time, with the 32
 * bytes its signature decodes to. Nothing is rebuilt, copied or encoded as
 * text per token.
 *
 * Only the one canonical spelling of a signature decodes, so a token is
 * accepted in exactly the spelling a string comparison accepted.
 */
class HS256Signer implements IJWTSigner {
	public var algorithm(get, never):JWTAlgorithm;
	public var keys(get, never):StringMap<String>;
	public var signKeyId(get, never):String;

	private var __keys:StringMap<String>;
	private var __macs:StringMap<HmacSha256>;
	private var __signKeyId:String;
	private var __hasSoleSecret:Bool;

	/**
	 * The sole secret's MAC, which a token naming no key is checked with;
	 * null when there are several. Found once, here, rather than by
	 * iterating the key map for each such token, which natively copies
	 * every key.
	 */
	private var __soleMac:Null<HmacSha256>;

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
		__macs = new StringMap();
		var soleKeyId:Null<String> = null;

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
			__macs.set(keyId, new HmacSha256(Bytes.ofString(secret.secret)));
			soleKeyId = keyId;
		}

		if (__hasSoleSecret) {
			__soleMac = __macs.get(soleKeyId);
		}

		if (signKeyId != null) {
			if (!__keys.exists(signKeyId)) {
				throw 'HS256Signer: unknown signKeyId "$signKeyId"';
			}
			__signKeyId = signKeyId;
		} else {
			__signKeyId = __hasSoleSecret ? soleKeyId : null;
			if (!__hasSoleSecret && __signKeyId == null) {
				throw "HS256Signer: multiple keys provided; signKeyId is required";
			}
		}
	}

	/**
	 * Minimum secret length, in bytes, recommended for HS256 signing keys.
	 *
	 * RFC 7518 requires an HMAC-SHA-256 key to be at least the size of the hash
	 * output (256 bits / 32 bytes). Shorter secrets are accepted for backward
	 * compatibility but are not considered cryptographically strong.
	 */
	public static inline final RECOMMENDED_SECRET_BYTES:Int = 32;

	/**
	 * Reports whether `secret` meets the recommended strength for an HS256 key.
	 *
	 * This is an advisory check only and does not affect signing or verification:
	 * secrets shorter than `RECOMMENDED_SECRET_BYTES` are still usable. Callers may
	 * use it to warn operators about weak configuration. Returns `false` for a
	 * `null` secret.
	 */
	public static inline function isSecretStrong(secret:String):Bool {
		return secret != null && Bytes.ofString(secret).length >= RECOMMENDED_SECRET_BYTES;
	}

	public function sign(input:String, ?keyId:String):String {
		keyId = keyId != null ? keyId : __signKeyId;

		if (keyId == null) {
			throw "HS256Signer.sign: no key id available";
		}
		var mac:Null<HmacSha256> = __macs.get(keyId);
		if (mac == null) {
			throw 'HS256Signer.sign: unknown key id "$keyId"';
		}

		return Base64Url.encode(mac.macText(input, 0, input.length));
	}

	public function verify(input:String, signature:String, ?keyId:String):Bool {
		if (input == null || signature == null) {
			return false;
		}
		var mac:Null<HmacSha256> = __macFor(keyId);
		if (mac == null) {
			return false;
		}
		var expected:Null<Bytes> = Base64Url.decodeCanonical(signature, 0, signature.length);
		return expected != null && mac.verifyText(input, 0, input.length, expected);
	}

	public function verifyToken(token:String, inputEnd:Int, keyId:Null<String>):Bool {
		var mac:Null<HmacSha256> = __macFor(keyId);
		if (mac == null) {
			return false;
		}
		var expected:Null<Bytes> = Base64Url.decodeCanonical(token, inputEnd + 1, token.length);
		return expected != null && mac.verifyText(token, 0, inputEnd, expected);
	}

	public function hasKey(keyId:Null<String>):Bool {
		return keyId != null ? __keys.exists(keyId) : __hasSoleSecret;
	}

	private inline function __macFor(keyId:Null<String>):Null<HmacSha256> {
		return keyId != null ? __macs.get(keyId) : __soleMac;
	}
}
