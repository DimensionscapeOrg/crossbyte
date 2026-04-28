package crossbyte.auth.jwt;

@:structInit
/** Typed view over the standard JWT payload claims used by CrossByte. */
abstract JWTPayload(JWTPayloadData) {
	/** Subject (`sub`) claim. */
	public var subject(get, set):String;
	/** Optional display name or application-specific name claim. */
	public var name(get, set):String;
	/** Issued-at (`iat`) claim as seconds since epoch. */
	public var issuedAt(get, set):Null<Int>;
	/** Expiration (`exp`) claim as seconds since epoch. */
	public var expiresAt(get, set):Null<Int>;
	/** Not-before (`nbf`) claim as seconds since epoch. */
	public var notBeforeTime(get, set):Null<Int>;
	/** Issuer (`iss`) claim. */
	public var issuer(get, set):String;
	/** Audience (`aud`) claim as either a string or array of strings. */
	public var audience(get, set):Dynamic;
	/** JWT ID (`jti`) claim. */
	public var tokenId(get, set):String;

	@:noCompletion private inline function get_subject():String {
		return this.sub;
	}

	@:noCompletion private inline function set_subject(v:String):String {
		return this.sub = v;
	}

	@:noCompletion private inline function get_name():String {
		return this.name;
	}

	@:noCompletion private inline function set_name(v:String):String {
		return this.name = v;
	}

	@:noCompletion private inline function get_issuedAt():Null<Int> {
		return this.iat;
	}

	@:noCompletion private inline function set_issuedAt(v:Null<Int>):Null<Int> {
		return this.iat = v;
	}

	@:noCompletion private inline function get_expiresAt():Null<Int> {
		return this.exp;
	}

	@:noCompletion private inline function set_expiresAt(v:Null<Int>):Null<Int> {
		return this.exp = v;
	}

	@:noCompletion private inline function get_notBeforeTime():Null<Int> {
		return this.nbf;
	}

	@:noCompletion private inline function set_notBeforeTime(v:Null<Int>):Null<Int> {
		return this.nbf = v;
	}

	@:noCompletion private inline function get_issuer():String {
		return this.iss;
	}

	@:noCompletion private inline function set_issuer(v:String):String {
		return this.iss = v;
	}

	@:noCompletion private inline function get_audience():Dynamic {
		return this.aud;
	}

	@:noCompletion private inline function set_audience(v:Dynamic):Dynamic {
		return this.aud = v;
	}

	@:noCompletion private inline function get_tokenId():String {
		return this.jti;
	}

	@:noCompletion private inline function set_tokenId(v:String) {
		return this.jti = v;
	}

	public inline function new(d:JWTPayloadData) {
		this = d;
	}

	@:to public inline function toData():JWTPayloadData {
		return this;
	}

	@:from public static inline function ofData(d:JWTPayloadData):JWTPayload {
		return new JWTPayload(d);
	}
}

/** Raw data shape encoded into a JWT payload segment. */
typedef JWTPayloadData = {
	var sub:String;
	@:optional var name:String;
	var iat:Null<Int>;
	var exp:Null<Int>;
	@:optional var nbf:Null<Int>;
	@:optional var iss:String;
	@:optional var aud:Dynamic;
	@:optional var jti:String;
}
