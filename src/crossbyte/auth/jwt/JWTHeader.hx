package crossbyte.auth.jwt;

@:structInit
/** Typed view over the standard JWT header fields. */
abstract JWTHeader(JWTHeaderData) {
	/** Signature algorithm (`alg`) used by the token. */
	/** Header `typ` value. Defaults to `JWT` when created via `make`. */
	public var algorithm(get, set):JWTAlgorithm;
	public var type(get, set):String;
	/** Optional key identifier used during signature selection. */
	public var keyId(get, set):String;
	/** Optional content type for nested JWT payloads. */
	public var contentType(get, set):String;

	@:noCompletion private inline function get_algorithm():String {
		return this.alg;
	}

	@:noCompletion private inline function set_algorithm(v:JWTAlgorithm):String {
		return this.alg = v;
	}

	@:noCompletion private inline function get_type():String {
		return this.typ;
	}

	@:noCompletion private inline function set_type(v:String):String {
		return this.typ = v;
	}

	@:noCompletion private inline function get_keyId():String {
		return this.kid;
	}

	@:noCompletion private inline function set_keyId(v:String):String {
		return this.kid = v;
	}

	@:noCompletion private inline function get_contentType():String {
		return this.cty;
	}

	@:noCompletion private inline function set_contentType(v:String):String {
		return this.cty = v;
	}

	public inline function new(d:JWTHeaderData) {
		this = d;
	}

	/** Builds a standard JWT header for the provided algorithm and optional key id. */
	public static inline function make(algorithm:JWTAlgorithm, ?keyId:String, ?type:String = "JWT"):JWTHeader
		return new JWTHeader({alg: algorithm, typ: type, kid: keyId});

	/** Returns `true` when the header uses a supported algorithm and expected type. */
	public inline function isValid(?requireTypeJWT:Bool = true):Bool {
		if (requireTypeJWT && this.typ != "JWT") {
			return false;
		}
		return switch (algorithm) {
			case HS256 | EdDSA | RS256: true;
			default: false;
		}
	}

	@:to public inline function toData():JWTHeaderData
		return this;

	@:from public static inline function ofData(d:JWTHeaderData):JWTHeader
		return new JWTHeader(d);
}

/** Raw data shape encoded into a JWT header segment. */
typedef JWTHeaderData = {
	var alg:JWTAlgorithm;
	var typ:String;
	@:optional var kid:String;
	@:optional var cty:String;
}
