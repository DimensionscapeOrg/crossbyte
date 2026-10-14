package crossbyte.auth.jwt;

import crossbyte.errors.ArgumentError;
import crossbyte._internal.serial.JsonNesting;
import crossbyte.auth.jwt._internal.Base64Url;
import haxe.ds.StringMap;
import haxe.io.Bytes;

/**
 * A key that was published but cannot be used, and why.
 *
 * Rotation is the reason this exists rather than an exception. A provider
 * adds the next key to its JWK Set before it starts signing with it, and
 * that key may be an algorithm this build does not verify. Refusing the
 * whole document over one such entry would lock a service out of the keys
 * it *can* use, at exactly the moment it needs them. Refusing silently
 * is worse, so they are reported.
 */
@:structInit
final class IgnoredKey {
	/** The key's `kid`, or `null` when it had none. */
	public var kid:Null<String> = null;

	/** Why the key cannot be used. */
	public var reason:String;
}

/**
 * A JWK Set (RFC 7517), parsed into verification keys.
 *
 * This is what turns a provider's published keys (Google, Microsoft,
 * Auth0, an in-house issuer) into the keys `JWTSigner.RS256`,
 * `JWTSigner.ES256` and `JWTSigner.EdDSA` take:
 *
 * ```haxe
 * // Given issuer:String, audience:String.
 * var keys = JWKSet.parse(sys.io.File.getContent("jwks.json"));
 * var jwt = JWT.make(keys.signer(RS256), issuer, audience);
 * ```
 *
 * Keys are indexed by `kid`, which is how a token names the key it was
 * signed with and how a set with several keys stays unambiguous across a
 * rotation.
 *
 * ## Publishing keys
 *
 * An issuer signing with Ed25519 publishes its public keys as a set, so the
 * services verifying its tokens hold no secret. During a rotation the set
 * holds the retiring key and the next one; verifiers fetch it again when a
 * token names a key they do not hold (`UNKNOWN_KEY`):
 *
 * ```haxe
 * // Given current:crossbyte.crypto.SigningKeyPair, next:crossbyte.crypto.SigningKeyPair.
 * var published:String = JWKSet.ofKeys([
 * 	JWK.ofEd25519("2026-10", current.publicKey),
 * 	JWK.ofEd25519("2026-11", next.publicKey)
 * ]).toJson();
 *
 * // A verifier, holding no secret:
 * var verifier = JWT.make(JWKSet.parse(published).signer(EdDSA), "https://accounts.example");
 * ```
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
	 * Throws only when the document itself is unusable: not JSON, nested
	 * more than 32 levels deep, or without a `keys` array. Individual keys
	 * that cannot be used are collected into `ignored` instead, so one
	 * unrecognised entry cannot cost a service the rest of its keys.
	 *
	 * The nesting, objects and arrays together, is measured before the
	 * document is parsed; a real set nests three or four levels. Parsing
	 * takes a frame per level, and natively a document nested 6,000 deep
	 * (12 KB from a provider's endpoint, or from whoever can answer for it)
	 * would overflow the stack and end the process.
	 *
	 * @param json The JWK Set document.
	 * @throws ArgumentError If the document is not a JWK Set.
	 */
	public static function parse(json:String):JWKSet {
		if (json == null || StringTools.trim(json) == "") {
			throw new ArgumentError("JWKS document is empty");
		}

		if (!JsonNesting.within(json, JsonNesting.LIMIT)) {
			throw new ArgumentError('JWKS document nests more than ${JsonNesting.LIMIT} levels deep');
		}

		var root:Dynamic;
		try {
			root = haxe.Json.parse(json);
		} catch (e:Dynamic) {
			throw new ArgumentError('JWKS document is not valid JSON: $e');
		}

		if (root == null) {
			throw new ArgumentError("JWKS document is not a JSON object");
		}

		var rawKeys:Dynamic = Reflect.field(root, "keys");
		if (rawKeys == null || !Std.isOfType(rawKeys, Array)) {
			throw new ArgumentError('JWKS document has no "keys" array');
		}

		var set:JWKSet = new JWKSet();
		var entries:Array<Dynamic> = cast rawKeys;

		for (entry in entries) {
			set.__ingest(entry);
		}

		return set;
	}

	/**
	 * A set of the given keys, in that order, to write out with `toJson`: the
	 * document an issuer publishes.
	 *
	 * @throws ArgumentError For a null array or entry, or two keys with the
	 *         same `kid`, which would leave a token naming it ambiguous.
	 */
	public static function ofKeys(keys:Array<JWK>):JWKSet {
		if (keys == null) {
			throw new ArgumentError("JWKSet.ofKeys was given no keys");
		}

		var set:JWKSet = new JWKSet();
		for (key in keys) {
			if (key == null) {
				throw new ArgumentError("JWKSet.ofKeys was given a null key");
			}
			if (key.kid != null) {
				if (set.__byKid.exists(key.kid)) {
					throw new ArgumentError('JWKSet.ofKeys was given two keys named "${key.kid}"');
				}
				set.__byKid.set(key.kid, key);
			}
			set.keys.push(key);
		}
		return set;
	}

	/**
	 * The set as a JWK Set document, `{"keys":[...]}`, each key as
	 * `JWK.toJson` writes it, in order. The same text on every target, and
	 * `parse` reads it back. Keys in `ignored` are not written.
	 */
	public function toJson():String {
		var out:StringBuf = new StringBuf();
		out.add('{"keys":[');
		for (i in 0...keys.length) {
			if (i > 0) {
				out.add(",");
			}
			out.add(keys[i].toJson());
		}
		out.add("]}");
		return out.toString();
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
	 * `algorithm`: `RS256` or `ES256`.
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

	/**
	 * The keys that verify `algorithm` (`RS256`, `ES256` or `EdDSA`) as the
	 * verify-only `JWTSigner` that `JWT.make` and `JWT.updateKeys` take.
	 *
	 * Keys are named by `kid`. A set whose only usable key has none is given
	 * it under `default`, which a token naming no key resolves to.
	 *
	 * ```haxe
	 * // Given jwt:JWT, fetchedJson:String.
	 * jwt.updateKeys(JWKSet.parse(fetchedJson).signer(RS256));
	 * ```
	 *
	 * An `EdDSA` signer needs `Ed25519` where `JWT.make` is called: natively,
	 * or on PHP with the sodium extension.
	 *
	 * @throws ArgumentError When `algorithm` is none of them, or no key here verifies it.
	 */
	public function signer(algorithm:JWTAlgorithm):JWTSigner {
		if (algorithm == JWTAlgorithm.EdDSA) {
			return EdDSA(__ed25519Keys());
		}
		if (algorithm != JWTAlgorithm.RS256 && algorithm != JWTAlgorithm.ES256) {
			throw new ArgumentError('A JWK Set verifies RS256, ES256 or EdDSA, not "$algorithm"');
		}

		var pems:StringMap<String> = pemsFor(algorithm);
		if (!pems.keys().hasNext()) {
			var single:Null<String> = singlePem(algorithm);
			if (single == null) {
				throw new ArgumentError('The JWK Set holds no key that verifies $algorithm');
			}
			pems.set("default", single);
		}

		return algorithm == JWTAlgorithm.RS256 ? RS256(pems) : ES256(pems);
	}

	/** The Ed25519 keys by `kid`, a lone unnamed one as `default`, as `signer` names them. **/
	private function __ed25519Keys():StringMap<Bytes> {
		var named:StringMap<Bytes> = new StringMap<Bytes>();
		var count:Int = 0;
		var unnamed:Null<JWK> = null;
		var unnamedCount:Int = 0;
		for (key in keys) {
			if (key.verificationAlgorithm() != (JWTAlgorithm.EdDSA : String)) {
				continue;
			}
			if (key.kid != null) {
				named.set(key.kid, key.ed25519PublicKey());
				count++;
			} else {
				unnamed = key;
				unnamedCount++;
			}
		}
		if (count == 0) {
			// As singlePem: one unnamed key, and only one key at all.
			if (unnamedCount == 0) {
				throw new ArgumentError("The JWK Set holds no key that verifies EdDSA");
			}
			if (unnamedCount > 1) {
				throw new ArgumentError("The JWK Set holds " + unnamedCount + " unnamed EdDSA keys, which no token can tell apart");
			}
			named.set("default", unnamed.ed25519PublicKey());
		}
		return named;
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

			case "OKP":
				// RFC 8037: Ed25519 signs; X25519 and X448 agree keys, and
				// Ed448 is not verified here.
				if (crv != "Ed25519") {
					ignored.push({kid: kid, reason: 'unsupported OKP curve "$crv"; only Ed25519 is supported'});
					return;
				}
				var x:Null<Bytes> = __b64(entry, "x");
				if (x == null || x.length != 32) {
					ignored.push({kid: kid, reason: 'Ed25519 key is missing "x" or it is not 32 bytes'});
					return;
				}
				key.__setOkp(x);

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
		if (kty != "OKP") {
			try {
				key.toPem();
			} catch (e:Dynamic) {
				ignored.push({kid: kid, reason: Std.string(e)});
				return;
			}
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

		var bytes:Null<Bytes> = Base64Url.decode(encoded, 0, encoded.length);
		return bytes == null || bytes.length == 0 ? null : bytes;
	}
}
