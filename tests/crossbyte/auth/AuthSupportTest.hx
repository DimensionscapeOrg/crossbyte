package crossbyte.auth;

import utest.Assert;

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

	public function testSecretTypedefSupportsOptionalKey():Void {
		var keyed:Secret = {key: "kid-1", secret: "secret-a"};
		var plain:Secret = {secret: "secret-b"};

		Assert.equals("kid-1", keyed.key);
		Assert.equals("secret-a", keyed.secret);
		Assert.isNull(plain.key);
		Assert.equals("secret-b", plain.secret);
	}
}
