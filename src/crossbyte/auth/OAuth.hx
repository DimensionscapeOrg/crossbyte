package crossbyte.auth;

import haxe.Http;
import haxe.Json;
using StringTools;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * OAuth utility class.
 */
class OAuth {
	private var config:OAuthConfig;

	/**
	 * Constructs a new OAuth instance with the given configuration.
	 *
	 * @param config The OAuth configuration.
	 */
	public function new(config:OAuthConfig) {
		this.config = config;
	}

	/**
	 * Generates the authorization URL for the OAuth flow.
	 *
	 * @param state A unique state parameter to prevent CSRF attacks.
	 * @param scope The scope of the requested permissions.
	 * @return The authorization URL.
	 */
	public function getAuthorizationUrl(state:String, scope:String):String {
		return config.authorizeUrl
			+ "?response_type=code"
			+ "&client_id=" + __encode(config.clientId)
			+ "&redirect_uri=" + __encode(config.redirectUri)
			+ "&state=" + __encode(state)
			+ "&scope=" + __encode(scope);
	}

	/**
	 * Exchanges the authorization code for an access token.
	 *
	 * @param code The authorization code received from the OAuth provider.
	 * @param callback The callback to handle the response.
	 */
	public function getAccessToken(code:String, callback:(OAuthToken) -> Void):Void {
		var params = [
			'grant_type=' + __encode('authorization_code'),
			'code=' + __encode(code),
			'redirect_uri=' + __encode(config.redirectUri),
			'client_id=' + __encode(config.clientId),
			'client_secret=' + __encode(config.clientSecret)
		];

		var url = config.tokenUrl;
		var http = new Http(url);
		http.setPostData(params.join('&'));
		http.setHeader('Content-Type', 'application/x-www-form-urlencoded');
		http.onData = function(response) {
			var data = Json.parse(response);
			var token = new OAuthToken(data.access_token, data.refresh_token, data.expires_in, data.token_type, data.scope);
			callback(token);
		};
		http.onError = function(error) {
			trace('Error getting access token: ' + error);
		};
		http.request(true);
	}

	/**
	 * Refreshes the access token using the refresh token.
	 *
	 * @param refreshToken The refresh token.
	 * @param callback The callback to handle the response.
	 */
	public function refreshAccessToken(refreshToken:String, callback:(OAuthToken) -> Void):Void {
		var params = [
			'grant_type=' + __encode('refresh_token'),
			'refresh_token=' + __encode(refreshToken),
			'client_id=' + __encode(config.clientId),
			'client_secret=' + __encode(config.clientSecret)
		];

		var url = config.tokenUrl;
		var http = new Http(url);
		http.setPostData(params.join('&'));
		http.setHeader('Content-Type', 'application/x-www-form-urlencoded');
		http.onData = function(response) {
			var data = Json.parse(response);
			var token = new OAuthToken(data.access_token, data.refresh_token, data.expires_in, data.token_type, data.scope);
			callback(token);
		};
		http.onError = function(error) {
			trace('Error refreshing access token: ' + error);
		};
		http.request(true);
	}

	@:noCompletion private static inline function __encode(value:String):String {
		return (value == null ? "" : StringTools.urlEncode(value));
	}
}
