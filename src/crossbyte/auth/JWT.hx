package crossbyte.auth;

import haxe.crypto.Base64;
import haxe.crypto.Sha256;
import haxe.Json;
import haxe.crypto.Hmac;

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

		var headerEncoded = parts[0];
		var payloadEncoded = parts[1];
		var signature = parts[2];

		var expectedSignature = createSignature(headerEncoded, payloadEncoded);
		if (signature != expectedSignature)
			return null;

		var payload:JWTPayload = Json.parse(base64UrlDecode(payloadEncoded));

		// Verify expiration
		if (payload.exp < Date.now().getTime() / 1000) {
			return null; // Token has expired
		}

		return payload;
	}

	private function createSignature(headerEncoded:String, payloadEncoded:String):String {
		var data = '${headerEncoded}.${payloadEncoded}';
		var hash = Hmac.sha256(secret, data);
		return base64UrlEncode(hash);
	}

	private static function base64UrlEncode(data:String):String {
		return Base64.encode(data).replace('+', '-').replace('/', '_').replace('=', '');
	}

	private static function base64UrlDecode(data:String):String {
		return Base64.decode(data.replace('-', '+').replace('_', '/'));
	}
}
