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
