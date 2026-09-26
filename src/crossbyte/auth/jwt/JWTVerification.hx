package crossbyte.auth.jwt;

/**
 * What `JWT.verify` found: the claims of a token that passed every check, or
 * the first check it failed.
 *
 * ```haxe
 * var result = jwt.verify(token);
 * if (!result.valid) {
 *     log.info('refused a token: ${result.rejection}');
 *     return respond(401);
 * }
 * var claims:JWTPayload = result.payload;
 * ```
 */
class JWTVerification {
	/** The token's claims when it was accepted; otherwise `null`. */
	public final payload:Null<JWTPayload>;

	/** Why it was refused; `null` when it was accepted. */
	public final rejection:Null<JWTRejection>;

	/** Whether the token was accepted. */
	public var valid(get, never):Bool;

	@:noCompletion private function new(payload:Null<JWTPayload>, rejection:Null<JWTRejection>) {
		this.payload = payload;
		this.rejection = rejection;
	}

	@:noCompletion private inline function get_valid():Bool {
		return rejection == null;
	}

	@:noCompletion @:allow(crossbyte.auth.jwt.JWT)
	private static inline function accepted(payload:JWTPayload):JWTVerification {
		return new JWTVerification(payload, null);
	}

	@:noCompletion @:allow(crossbyte.auth.jwt.JWT)
	private static inline function refused(rejection:JWTRejection):JWTVerification {
		return new JWTVerification(null, rejection);
	}

	public function toString():String {
		return valid ? "JWTVerification(accepted)" : 'JWTVerification(refused: $rejection)';
	}
}
