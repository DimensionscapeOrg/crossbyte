package crossbyte.auth.jwt;

import haxe.io.Bytes;
import haxe.crypto.Base64;
import haxe.Json;
import haxe.Timer;
import crossbyte.auth.jwt._internal.sign.IJWTSigner;
import crossbyte.auth.jwt._internal.sign.HS256Signer;

using StringTools;

class JWT {
	@:noCompletion private var __signer:IJWTSigner;

	public var expectedIssuer:String;
	public var expectedAudience:String;
	public var leeway:Int = 60;

	public static function make(spec:JWTSigner, ?issuer:String, ?audience:String, ?leeway:Int = 60):JWT {
		var signer:IJWTSigner = switch (spec) {
			case HS256(secrets, signKeyId):
				new HS256Signer(secrets, signKeyId);

			case EdDSA(_, _, _):
				throw "EdDSA signer not implemented on this target yet";

			case RS256(_, _, _):
				throw "RS256 signer not implemented on this target yet";
		};

		var jwt = new JWT(signer);
		jwt.expectedIssuer = issuer;
		jwt.expectedAudience = audience;
		jwt.leeway = leeway;
		return jwt;
	}

	@:noCompletion private function new(signer:IJWTSigner) {
		this.__signer = signer;
	}

	public function generateToken(payload:JWTPayload):String {
		var header:JWTHeader = JWTHeader.make(__signer.algorithm, __signer.signKeyId, "JWT");
		var headerStr:String = base64UrlEncodeString(Json.stringify(header.toData()));
		var payloadStr:String = base64UrlEncodeString(Json.stringify(payload.toData()));
		var signature:String = __signer.sign(headerStr + "." + payloadStr, header.keyId);
		return headerStr + "." + payloadStr + "." + signature;
	}

	public function verifyToken(token:String):JWTPayload {
		if (token == null || token.length == 0 || token.length > 4096) {
			return null;
		}

		var parts = token.split('.');
		if (parts.length != 3) {
			return null;
		}

		var headerStr:String = safeBase64UrlEncodeString(parts[0]);
		if (headerStr == null) {
			return null;
		}
		var header:JWTHeader;
		try {
			header = JWTHeader.ofData(Json.parse(headerStr));
		} catch (_:Dynamic) {
			return null;
		}

		if (!header.isValid(true)) {
			return null;
		}
		if (header.algorithm != __signer.algorithm) {
			return null;
		}

		if (!__signer.verify(parts[0] + "." + parts[1], parts[2], header.keyId)) {
			return null;
		}

		var payloadStr:String = safeBase64UrlEncodeString(parts[1]);
		if (payloadStr == null) {
			return null;
		}
		var payload:JWTPayload;
		try {
			payload = JWTPayload.ofData(Json.parse(payloadStr));
		} catch (_:Dynamic) {
			return null;
		}

		var nowSec:Int = Std.int(Timer.stamp());
		if (payload.expiresAt == null || nowSec > payload.expiresAt + leeway) {
			return null;
		}
		if (payload.issuedAt != null && (nowSec + leeway) < payload.issuedAt) {
			return null;
		}
		if (payload.notBeforeTime != null && (nowSec + leeway) < payload.notBeforeTime) {
			return null;
		}

		if (expectedIssuer != null && payload.issuer != expectedIssuer) {
			return null;
		}
		if (expectedAudience != null && !__audMatches(expectedAudience, payload.audience)) {
			return null;
		}

		return payload;
	}

	@:noCompletion private static function __audMatches(expected:String, aud:Dynamic):Bool {
		if (aud == null) {
			return false;
		}
		if (Std.isOfType(aud, String)) {
			return (cast aud : String) == expected;
		}
		if (Std.isOfType(aud, Array)) {
			var arr:Array<Dynamic> = cast aud;
			for (v in arr) {
				if (Std.isOfType(v, String) && (cast v : String) == expected) {
					return true;
				}
			}
			return false;
		}
		return false;
	}

	public static inline function base64UrlEncodeString(s:String):String {
		return base64UrlEncodeBytes(Bytes.ofString(s));
	}

	@:noCompletion private static inline function __stripPad(s:String):String {
		var i:Int = s.length, eq = '='.code;
		while (i > 0 && s.charCodeAt(i - 1) == eq) {
			i--;
		}
		return s.substr(0, i);
	}

	public static inline function base64UrlEncodeBytes(b:Bytes):String {
		var s:String = Base64.encode(b);
		s = s.split("+").join("-").split("/").join("_");
		return __stripPad(s);
	}

	public static inline function normalizeBase64Url(s:String):String {
		var std:String = s.split("-").join("+").split("_").join("/");
		switch (std.length % 4) {
			case 2:
				std += "==";
			case 3:
				std += "=";
			case 0:
			case 1:
				throw "invalid base64url length";
		}
		return std;
	}

	public static function safeBase64UrlEncodeString(s:String):Null<String> {
		var b64:String = s.split("-").join("+").split("_").join("/");
		switch (b64.length % 4) {
			case 2:
				b64 += "==";
			case 3:
				b64 += "=";
			case 0:
			case 1:
				return null;
		}
		try {
			return Base64.decode(b64).toString();
		} catch (_:Dynamic) {
			return null;
		}
	}

	public static inline function secureCompare(a:String, b:String):Bool {
		if (a.length != b.length) {
			return false;
		}
		var diff:Int = 0;
		for (i in 0...a.length) {
			diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
		}
		return diff == 0;
	}
}
