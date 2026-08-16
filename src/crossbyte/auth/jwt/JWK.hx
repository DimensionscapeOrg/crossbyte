package crossbyte.auth.jwt;

import crossbyte.auth.jwt._internal.Der;
import haxe.io.Bytes;

/**
 * A single public key from a JWK Set (RFC 7517).
 *
 * Only the members needed to verify a signature are modelled: a provider
 * publishes far more than a verifier cares about, and quietly ignoring
 * the rest is what lets a set keep working when a provider adds a field.
 */
class JWK {
	/** Key type: `RSA` or `EC`. Other types are not verifiable here. */
	public var kty(default, null):String;

	/** Key id, matched against a token's `kid` header. May be `null`. */
	public var kid(default, null):Null<String>;

	/** Intended algorithm, for example `RS256`. Often absent. */
	public var alg(default, null):Null<String>;

	/** `sig` or `enc`. Absent means unrestricted, which is treated as `sig`. */
	public var use(default, null):Null<String>;

	/** Curve name for `EC` keys; only `P-256` is supported. */
	public var crv(default, null):Null<String>;

	private var __rsaModulus:Null<Bytes>;
	private var __rsaExponent:Null<Bytes>;
	private var __ecX:Null<Bytes>;
	private var __ecY:Null<Bytes>;
	private var __pem:Null<String>;

	@:allow(crossbyte.auth.jwt.JWKSet)
	private function new() {}

	/**
	 * The algorithm this key can verify — `RS256` or `ES256` — or `null`
	 * if it cannot verify either.
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
			default: null;
		}

		if (derived == null) {
			return null;
		}

		return (alg == null || alg == "") ? derived : (alg == derived ? derived : null);
	}

	/**
	 * The key as a PEM `SubjectPublicKeyInfo`, which is the form
	 * `JWTSigner.RS256` and `JWTSigner.ES256` accept.
	 *
	 * Computed once and retained: a verifier reaches for this on every
	 * token, and re-encoding DER per request would be pure waste.
	 *
	 * @throws String If the key material is missing or malformed.
	 */
	public function toPem():String {
		if (__pem != null) {
			return __pem;
		}

		__pem = switch (kty) {
			case "RSA": __rsaPem();
			case "EC": __ecPem();
			default: throw 'unsupported JWK kty "$kty"';
		}

		return __pem;
	}

	private function __rsaPem():String {
		if (__rsaModulus == null || __rsaExponent == null) {
			throw "RSA JWK is missing n or e";
		}
		if (__rsaModulus.length == 0 || __rsaExponent.length == 0) {
			throw "RSA JWK has an empty n or e";
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
			throw 'unsupported EC curve "$crv"; only P-256 is supported';
		}
		if (__ecX == null || __ecY == null) {
			throw "EC JWK is missing x or y";
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
			throw 'EC JWK coordinate $name is ${value.length} bytes, longer than the $size expected for P-256';
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
	private function __setCommon(kty:String, kid:Null<String>, alg:Null<String>, use:Null<String>, crv:Null<String>):Void {
		this.kty = kty;
		this.kid = kid;
		this.alg = alg;
		this.use = use;
		this.crv = crv;
	}
}
