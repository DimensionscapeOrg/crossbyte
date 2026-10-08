package crossbyte.auth.jwt;

/**
 * Typed view over a JWT's claims.
 *
 * The registered claims have properties. Any other claim (an application's
 * `role`, an identity provider's `groups`) goes in the same object literal
 * and is read back with `claim`:
 *
 * ```haxe
 * var token = jwt.generateToken({sub: "user-1", exp: now + 3600, role: "admin"});
 * var role:String = jwt.verifyToken(token).claim("role");
 * ```
 *
 * Times are seconds since the epoch, as RFC 7519's NumericDate: a JSON number,
 * which may be fractional. They are `Float`s, so a time after January 2038
 * fits, and read back as `Float`s. A literal may give them as `Int`s, as
 * long as it gives every one of them so, or every one as a `Float`; one
 * mixing the two converts either side (`now + 3600.0`, say, beside a
 * `Float` `iat`).
 *
 * The audience is a `JWTAudience`: one string or an array of them, asked
 * with `contains`.
 */
abstract JWTPayload(JWTPayloadData) {
	/** Subject (`sub`) claim. */
	public var subject(get, set):String;
	/** Optional display name or application-specific name claim. */
	public var name(get, set):String;
	/** Issued-at (`iat`) claim, in seconds since the epoch. */
	public var issuedAt(get, set):Null<Float>;
	/** Expiration (`exp`) claim, in seconds since the epoch. */
	public var expiresAt(get, set):Null<Float>;
	/** Not-before (`nbf`) claim, in seconds since the epoch. */
	public var notBeforeTime(get, set):Null<Float>;
	/** Issuer (`iss`) claim. */
	public var issuer(get, set):String;
	/**
	 * Audience (`aud`) claim: one string or an array of them. Ask whether it
	 * names a service with `contains`.
	 */
	public var audience(get, set):JWTAudience;
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

	@:noCompletion private inline function get_issuedAt():Null<Float> {
		return __time(this.iat);
	}

	@:noCompletion private inline function set_issuedAt(v:Null<Float>):Null<Float> {
		this.iat = v;
		return v;
	}

	@:noCompletion private inline function get_expiresAt():Null<Float> {
		return __time(this.exp);
	}

	@:noCompletion private inline function set_expiresAt(v:Null<Float>):Null<Float> {
		this.exp = v;
		return v;
	}

	@:noCompletion private inline function get_notBeforeTime():Null<Float> {
		return __time(this.nbf);
	}

	@:noCompletion private inline function set_notBeforeTime(v:Null<Float>):Null<Float> {
		this.nbf = v;
		return v;
	}

	@:noCompletion private inline function get_issuer():String {
		return this.iss;
	}

	@:noCompletion private inline function set_issuer(v:String):String {
		return this.iss = v;
	}

	@:noCompletion private inline function get_audience():JWTAudience {
		return this.aud;
	}

	@:noCompletion private inline function set_audience(v:JWTAudience):JWTAudience {
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

	/**
	 * Any claim by name, registered or not, as the token carried it; `null`
	 * when absent.
	 */
	public inline function claim(name:String):Dynamic {
		return Reflect.field(this, name);
	}

	/** Whether the claims include `name`. */
	public inline function hasClaim(name:String):Bool {
		return Reflect.hasField(this, name);
	}

	/**
	 * Sets a claim by name, for claims added after the payload was built.
	 *
	 * @return This payload, so calls chain.
	 */
	public function setClaim(name:String, value:Dynamic):JWTPayload {
		Reflect.setField(this, name, value);
		return new JWTPayload(this);
	}

	/**
	 * A time as it reads back: the field itself, checked when the token was
	 * decoded or made. Except on the interpreter and neko, where a `Float`
	 * decoded or made. Except on the interpreter and neko, where a `Float`
	 * variable given an `Int` keeps doing `Int` arithmetic (the leeway
	 * added to 2147483647 would wrap there), so an `Int` a literal gave is
	 * converted as it is read.
	 */
	@:noCompletion private static inline function __time(value:Null<Float>):Null<Float> {
		#if (eval || neko)
		return seconds(value);
		#else
		return value;
		#end
	}

	/**
	 * Seconds since the epoch from a claim as JSON gives it (an `Int` or a
	 * `Float` depending on the target and the size of the number), or `null`
	 * when it is absent or not a finite number.
	 */
	@:allow(crossbyte.auth.jwt.JWT)
	@:noCompletion private static function seconds(value:Dynamic):Null<Float> {
		if (value == null) {
			return null;
		}
		if (Std.isOfType(value, Int)) {
			// `+ 0.0` rather than a typed assignment: on the interpreter a Float
			// variable given an Int keeps Int arithmetic, and the leeway added
			// to 2147483647 would wrap.
			return (value : Int) + 0.0;
		}
		if (Std.isOfType(value, Float)) {
			var number:Float = value;
			return Math.isFinite(number) ? number : null;
		}
		return null;
	}

	@:to public inline function toData():JWTPayloadData {
		return this;
	}

	/**
	 * Takes a claims object literal: the registered claims, typed, and any other
	 * claims beside them.
	 *
	 * Generic so that a literal may carry claims the typedef does not name: a
	 * closed structure refuses them with "has extra field". The registered
	 * claims keep their types, the times as `Float`s; a literal whose times
	 * are all `Int`s converts through the conversion beside this one.
	 */
	@:from public static inline function ofClaims<T:JWTPayloadData>(claims:T):JWTPayload {
		return new JWTPayload(claims);
	}

	/**
	 * `ofClaims` for a literal whose times are all `Int`s (`{sub: id, iat:
	 * now, exp: now + 600}` with an `Int` `now`), which the `Float` fields
	 * refuse: a structure's field types have to match exactly. They are read
	 * back as `Float`s, and written as integers.
	 */
	@:from @:noCompletion public static inline function ofIntClaims<T:JWTPayloadIntData>(claims:T):JWTPayload {
		return new JWTPayload(cast claims);
	}

	/**
	 * Takes the registered claims alone.
	 *
	 * `JWTPayloadData` is a closed structure, so a literal carrying a claim of
	 * an application's own (`{sub: id, exp: now + 600, role: "admin"}`)
	 * does not compile here. Give such a literal where a `JWTPayload` is
	 * expected, which converts it through `ofClaims`, or add the claim
	 * afterwards with `setClaim`.
	 */
	public static inline function ofData(d:JWTPayloadData):JWTPayload {
		return new JWTPayload(d);
	}
}

/**
 * Raw data shape encoded into a JWT payload segment: the registered claims.
 * A payload may carry others beside them; see `JWTPayload`.
 */
typedef JWTPayloadData = {
	@:optional var sub:String;
	@:optional var name:String;

	/** Issued-at, in seconds since the epoch. */
	@:optional var iat:Float;

	/**
	 * Expiry, in seconds since the epoch. `JWT.verify` refuses a token
	 * without one.
	 */
	var exp:Null<Float>;

	/** Not-before, in seconds since the epoch. */
	@:optional var nbf:Float;

	@:optional var iss:String;
	@:optional var aud:JWTAudience;
	@:optional var jti:String;
}

/**
 * `JWTPayloadData` with its times as `Int`s, for `JWTPayload.ofIntClaims`
 * alone.
 */
@:noCompletion
typedef JWTPayloadIntData = {
	@:optional var sub:String;
	@:optional var name:String;
	@:optional var iat:Int;
	var exp:Null<Int>;
	@:optional var nbf:Int;
	@:optional var iss:String;
	@:optional var aud:JWTAudience;
	@:optional var jti:String;
}
