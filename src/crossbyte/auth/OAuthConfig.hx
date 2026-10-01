package crossbyte.auth;

/**
 * OAuth configuration class.
 */
class OAuthConfig {
	/** The client id the provider issued. */
	public var clientId:String;

	/** The client secret, or `null` for a public client using PKCE, which sends none. */
	public var clientSecret:String;

	/**
	 * The provider's authorization endpoint. It may carry a query of its own,
	 * for parameters that never change; `OAuth.getAuthorizationUrl` adds the
	 * flow's after it.
	 */
	public var authorizeUrl:String;

	/** The provider's token endpoint. */
	public var tokenUrl:String;

	/** Where the provider sends the user back, exactly as registered with it. */
	public var redirectUri:String;

	/**
	 * Where the client secret goes in a token request: the body
	 * (`SECRET_POST`, the default) or an HTTP Basic header (`SECRET_BASIC`).
	 * Set it to what the provider was configured for; one configured for
	 * Basic alone refuses the body as `invalid_client`.
	 */
	public var clientAuthentication:OAuthClientAuthentication = SECRET_POST;

	/**
	 * Constructs a new OAuthConfig instance.
	 *
	 * @param clientId The client ID.
	 * @param clientSecret The client secret.
	 * @param authorizeUrl The authorization URL.
	 * @param tokenUrl The token URL.
	 * @param redirectUri The redirect URI.
	 */
	public function new(clientId:String, clientSecret:String, authorizeUrl:String, tokenUrl:String, redirectUri:String) {
		this.clientId = clientId;
		this.clientSecret = clientSecret;
		this.authorizeUrl = authorizeUrl;
		this.tokenUrl = tokenUrl;
		this.redirectUri = redirectUri;
	}
}
