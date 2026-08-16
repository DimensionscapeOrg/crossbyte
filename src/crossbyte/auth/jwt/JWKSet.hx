package crossbyte.auth.jwt;

import haxe.ds.StringMap;
import haxe.io.Bytes;

/**
 * A key that was published but cannot be used, and why.
 *
 * Rotation is the reason this exists rather than an exception. A provider
 * adds the next key to its JWK Set before it starts signing with it, and
 * that key may be an algorithm this build does not verify. Refusing the
 * whole document over one such entry would lock a service out of the keys
 * it *can* use — at exactly the moment it needs them. Refusing silently
 * is worse, so they are reported.
 */
typedef IgnoredKey = {
	var kid:Null<String>;
	var reason:String;
}

/**
 * A JWK Set (RFC 7517), parsed into verification keys.
 *
 * This is what turns a provider's published keys — Google, Microsoft,
 * Auth0, an in-house issuer — into the PEM maps `JWTSigner.RS256` and
 * `JWTSigner.ES256` take:
 *
 * ```haxe
 * var keys = JWKSet.parse(sys.io.File.getContent("jwks.json"));
 * var jwt = JWT.make(RS256(keys.pemsFor("RS256")), issuer, audience);
 * ```
 *
 * Keys are indexed by `kid`, which is how a token names the key it was
 * signed with and how a set with several keys stays unambiguous across a
 * rotation.
 */
class JWKSet {
	/** Every usable key, in document order. */
	public var keys(default, null):Array<JWK>;

	/**
	 * Keys that were present but not usable, with a reason each.
	 *
	 * Empty for a set this build fully understands. Worth logging on
	 * refresh: an entry appearing here is the first sign that a provider
	 * has started publishing something new.
	 */
	public var ignored(default, null):Array<IgnoredKey>;

	private var __byKid:StringMap<JWK>;

	private function new() {
		keys = [];
		ignored = [];
		__byKid = new StringMap<JWK>();
	}

	/**
	 * Parses a JWK Set document.
	 *
	 * Throws only when the document itself is unusable — not JSON, or
	 * without a `keys` array. Individual keys that cannot be used are
	 * collected into `ignored` instead, so one unrecognised entry cannot
	 * cost a service the rest of its keys.
	 *
	 * @param json The JWK Set document.
	 * @throws String If the document is not a JWK Set.
	 */
	public static function parse(json:String):JWKSet {
		if (json == null || StringTools.trim(json) == "") {
			throw "JWKS document is empty";
		}

		var root:Dynamic;
		try {
			root = haxe.Json.parse(json);
		} catch (e:Dynamic) {
			throw 'JWKS document is not valid JSON: $e';
		}

		if (root == null) {
			throw "JWKS document is not a JSON object";
		}

		var rawKeys:Dynamic = Reflect.field(root, "keys");
		if (rawKeys == null || !Std.isOfType(rawKeys, Array)) {
			throw 'JWKS document has no "keys" array';
		}

		var set:JWKSet = new JWKSet();
		var entries:Array<Dynamic> = cast rawKeys;

		for (entry in entries) {
			set.__ingest(entry);
		}

		return set;
	}

	/**
	 * The key published under `kid`, or `null`.
	 */
	public function get(kid:String):Null<JWK> {
		return kid == null ? null : __byKid.get(kid);
	}

	/**
	 * Every key id in the set, in document order.
	 */
	public function kids():Array<String> {
		var out:Array<String> = [];
		for (key in keys) {
			if (key.kid != null) {
				out.push(key.kid);
			}
		}
		return out;
	}

	/**
	 * PEM verification keys by `kid`, for the keys that can verify
	 * `algorithm` — `RS256` or `ES256`.
	 *
	 * Pass the result straight to `JWTSigner.RS256` or `JWTSigner.ES256`.
	 * A set holding both kinds is normal during a migration between them;
	 * ask for each separately.
	 *
	 * Keys without a `kid` are omitted, since there is no name to look
	 * them up by. A set that is entirely keyless yields an empty map, and
	 * `singlePem` covers that case.
	 */
	public function pemsFor(algorithm:String):StringMap<String> {
		var out:StringMap<String> = new StringMap<String>();

		for (key in keys) {
			if (key.kid == null || key.verificationAlgorithm() != algorithm) {
				continue;
			}
			out.set(key.kid, key.toPem());
		}

		return out;
	}

	/**
	 * The PEM of the only key able to verify `algorithm`, or `null` when
	 * the set holds none or more than one.
	 *
	 * For small issuers that publish a single unnamed key, whose tokens
	 * carry no `kid` to match on. Returning `null` for an ambiguous set is
	 * deliberate: picking one of several keys arbitrarily would verify
	 * some tokens and reject others with no way to tell why.
	 */
	public function singlePem(algorithm:String):Null<String> {
		var found:Null<JWK> = null;

		for (key in keys) {
			if (key.verificationAlgorithm() != algorithm) {
				continue;
			}
			if (found != null) {
				return null;
			}
			found = key;
		}

		return found == null ? null : found.toPem();
	}

	private function __ingest(entry:Dynamic):Void {
		if (entry == null) {
			ignored.push({kid: null, reason: "entry is null"});
			return;
		}

		var kty:Null<String> = __str(entry, "kty");
		var kid:Null<String> = __str(entry, "kid");
		var alg:Null<String> = __str(entry, "alg");
		var use:Null<String> = __str(entry, "use");
		var crv:Null<String> = __str(entry, "crv");

		if (kty == null) {
			ignored.push({kid: kid, reason: 'entry has no "kty"'});
			return;
		}

		var key:JWK = new JWK();
		key.__setCommon(kty, kid, alg, use, crv);

		switch (kty) {
			case "RSA":
				var n:Null<Bytes> = __b64(entry, "n");
				var e:Null<Bytes> = __b64(entry, "e");
				if (n == null || e == null) {
					ignored.push({kid: kid, reason: 'RSA key is missing or has malformed "n" or "e"'});
					return;
				}
				key.__setRsa(n, e);

			case "EC":
				var x:Null<Bytes> = __b64(entry, "x");
				var y:Null<Bytes> = __b64(entry, "y");
				if (x == null || y == null) {
					ignored.push({kid: kid, reason: 'EC key is missing or has malformed "x" or "y"'});
					return;
				}
				key.__setEc(x, y);

			default:
				ignored.push({kid: kid, reason: 'unsupported kty "$kty"'});
				return;
		}

		if (key.verificationAlgorithm() == null) {
			var detail:String = use == "enc" ? 'use is "enc", not a signature key' : 'no supported signature algorithm (kty "$kty", crv "$crv", alg "$alg")';
			ignored.push({kid: kid, reason: detail});
			return;
		}

		// Encoded now rather than lazily so a key that cannot be encoded is
		// reported at parse time, where the reason can be attached to it,
		// instead of throwing later from inside a verification.
		try {
			key.toPem();
		} catch (e:Dynamic) {
			ignored.push({kid: kid, reason: Std.string(e)});
			return;
		}

		// Last one wins on a duplicate kid, matching how a rotation
		// republishes a key id, but the collision is still reported.
		if (kid != null && __byKid.exists(kid)) {
			ignored.push({kid: kid, reason: "duplicate kid; the later key replaced the earlier one"});
			keys.remove(__byKid.get(kid));
		}

		keys.push(key);
		if (kid != null) {
			__byKid.set(kid, key);
		}
	}

	private static function __str(entry:Dynamic, field:String):Null<String> {
		var value:Dynamic = Reflect.field(entry, field);
		if (value == null || !Std.isOfType(value, String)) {
			return null;
		}
		var text:String = cast value;
		return text == "" ? null : text;
	}

	private static function __b64(entry:Dynamic, field:String):Null<Bytes> {
		var encoded:Null<String> = __str(entry, field);
		if (encoded == null) {
			return null;
		}

		try {
			var bytes:Bytes = haxe.crypto.Base64.decode(JWT.normalizeBase64Url(encoded));
			return bytes.length == 0 ? null : bytes;
		} catch (_:Dynamic) {
			return null;
		}
	}
}
