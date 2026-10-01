package crossbyte.auth;

import utest.Assert;
import crossbyte.test.Require;

class AuthSupportTest extends utest.Test {
	public function testOAuthConfigStoresConstructorValues():Void {
		var config = new OAuthConfig(
			"client-id",
			"client-secret",
			"https://auth.example/authorize",
			"https://auth.example/token",
			"https://app.example/callback"
		);

		Assert.equals("client-id", config.clientId);
		Assert.equals("client-secret", config.clientSecret);
		Assert.equals("https://auth.example/authorize", config.authorizeUrl);
		Assert.equals("https://auth.example/token", config.tokenUrl);
		Assert.equals("https://app.example/callback", config.redirectUri);
	}

	public function testOAuthTokenStoresPayloadFields():Void {
		var token = new OAuthToken("access-token", "refresh-token", 3600, "Bearer", "profile email");

		Assert.equals("access-token", token.accessToken);
		Assert.equals("refresh-token", token.refreshToken);
		Assert.equals(3600, token.expiresIn);
		Assert.equals("Bearer", token.tokenType);
		Assert.equals("profile email", token.scope);
	}

	public function testOAuthAuthorizationUrlEncodesSensitiveParameters():Void {
		var oauth = new OAuth(new OAuthConfig(
			"client id",
			"client/secret?",
			"https://auth.example/authorize",
			"https://auth.example/token",
			"https://app.example/callback?x=1&y=two words"
		));

		var url = oauth.getAuthorizationUrl("a state/with spaces", "profile email+write");

		Assert.equals(
			"https://auth.example/authorize"
				+ "?response_type=code"
				+ "&client_id=client%20id"
				+ "&redirect_uri=https%3A%2F%2Fapp.example%2Fcallback%3Fx%3D1%26y%3Dtwo%20words"
				+ "&state=a%20state%2Fwith%20spaces"
				+ "&scope=profile%20email%2Bwrite",
			url
		);
	}

	public function testOAuthAuthorizationUrlTreatsNullStateAndScopeAsEmpty():Void {
		var oauth = new OAuth(new OAuthConfig(
			"client",
			"secret",
			"https://auth.example/authorize",
			"https://auth.example/token",
			"https://app.example/callback"
		));

		var url = oauth.getAuthorizationUrl(null, null);

		Assert.equals(
			"https://auth.example/authorize"
				+ "?response_type=code"
				+ "&client_id=client"
				+ "&redirect_uri=https%3A%2F%2Fapp.example%2Fcallback"
				+ "&state="
				+ "&scope=",
			url
		);
	}

	/**
		An authorization endpoint that carries a query of its own keeps it.

		The flow's parameters were added after a second `?`, so a parameter
		that never changes put in the endpoint, Google's
		`access_type=offline`, without which no refresh token is issued,
		took the rest of the URL as its value.
	**/
	public function testAnAuthorizeUrlWithAQueryKeepsIt():Void {
		var oauth = new OAuth(new OAuthConfig("client", "secret", "https://auth.example/authorize?access_type=offline", "https://auth.example/token",
			"https://app.example/callback"));

		Assert.equals("https://auth.example/authorize?access_type=offline"
			+ "&response_type=code"
			+ "&client_id=client"
			+ "&redirect_uri=https%3A%2F%2Fapp.example%2Fcallback"
			+ "&state=s"
			+ "&scope=openid", oauth.getAuthorizationUrl("s", "openid"));
	}

	/**
		Parameters that change per request, OpenID Connect's `nonce`,
		`prompt`, `login_hint`, go in the URL encoded like the rest. There
		was nowhere to put them: a nonce, which has to be new for each
		sign-in, cannot live in the configuration.
	**/
	public function testFurtherAuthorizationParametersAreEncodedIn():Void {
		var oauth = new OAuth(new OAuthConfig("client", "secret", "https://auth.example/authorize", "https://auth.example/token",
			"https://app.example/callback"));

		var url:String = oauth.getAuthorizationUrl("s", "openid", "challenge", ["nonce" => "n 1/2", "prompt" => "consent"]);

		Assert.isTrue(StringTools.startsWith(url, "https://auth.example/authorize?response_type=code&"), url);
		Assert.isTrue(url.indexOf("&code_challenge=challenge&code_challenge_method=S256") > 0, url);
		Assert.isTrue(url.indexOf("&nonce=n%201%2F2") > 0, url);
		Assert.isTrue(url.indexOf("&prompt=consent") > 0, url);
	}

	public function testSecretTypedefSupportsOptionalKey():Void {
		var keyed:Secret = {key: "kid-1", secret: "secret-a"};
		var plain:Secret = {secret: "secret-b"};

		Assert.equals("kid-1", keyed.key);
		Assert.equals("secret-a", keyed.secret);
		Assert.isNull(plain.key);
		Assert.equals("secret-b", plain.secret);
	}

	public function testTokenResponseDeliversATokenAndCoercesExpiresIn():Void {
		var delivered:OAuthToken = null;
		var failure:String = null;

		OAuth.__handleTokenResponse("exchange", '{"access_token":"at","refresh_token":"rt","expires_in":"3600","token_type":"Bearer","scope":"profile"}',
			token -> delivered = token, message -> failure = message);

		Assert.isNull(failure);
		Require.notNull(delivered);
		Assert.equals("at", delivered.accessToken);
		Assert.equals("rt", delivered.refreshToken);
		Assert.equals("Bearer", delivered.tokenType);
		Assert.equals("profile", delivered.scope);
		// Sent as a string by some providers; handed straight to an Int field it
		// is a broken token on every static target.
		Assert.equals(3600, delivered.expiresIn);
		Assert.isNull(delivered.idToken);
	}

	/**
		An OpenID Connect sign-in hands back its ID token.

		The class's own example asks for `openid email` and signs the user in
		with what comes back, and the `id_token`, the one thing in the
		response that says who signed in, was dropped.
	**/
	public function testAnOpenIdConnectSignInKeepsItsIdToken():Void {
		var delivered:OAuthToken = null;

		OAuth.__handleTokenResponse("exchange", '{"access_token":"at","token_type":"Bearer","expires_in":3600,"id_token":"h.p.s"}',
			token -> delivered = token, null);

		Require.notNull(delivered);
		Assert.equals("h.p.s", delivered.idToken);
	}

	public function testRejectedGrantReachesTheErrorCallback():Void {
		var delivered:OAuthToken = null;
		var failure:String = null;

		// A 200 carrying an error document, which is how a rejected grant often
		// arrives. This used to be delivered as success with a null accessToken.
		OAuth.__handleTokenResponse("exchange", '{"error":"invalid_grant","error_description":"authorization code has expired"}',
			token -> delivered = token, message -> failure = message);

		Assert.isNull(delivered);
		Require.notNull(failure);
		// The provider's own reason, not just "it failed".
		Assert.isTrue(failure.indexOf("invalid_grant") >= 0);
		Assert.isTrue(failure.indexOf("authorization code has expired") >= 0);
		Assert.isTrue(failure.indexOf("exchange") >= 0);
	}

	public function testResponseWithoutAnAccessTokenIsAFailure():Void {
		var delivered:OAuthToken = null;
		var failure:String = null;

		OAuth.__handleTokenResponse("exchange", '{"token_type":"Bearer"}', token -> delivered = token, message -> failure = message);

		Assert.isNull(delivered);
		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("no access_token") >= 0);
	}

	public function testMalformedResponseIsAFailureRatherThanAThrow():Void {
		var delivered:OAuthToken = null;
		var failure:String = null;

		OAuth.__handleTokenResponse("exchange", "<html>502 Bad Gateway</html>", token -> delivered = token, message -> failure = message);

		Assert.isNull(delivered);
		Require.notNull(failure);
		Assert.isTrue(failure.indexOf("malformed response") >= 0);
	}

	public function testCallbackFailureIsNotReportedAsAMalformedResponse():Void {
		var failure:String = null;
		var threw:Bool = false;

		try {
			OAuth.__handleTokenResponse("exchange", '{"access_token":"at"}', _ -> throw "caller blew up", message -> failure = message);
		} catch (_:Dynamic) {
			threw = true;
		}

		// The caller's own exception propagates untouched. Catching it inside the
		// parse guard would blame the provider for the application's bug.
		Assert.isTrue(threw);
		Assert.isNull(failure);
	}

	public function testFailureWithoutAnErrorCallbackDoesNotThrow():Void {
		var delivered:OAuthToken = null;

		// The pre-existing shape: no handler, so the failure is logged. It must
		// stay non-fatal, since that is what every current caller relies on.
		OAuth.__handleTokenResponse("exchange", '{"error":"invalid_client"}', token -> delivered = token, null);

		Assert.isNull(delivered);
		Assert.pass();
	}
}
