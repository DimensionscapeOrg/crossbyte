package crossbyte.auth;

#if !(java || jvm)
// haxe.Http reaches HTTPS through sys.ssl.Socket, which does not compile on the
// jvm target. There, CrossByte's own client is used instead: it goes through
// FlexSocket, which now terminates TLS on jvm as well. The other targets are
// left on haxe.Http rather than moved wholesale, since nothing here covers a
// live token exchange and changing four working targets to fix one is a poor
// trade.
import haxe.Http;
#end
import haxe.Json;
import crossbyte.utils.Logger;

using StringTools;

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
	 * `callback` fires only on success. Supply `onError` to be told about a
	 * failure: without one, a rejected grant is logged and nothing else happens,
	 * which from the caller's side is indistinguishable from a request still in
	 * flight.
	 *
	 * @param code The authorization code received from the OAuth provider.
	 * @param callback The callback to handle a successful exchange.
	 * @param onError Called with a description when the exchange fails.
	 */
	public function getAccessToken(code:String, callback:(OAuthToken) -> Void, ?onError:(String) -> Void):Void {
		__requestToken("OAuth access token request", [
			"grant_type=" + __encode("authorization_code"),
			"code=" + __encode(code),
			"redirect_uri=" + __encode(config.redirectUri),
			"client_id=" + __encode(config.clientId),
			"client_secret=" + __encode(config.clientSecret)
		], callback, onError);
	}

	/**
	 * Refreshes the access token using the refresh token.
	 *
	 * As with `getAccessToken`, supply `onError` to be told about a failure. An
	 * expired or revoked refresh token is the one that matters, since it is the
	 * point at which the user has to sign in again — and silently doing nothing
	 * there presents as a session that simply stops working.
	 *
	 * @param refreshToken The refresh token.
	 * @param callback The callback to handle a successful refresh.
	 * @param onError Called with a description when the refresh fails.
	 */
	public function refreshAccessToken(refreshToken:String, callback:(OAuthToken) -> Void, ?onError:(String) -> Void):Void {
		__requestToken("OAuth token refresh", [
			"grant_type=" + __encode("refresh_token"),
			"refresh_token=" + __encode(refreshToken),
			"client_id=" + __encode(config.clientId),
			"client_secret=" + __encode(config.clientSecret)
		], callback, onError);
	}

	@:noCompletion private function __requestToken(operation:String, params:Array<String>, callback:(OAuthToken) -> Void,
			onError:Null<(String) -> Void>):Void {
		#if (java || jvm)
		// CrossByte's own client, which reaches HTTPS through FlexSocket.
		var http = new crossbyte._internal.http.Http(config.tokenUrl, "POST", null, params.join("&"),
			"application/x-www-form-urlencoded");

		http.onComplete = function(data:haxe.io.Bytes):Void {
			__handleTokenResponse(operation, data.toString(), callback, onError);
		};

		http.onError = function(message:String, ?data:haxe.io.Bytes):Void {
			__fail(operation, message, onError);
		};

		http.load();
		#else
		var http = new Http(config.tokenUrl);
		http.setPostData(params.join("&"));
		http.setHeader("Content-Type", "application/x-www-form-urlencoded");

		http.onData = function(response:String):Void {
			__handleTokenResponse(operation, response, callback, onError);
		};

		http.onError = function(error:Dynamic):Void {
			__fail(operation, Std.string(error), onError);
		};

		http.request(true);
		#end
	}

	/**
	 * Turns a token endpoint's response body into either a token or a failure.
	 *
	 * Public and `@:noCompletion` so this decision can be exercised without a
	 * network round trip; it is not part of the supported surface.
	 */
	@:noCompletion public static function __handleTokenResponse(operation:String, response:String, callback:(OAuthToken) -> Void,
			onError:Null<(String) -> Void>):Void {
		var token:OAuthToken;

		try {
			var data:Dynamic = Json.parse(response);
			var accessToken:Dynamic = Reflect.field(data, "access_token");

			if (accessToken == null || Std.string(accessToken) == "") {
				// Providers answer a rejected grant with an error document, and
				// not always with a failing status. Passing that through as a
				// success handed back a token whose accessToken was null, which
				// then failed later somewhere with nothing to connect it to.
				__fail(operation, __describeFailure(data), onError);
				return;
			}

			token = new OAuthToken(Std.string(accessToken), __optionalString(data, "refresh_token"), __toInt(Reflect.field(data, "expires_in")),
				__optionalString(data, "token_type"), __optionalString(data, "scope"));
		} catch (e:Dynamic) {
			__fail(operation, "malformed response: " + Std.string(e), onError);
			return;
		}

		// Outside the try on purpose: an exception thrown by the caller's own
		// callback is not a malformed response and must not be reported as one.
		callback(token);
	}

	@:noCompletion private static function __fail(operation:String, detail:String, onError:Null<(String) -> Void>):Void {
		var message:String = operation + " failed: " + detail;

		if (onError != null) {
			onError(message);
			return;
		}

		// No handler supplied: the failure still has to go somewhere, or this is
		// exactly the silent case the parameter exists to end.
		Logger.error(message);
	}

	@:noCompletion private static function __describeFailure(data:Dynamic):String {
		var error:Dynamic = Reflect.field(data, "error");

		if (error == null) {
			return "response contained no access_token";
		}

		// The provider's own reason, which is the difference between "it failed"
		// and "invalid_grant: authorization code has expired".
		var description:Dynamic = Reflect.field(data, "error_description");
		return description == null ? Std.string(error) : Std.string(error) + ": " + Std.string(description);
	}

	@:noCompletion private static function __optionalString(data:Dynamic, field:String):String {
		var value:Dynamic = Reflect.field(data, field);
		return value == null ? null : Std.string(value);
	}

	@:noCompletion private static function __toInt(value:Dynamic):Int {
		if (value == null) {
			return 0;
		}

		if (Std.isOfType(value, Int)) {
			return value;
		}

		// Some providers send expires_in as a string. Handing that straight to
		// an Int field is a broken token on every static target.
		var parsed:Null<Int> = Std.parseInt(Std.string(value));
		return parsed == null ? 0 : parsed;
	}

	@:noCompletion private static inline function __encode(value:String):String {
		return (value == null ? "" : StringTools.urlEncode(value));
	}
}
