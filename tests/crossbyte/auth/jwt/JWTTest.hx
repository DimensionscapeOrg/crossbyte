package crossbyte.auth.jwt;

import utest.Assert;

class JWTTest extends utest.Test {
	public function testNullTimestampPayloadIsRejected():Void {
		var jwt = JWT.make(HS256([{secret: "test-secret"}]));
		var token = jwt.generateToken({
			sub: "subject",
			iat: null,
			exp: null
		});

		Assert.isNull(jwt.verifyToken(token));
	}

	public function testNullablePayloadTimestampsRoundTrip():Void {
		var payload:JWTPayload = {
			sub: "subject",
			iat: null,
			exp: null
		};

		Assert.isNull(payload.issuedAt);
		Assert.isNull(payload.expiresAt);
	}
}
