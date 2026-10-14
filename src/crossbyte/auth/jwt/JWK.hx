package crossbyte.auth.jwt;

import crossbyte.errors.ArgumentError;
import crossbyte.auth.jwt._internal.Base64Url;
import crossbyte.auth.jwt._internal.Der;
import haxe.format.JsonPrinter;
import haxe.io.Bytes;

/**
 * A single public key from a JWK Set (RFC 7517).
 *
 * Only the members needed to verify a signature are modelled: a provider
 * publishes far more than a verifier cares about, and quietly ignoring
 * the rest is what lets a set keep working when a provider adds a field.
 *
 * A key comes from `JWKSet.parse`, or, for an issuer publishing its own
 * Ed25519 keys, from `ofEd25519`; `toJson` writes it back out.
 */
class JWK {
	/**
	 * Key type: `RSA`, `EC`, or `OKP` (RFC 8037's octet key pair, for
	 * Ed25519). Other types are not verifiable here.
	 */
	public var kty(default, null):String;

	/** Key id, matched against a token's `kid` header. May be `null`. */
	public var kid(default, null):Null<String>;

	/** Intended algorithm, for example `RS256`. Often absent. */
	public var alg(default, null):Null<String>;

	/** `sig` or `enc`. Absent means unrestricted, which is treated as `sig`. */
	public var use(default, null):Null<String>;

	/** Curve name: `P-256` for `EC` keys, `Ed25519` for `OKP` keys; no others are supported. */
	public var crv(default, null):Null<String>;

	private var __rsaModulus:Null<Bytes>;
	private var __rsaExponent:Null<Bytes>;
	private var __ecX:Null<Bytes>;
	private var __ecY:Null<Bytes>;
	private var __okpX:Null<Bytes>;
	private var __pem:Null<String>;

	@:allow(crossbyte.auth.jwt.JWKSet)
	private function new() {}

	/**
	 * An Ed25519 public key as a JWK (RFC 8037): `kty` `OKP`, `crv` `Ed25519`,
	 * the key in `x`, with `use` `sig` and `alg` `EdDSA`, so a verifier reading
	 * the set uses it for nothing else. For an issuer publishing the keys its
	 * tokens are signed with; see `JWKSet.ofKeys`.
	 *
	 * ```haxe
	 * var seed = haxe.io.Bytes.ofHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
	 * var pair = crossbyte.crypto.Ed25519.keypairFromSeed(seed);
	 * trace(JWK.ofEd25519("2026-10", pair.publicKey).toJson());
	 * // {"kty":"OKP","kid":"2026-10","use":"sig","alg":"EdDSA","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}
	 * ```
	 *
	 * Pure Haxe, so it works on every target, whether `Ed25519` does or not.
	 *
	 * @param kid The key id tokens signed with it carry, or `null` for a set
	 *        of one unnamed key.
	 * @param publicKey The 32-byte public key, as `Ed25519.keypair` makes it.
	 *        Copied.
	 * @throws ArgumentError For a key that is not 32 bytes, or an empty `kid`.
	 */
	public static function ofEd25519(kid:Null<String>, publicKey:Bytes):JWK {
		if (publicKey == null || publicKey.length != ED25519_KEY_BYTES) {
			throw new ArgumentError("An Ed25519 public key is " + ED25519_KEY_BYTES + " bytes");
		}
		if (kid == "") {
			throw new ArgumentError("A JWK's kid is null or a non-empty string");
		}

		var key:JWK = new JWK();
		key.__setCommon("OKP", kid, "EdDSA", "sig", "Ed25519");
		key.__setOkp(publicKey.sub(0, ED25519_KEY_BYTES));
		return key;
	}

	@:noCompletion private static inline final ED25519_KEY_BYTES:Int = 32;

	/**
	 * The algorithm this key can verify (`RS256`, `ES256` or `EdDSA`), or
	 * `null` if it cannot verify any of them.
	 *
	 * Derived from the key material rather than the `alg` member, which
	 * providers frequently omit. When `alg` *is* present and names a
	 * different algorithm, that is reported instead, so a key published
	 * for `RS512` is not silently used for `RS256`.
	 */
	public function verificationAlgorithm():Null<String> {
		if (use == "enc") {
			return null;
		}

		var derived:Null<String> = switch (kty) {
			case "RSA": "RS256";
			case "EC": crv == "P-256" ? "ES256" : null;
			case "OKP": crv == "Ed25519" ? "EdDSA" : null;
			default: null;
		}

		if (derived == null) {
			return null;
		}

		return (alg == null || alg == "") ? derived : (alg == derived ? derived : null);
	}

	/**
	 * The key as a PEM `SubjectPublicKeyInfo`, which is the form
	 * `JWTSigner.RS256` and `JWTSigner.ES256` accept. An Ed25519 key has no
	 * PEM form here: `JWTSigner.EdDSA` takes `ed25519PublicKey()`.
	 *
	 * Computed once and retained: a verifier reaches for this on every
	 * token, and re-encoding DER per request would be pure waste.
	 *
	 * @throws ArgumentError If the key material is missing or malformed.
	 */
	public function toPem():String {
		if (__pem != null) {
			return __pem;
		}

		__pem = switch (kty) {
			case "RSA": __rsaPem();
			case "EC": __ecPem();
			case "OKP": throw new ArgumentError("An Ed25519 JWK has no PEM form here; JWTSigner.EdDSA takes ed25519PublicKey()");
			default: throw new ArgumentError('unsupported JWK kty "$kty"');
		}

		return __pem;
	}

	/**
	 * The 32 bytes of an Ed25519 key (`OKP`, `crv` `Ed25519`): the form
	 * `JWTSigner.EdDSA` and `Ed25519.verifyDetached` take. A copy, so the key
	 * cannot be changed through it.
	 *
	 * @throws ArgumentError For a key of another kind.
	 */
	public function ed25519PublicKey():Bytes {
		if (kty != "OKP" || crv != "Ed25519" || __okpX == null) {
			throw new ArgumentError('A $kty key is not an Ed25519 key');
		}
		return __okpX.sub(0, __okpX.length);
	}

	/**
	 * The key as a JWK object, its public members only: `kty`, then `kid`,
	 * `use` and `alg` where it has them, then the key itself (`n` and `e`;
	 * `crv`, `x` and `y`; or `crv` and `x`). The same text on every target.
	 * Members a parsed key carried that are not modelled here are not
	 * written, so a private member such as `d` never is.
	 */
	public function toJson():String {
		var out:StringBuf = new StringBuf();
		out.add('{"kty":');
		out.add(JsonPrinter.print(kty));
		__member(out, "kid", kid);
		__member(out, "use", use);
		__member(out, "alg", alg);
		switch (kty) {
			case "RSA":
				__member(out, "n", Base64Url.encode(__rsaModulus));
				__member(out, "e", Base64Url.encode(__rsaExponent));
			case "EC":
				__member(out, "crv", crv);
				__member(out, "x", Base64Url.encode(__ecX));
				__member(out, "y", Base64Url.encode(__ecY));
			case "OKP":
				__member(out, "crv", crv);
				__member(out, "x", Base64Url.encode(__okpX));
			default:
		}
		out.add("}");
		return out.toString();
	}

	private static function __member(out:StringBuf, name:String, value:Null<String>):Void {
		if (value == null) {
			return;
		}
		out.add(',"');
		out.add(name);
		out.add('":');
		out.add(JsonPrinter.print(value));
	}

	private function __rsaPem():String {
		if (__rsaModulus == null || __rsaExponent == null) {
			throw new ArgumentError("RSA JWK is missing n or e");
		}
		if (__rsaModulus.length == 0 || __rsaExponent.length == 0) {
			throw new ArgumentError("RSA JWK has an empty n or e");
		}

		var publicKey:Bytes = Der.sequence([Der.unsignedInteger(__rsaModulus), Der.unsignedInteger(__rsaExponent)]);
		var spki:Bytes = Der.sequence([
			Der.sequence([Der.oid(Der.OID_RSA_ENCRYPTION), Der.nullValue()]),
			Der.bitString(publicKey)
		]);

		return Der.toPem(spki, "PUBLIC KEY");
	}

	private function __ecPem():String {
		if (crv != "P-256") {
			throw new ArgumentError('unsupported EC curve "$crv"; only P-256 is supported');
		}
		if (__ecX == null || __ecY == null) {
			throw new ArgumentError("EC JWK is missing x or y");
		}

		// RFC 7518 6.2.1.2: each coordinate is the full field size, so a
		// value shorter than 32 bytes was published with its leading zeros
		// stripped and has to be padded back rather than shifted.
		var x:Bytes = __padCoordinate(__ecX, 32, "x");
		var y:Bytes = __padCoordinate(__ecY, 32, "y");

		var point:Bytes = Bytes.alloc(65);
		// 0x04 marks an uncompressed point, the only form JWK produces.
		point.set(0, 0x04);
		point.blit(1, x, 0, 32);
		point.blit(33, y, 0, 32);

		var spki:Bytes = Der.sequence([
			Der.sequence([Der.oid(Der.OID_EC_PUBLIC_KEY), Der.oid(Der.OID_PRIME256V1)]),
			Der.bitString(point)
		]);

		return Der.toPem(spki, "PUBLIC KEY");
	}

	private function __padCoordinate(value:Bytes, size:Int, name:String):Bytes {
		if (value.length == size) {
			return value;
		}
		if (value.length > size) {
			throw new ArgumentError('EC JWK coordinate $name is ${value.length} bytes, longer than the $size expected for P-256');
		}

		var padded:Bytes = Bytes.alloc(size);
		padded.blit(size - value.length, value, 0, value.length);
		return padded;
	}

	@:allow(crossbyte.auth.jwt.JWKSet)
	private function __setRsa(modulus:Bytes, exponent:Bytes):Void {
		__rsaModulus = modulus;
		__rsaExponent = exponent;
	}

	@:allow(crossbyte.auth.jwt.JWKSet)
	private function __setEc(x:Bytes, y:Bytes):Void {
		__ecX = x;
		__ecY = y;
	}

	@:allow(crossbyte.auth.jwt.JWKSet)
	private function __setOkp(x:Bytes):Void {
		__okpX = x;
	}

	@:allow(crossbyte.auth.jwt.JWKSet)
	private function __setCommon(kty:String, kid:Null<String>, alg:Null<String>, use:Null<String>, crv:Null<String>):Void {
		this.kty = kty;
		this.kid = kid;
		this.alg = alg;
		this.use = use;
		this.crv = crv;
	}
}
