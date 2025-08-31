package crossbyte.auth;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * OAuth configuration class.
 */
class OAuthConfig {
	public var clientId:String;
	public var clientSecret:String;
	public var authorizeUrl:String;
	public var tokenUrl:String;
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
