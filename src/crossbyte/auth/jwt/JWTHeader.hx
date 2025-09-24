package crossbyte.auth.jwt;

@:structInit
abstract JWTHeader(JWTHeaderData) {
	public var algorithm(get, set):JWTAlgorithm;
	public var type(get, set):String;
	public var keyId(get, set):String;
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

	public static inline function make(algorithm:JWTAlgorithm, ?keyId:String, ?type:String = "JWT"):JWTHeader
		return new JWTHeader({alg: algorithm, typ: type, kid: keyId});

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

typedef JWTHeaderData = {
	var alg:JWTAlgorithm;
	var typ:String;
	@:optional var kid:String;
	@:optional var cty:String;
}
