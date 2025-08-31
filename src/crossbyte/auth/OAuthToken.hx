package crossbyte.auth;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * OAuth token class.
 */
class OAuthToken {
	public var accessToken:String;
	public var refreshToken:Null<String>;
	public var expiresIn:Int;
	public var tokenType:String;
	public var scope:Null<String>;

	/**
	 * Constructs a new OAuthToken instance.
	 *
	 * @param accessToken The access token.
	 * @param refreshToken The refresh token.
	 * @param expiresIn The token expiration time in seconds.
	 * @param tokenType The type of the token.
	 * @param scope The scope of the token.
	 */
	public function new(accessToken:String, refreshToken:Null<String>, expiresIn:Int, tokenType:String, scope:Null<String>) {
		this.accessToken = accessToken;
		this.refreshToken = refreshToken;
		this.expiresIn = expiresIn;
		this.tokenType = tokenType;
		this.scope = scope;
	}
}
