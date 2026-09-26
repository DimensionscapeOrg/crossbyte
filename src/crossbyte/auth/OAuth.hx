package crossbyte.auth;

import crossbyte.crypto.SecureRandom;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;
import crossbyte.url.URLRequestHeader;
import crossbyte.url.URLRequestMethod;
import crossbyte.utils.IntParse;
import crossbyte.utils.Logger;
import haxe.Json;
import haxe.crypto.Base64;
import haxe.crypto.Sha256;
import haxe.io.Bytes;

using StringTools;

/**
 * OAuth 2.0 authorization-code flow: the URL to send a user to, and the token
 * exchange when they come back.
 *
 * The exchange goes through `URLLoader`, CrossByte's own HTTP client, which
 * runs it off the runtime's thread on native targets and asynchronously on
 * Node, and delivers the result on the calling runtime's thread. It used the
 * blocking `haxe.Http` there, so a token endpoint taking 1.5 s stalled every
 * connection the server had for 1.5 s per sign-in; and on Node an endpoint
 * that never answered left both callbacks waiting forever. Every exchange now
 * has a deadline, `timeout`.
 *
 * Use PKCE (RFC 7636): it keeps an intercepted authorization code from being
 * exchanged by anyone else, and a client with no secret, a mobile or
 * single-page app's backend, needs it:
 *
 * ```haxe
 * var verifier = OAuth.createCodeVerifier();   // keep it with the session
 * redirect(oauth.getAuthorizationUrl(state, "openid email", OAuth.codeChallenge(verifier)));
 * // ...and when the provider redirects back:
 * oauth.getAccessToken(code, token -> signIn(token), error -> refuse(error), verifier);
 * ```
 */
class OAuth {
	/**
	 * Seconds the token endpoint has to answer an exchange or refresh before it
	 * fails with an error. 30 by default.
	 */
	public var timeout:Float = 30;

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
	 * A new PKCE code verifier: 32 random bytes as base64url, 43 characters.
	 *
	 * Keep it with the user's session until the provider redirects back, and
	 * pass it to `getAccessToken`. Send only `codeChallenge(verifier)` in the
	 * authorization URL.
	 */
	public static function createCodeVerifier():String {
		return __base64Url(SecureRandom.getSecureRandomBytes(32));
	}

	/**
	 * The S256 code challenge for `verifier`: base64url of its SHA-256, as RFC
	 * 7636 section 4.2 defines it.
	 */
	public static function codeChallenge(verifier:String):String {
		return __base64Url(Sha256.make(Bytes.ofString(verifier)));
	}

	/**
	 * Generates the authorization URL for the OAuth flow.
	 *
	 * @param state A unique state parameter to prevent CSRF attacks.
	 * @param scope The scope of the requested permissions.
	 * @param codeChallenge The PKCE challenge, `codeChallenge(verifier)`, which
	 *        is sent with `code_challenge_method=S256`. Omit it to leave PKCE out.
	 * @return The authorization URL.
	 */
	public function getAuthorizationUrl(state:String, scope:String, ?codeChallenge:String):String {
		var url:String = config.authorizeUrl
			+ "?response_type=code"
			+ "&client_id=" + __encode(config.clientId)
			+ "&redirect_uri=" + __encode(config.redirectUri)
			+ "&state=" + __encode(state)
			+ "&scope=" + __encode(scope);

		if (codeChallenge != null && codeChallenge != "") {
			url += "&code_challenge=" + __encode(codeChallenge) + "&code_challenge_method=S256";
		}
		return url;
	}

	/**
	 * Exchanges the authorization code for an access token.
	 *
	 * On native targets and Node this returns at once, and the callbacks run on
	 * the calling runtime's thread when the endpoint answers or `timeout`
	 * seconds pass; on the jvm and the interpreter, where `URLLoader` runs its
	 * request inline, it returns once the endpoint has answered. Needs a
	 * CrossByte runtime on the calling thread.
	 *
	 * `callback` fires only on success. Supply `onError` to be told about a
	 * failure: without one, a rejected grant is logged and nothing else happens,
	 * which from the caller's side is indistinguishable from a request still in
	 * flight.
	 *
	 * @param code The authorization code received from the OAuth provider.
	 * @param callback The callback to handle a successful exchange.
	 * @param onError Called with a description when the exchange fails.
	 * @param codeVerifier The PKCE verifier whose challenge went in the
	 *        authorization URL.
	 */
	public function getAccessToken(code:String, callback:(OAuthToken) -> Void, ?onError:(String) -> Void, ?codeVerifier:String):Void {
		var params:Array<String> = [
			"grant_type=" + __encode("authorization_code"),
			"code=" + __encode(code),
			"redirect_uri=" + __encode(config.redirectUri),
			"client_id=" + __encode(config.clientId)
		];
		__addClientSecret(params);
		if (codeVerifier != null && codeVerifier != "") {
			params.push("code_verifier=" + __encode(codeVerifier));
		}
		__requestToken("OAuth access token request", params, callback, onError);
	}

	/**
	 * Refreshes the access token using the refresh token.
	 *
	 * As with `getAccessToken`, supply `onError` to be told about a failure. An
	 * expired or revoked refresh token is the one that matters, since it is the
	 * point at which the user has to sign in again, and silently doing nothing
	 * there presents as a session that simply stops working.
	 *
	 * @param refreshToken The refresh token.
	 * @param callback The callback to handle a successful refresh.
	 * @param onError Called with a description when the refresh fails.
	 */
	public function refreshAccessToken(refreshToken:String, callback:(OAuthToken) -> Void, ?onError:(String) -> Void):Void {
		var params:Array<String> = [
			"grant_type=" + __encode("refresh_token"),
			"refresh_token=" + __encode(refreshToken),
			"client_id=" + __encode(config.clientId)
		];
		__addClientSecret(params);
		__requestToken("OAuth token refresh", params, callback, onError);
	}

	/**
	 * A public client, one using PKCE with no secret, sends none. An empty
	 * `client_secret` is refused as a wrong one by some providers.
	 */
	@:noCompletion private function __addClientSecret(params:Array<String>):Void {
		if (config.clientSecret != null && config.clientSecret != "") {
			params.push("client_secret=" + __encode(config.clientSecret));
		}
	}

	@:noCompletion private function __requestToken(operation:String, params:Array<String>, callback:(OAuthToken) -> Void,
			onError:Null<(String) -> Void>):Void {
		var request:URLRequest = new URLRequest(config.tokenUrl);
		request.method = URLRequestMethod.POST;
		request.contentType = "application/x-www-form-urlencoded";
		request.data = params.join("&");
		request.requestHeaders.push(new URLRequestHeader("Accept", "application/json"));
		// The client's own idle limit as a backstop; the deadline below is what
		// bounds the whole exchange, drip-fed answers included.
		request.idleTimeout = Std.int(Math.max(1, timeout) * 1000);

		var loader:URLLoader = new URLLoader();
		var settled:Bool = false;
		var deadline:Int = -1;

		// Exactly one of the outcomes below reports, whichever comes first.
		function settle():Bool {
			if (settled) {
				return false;
			}
			settled = true;
			if (deadline >= 0) {
				crossbyte.Timer.clear(deadline);
			}
			return true;
		}

		// Node's client completes a load whatever the status, where the native
		// one reports 4xx and 5xx as errors; this makes both mean failure.
		var status:Int = 0;
		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, (event:HTTPStatusEvent) -> status = event.status);

		loader.addEventListener(Event.COMPLETE, (_:Event) -> {
			if (!settle()) {
				return;
			}
			if (status >= 400) {
				__fail(operation, __errorBody(__text(loader.data), "HTTP error " + status), onError);
			} else {
				__handleTokenResponse(operation, __text(loader.data), callback, onError);
			}
		});

		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> {
			if (settle()) {
				// A rejected grant is usually a 400 carrying the provider's error
				// document, the reason worth passing on; the client keeps the body
				// of an error response in `data`. A failing status is a failure
				// whatever the body holds.
				__fail(operation, __errorBody(__text(loader.data), event.text), onError);
			}
		});

		// Armed before the load: where the loader runs inline, the answer has
		// settled, and cleared this, by the time load returns.
		deadline = crossbyte.Timer.setTimeout(timeout, () -> {
			if (!settle()) {
				return;
			}
			// Cancelled, so a native worker blocked on the socket unwinds rather
			// than waiting out its own idle limit. Through the token, not
			// `loader.close()`: close drops the loader's worker while the request
			// is still running, and the worker then reports through a null
			// reference, an access violation on native. The token closes the
			// socket, and the loader winds down on its own, unheard.
			#if js
			loader.close();
			#else
			if (loader.cancelToken != null) {
				loader.cancelToken.cancel();
			}
			#end
			__fail(operation, "the token endpoint did not answer within " + timeout + " s", onError);
		});

		loader.load(request);
	}

	/**
	 * The provider's reason from the body of a failing response, its `error`
	 * and `error_description`, or what the client reported when it gave none.
	 */
	@:noCompletion private static function __errorBody(body:Null<String>, transportError:String):String {
		if (body == null || body.trim() == "") {
			return transportError;
		}

		try {
			var data:Dynamic = Json.parse(body);
			if (data != null && Reflect.field(data, "error") != null) {
				return __describeFailure(data);
			}
		} catch (_:Dynamic) {}
		return transportError;
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

	/**
	 * `expires_in` as seconds, or 0 when absent or unusable. Some providers send
	 * it as a string; either form is read with `IntParse`, so a value too large
	 * for an `Int` is 0 on every target rather than whatever `Std.parseInt`
	 * made of it on that one.
	 */
	@:noCompletion private static function __toInt(value:Dynamic):Int {
		if (value == null) {
			return 0;
		}

		if (Std.isOfType(value, Int)) {
			var seconds:Int = value;
			return seconds < 0 ? 0 : seconds;
		}

		var text:String = Std.string(value);
		if (Std.isOfType(value, Float)) {
			var number:Float = value;
			if (!Math.isFinite(number) || number != Math.ffloor(number) || number < 0 || number > 2147483647.0) {
				return 0;
			}
			return Std.int(number);
		}

		var parsed:Int = IntParse.decimal(text.trim());
		return parsed < 0 ? 0 : parsed;
	}

	@:noCompletion private static function __text(data:Dynamic):Null<String> {
		if (data == null) {
			return null;
		}
		if (Std.isOfType(data, Bytes)) {
			return (data : Bytes).toString();
		}
		return Std.string(data);
	}

	@:noCompletion private static function __base64Url(bytes:Bytes):String {
		var text:String = Base64.encode(bytes, false);
		return text.replace("+", "-").replace("/", "_");
	}

	@:noCompletion private static inline function __encode(value:String):String {
		return (value == null ? "" : StringTools.urlEncode(value));
	}
}
