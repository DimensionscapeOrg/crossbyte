package crossbyte.auth.jwt;

/**
 * A token's audience (`aud`): the one service it is for, or an array of
 * them, as RFC 7519 lets an issuer write it.
 *
 * Set it from either shape; ask it with `contains`, or read every audience
 * with `toArray`, rather than testing which shape a token carried:
 *
 * ```haxe
 * var claims:JWTPayload = {sub: "user-1", exp: now + 600, aud: ["api", "billing"]};
 * claims.audience.contains("billing"); // true
 * ```
 *
 * It was `Dynamic`, so reading it needed a check of its type at every use,
 * and a `String` taken from an array-valued claim failed only at run time.
 */
abstract JWTAudience(Dynamic) from String from Array<String> to Dynamic {
	/**
	 * Whether this names `audience`: is it, or, as an array, holds it. False
	 * when there is no audience, and for a `null` one asked about. An entry
	 * of an array that is not a string, a token's, which can hold any JSON,
	 * matches nothing.
	 */
	public function contains(audience:String):Bool {
		var value:Dynamic = this;
		if (value == null || audience == null) {
			return false;
		}
		if (Std.isOfType(value, String)) {
			return (value : String) == audience;
		}
		if (Std.isOfType(value, Array)) {
			var entries:Array<Dynamic> = value;
			for (entry in entries) {
				if (Std.isOfType(entry, String) && (entry : String) == audience) {
					return true;
				}
			}
		}
		return false;
	}

	/**
	 * Every audience this names, as a new array: one entry for a single
	 * audience, none when there is none. Entries of an array that are not
	 * strings are left out.
	 */
	public function toArray():Array<String> {
		var value:Dynamic = this;
		var out:Array<String> = [];
		if (value == null) {
			return out;
		}
		if (Std.isOfType(value, String)) {
			out.push(value);
		} else if (Std.isOfType(value, Array)) {
			var entries:Array<Dynamic> = value;
			for (entry in entries) {
				if (Std.isOfType(entry, String)) {
					out.push(entry);
				}
			}
		}
		return out;
	}
}
