package crossbyte.auth.jwt;

/**
 * Typed view over a JWT's claims.
 *
 * The registered claims have properties. Any other claim -- an application's
 * `role`, an identity provider's `groups` -- goes in the same object literal
 * and is read back with `claim`:
 *
 * ```haxe
 * var token = jwt.generateToken({sub: "user-1", exp: now + 3600, role: "admin"});
 * var role:String = jwt.verifyToken(token).claim("role");
 * ```
 *
 * Times are seconds since the epoch, as RFC 7519's NumericDate: a JSON number,
 * which may be fractional. Write them as an `Int` or a `Float`; they read back
 * as `Float`. They were `Int`, so a time after January 2038 did not fit, and
 * adding the leeway to one near that limit wrapped where an `Int` is 32 bits:
 * one token was expired on the interpreter and the jvm and valid on cpp and
 * Node.
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

	@:noCompletion private inline function get_issuedAt():Null<Float> {
		return seconds(this.iat);
	}

	@:noCompletion private inline function set_issuedAt(v:Null<Float>):Null<Float> {
		this.iat = v;
		return v;
	}

	@:noCompletion private inline function get_expiresAt():Null<Float> {
		return seconds(this.exp);
	}

	@:noCompletion private inline function set_expiresAt(v:Null<Float>):Null<Float> {
		this.exp = v;
		return v;
	}

	@:noCompletion private inline function get_notBeforeTime():Null<Float> {
		return seconds(this.nbf);
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
	 * Seconds since the epoch from a claim as JSON gives it -- an `Int` or a
	 * `Float` depending on the target and the size of the number -- or `null`
	 * when it is absent or not a finite number.
	 */
	@:noCompletion public static function seconds(value:Dynamic):Null<Float> {
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
	 * claims keep their types, except the times, which accept an `Int` or a
	 * `Float` and are checked when the token is made.
	 */
	@:from public static inline function ofClaims<T:JWTPayloadData>(claims:T):JWTPayload {
		return new JWTPayload(claims);
	}

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

	/** Issued-at, in seconds since the epoch: an `Int` or a `Float`. */
	@:optional var iat:Dynamic;

	/**
	 * Expiry, in seconds since the epoch: an `Int` or a `Float`. `JWT.verify`
	 * refuses a token without one.
	 */
	var exp:Dynamic;

	/** Not-before, in seconds since the epoch: an `Int` or a `Float`. */
	@:optional var nbf:Dynamic;

	@:optional var iss:String;
	@:optional var aud:Dynamic;
	@:optional var jti:String;
}
