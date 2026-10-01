package crossbyte.auth;

/**
 * What a token endpoint answered: the access token, and what came with it.
 */
class OAuthToken {
	/** The access token, to send to the resource server. */
	public var accessToken:String;

	/** The refresh token, for `OAuth.refreshAccessToken`; `null` when none was issued. */
	public var refreshToken:Null<String>;

	/** Seconds the access token is good for, as the provider said; 0 when it did not. */
	public var expiresIn:Int;

	/** The token type, usually `Bearer`. */
	public var tokenType:String;

	/** The scope granted, when the provider said; it may differ from what was asked. */
	public var scope:Null<String>;

	/**
	 * The OpenID Connect ID token, a JWT naming who signed in, when the
	 * request's scope included `openid`; `null` otherwise. Verify it with
	 * `JWT` before trusting it.
	 */
	public var idToken:Null<String>;

	/**
	 * Constructs a new OAuthToken instance.
	 *
	 * @param accessToken The access token.
	 * @param refreshToken The refresh token.
	 * @param expiresIn The token expiration time in seconds.
	 * @param tokenType The type of the token.
	 * @param scope The scope of the token.
	 * @param idToken The OpenID Connect ID token, if one came with it.
	 */
	public function new(accessToken:String, refreshToken:Null<String>, expiresIn:Int, tokenType:String, scope:Null<String>, ?idToken:String) {
		this.accessToken = accessToken;
		this.refreshToken = refreshToken;
		this.expiresIn = expiresIn;
		this.tokenType = tokenType;
		this.scope = scope;
		this.idToken = idToken;
	}
}
