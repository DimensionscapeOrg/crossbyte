package crossbyte.auth;

import haxe.io.Bytes;
import haxe.crypto.Base64;
import haxe.Json;
import haxe.crypto.Hmac;

using StringTools;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * JWTHeader represents the header part of a JWT.
 */
typedef JWTHeader = {
	alg:String,
	typ:String
}

/**
 * JWTPayload represents the payload part of a JWT.
 */
typedef JWTPayload = {
	sub:String,
	name:String,
	iat:Float,
	exp:Float
}

/**
 * JWT (JSON Web Token) utility class for generating and verifying JWT tokens.
 */
class JWT {
	private var secret:String;

	/**
	 * Constructs a new JWT instance with the given secret.
	 *
	 * @param secret The secret key used for signing and verifying tokens.
	 */
	public function new(secret:String) {
		this.secret = secret;
	}

	/**
	 * Generates a JWT token with the given payload.
	 *
	 * @param payload The payload to be included in the token.
	 * @return The generated JWT token.
	 */
	public function generateToken(payload:JWTPayload):String {
		var header:JWTHeader = {alg: "HS256", typ: "JWT"};
		var headerEncoded = base64UrlEncode(Json.stringify(header));
		var payloadEncoded = base64UrlEncode(Json.stringify(payload));
		var signature = createSignature(headerEncoded, payloadEncoded);
		return '${headerEncoded}.${payloadEncoded}.${signature}';
	}

	/**
	 * Verifies a JWT token and returns the payload if valid.
	 *
	 * @param token The JWT token to be verified.
	 * @return The payload if the token is valid, null otherwise.
	 */
	public function verifyToken(token:String):Null<JWTPayload> {
		var parts = token.split('.');
		if (parts.length != 3)
			return null;

		var header:JWTHeader = Json.parse(base64UrlDecode(parts[0]));
		if (header.alg != "HS256")
			return null;

		var expectedSignature = createSignature(parts[0], parts[1]);
		if (!secureCompare(parts[2], expectedSignature))
			return null;

		var payload:JWTPayload = Json.parse(base64UrlDecode(parts[1]));
		if (Std.int(payload.exp) < Std.int(Date.now().getTime() / 1000)) {
			return null;
		}
		return payload;
	}

	private function createSignature(headerEncoded:String, payloadEncoded:String):String {
		var data = '${headerEncoded}.${payloadEncoded}';
		var hash = new Hmac(HashMethod.SHA256).make(Bytes.ofString(secret), Bytes.ofString(data));
		return base64UrlEncode(Base64.encode(hash));
	}

	private static function secureCompare(a:String, b:String):Bool {
		if (a.length != b.length)
			return false;
		var result = 0;
		for (i in 0...a.length) {
			result |= a.charCodeAt(i) ^ b.charCodeAt(i);
		}
		return result == 0;
	}

	private static function base64UrlEncode(data:String):String {
		return Base64.encode(Bytes.ofString(data)).replace("+", "-").replace("/", "_").replace("=", "");
	}

	private static function base64UrlDecode(data:String):String {
		var padded = data + "===".substr(0, (4 - data.length % 4) % 4);
		return Base64.decode(padded.replace("-", "+").replace("_", "/")).toString();
	}
}
