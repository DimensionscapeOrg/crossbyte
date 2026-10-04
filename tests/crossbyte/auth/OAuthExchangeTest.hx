package crossbyte.auth;

import crossbyte.core.CrossByte;
import crossbyte.crypto.SecureRandom;
import utest.Assert;
import utest.Async;
import crossbyte.test.Require;
#if (sys && !nodejs)
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Thread;
#end

/**
 * OAuth's token exchange against a real endpoint, and PKCE.
 *
 * The exchange used the blocking `haxe.Http` on native targets, so a token
 * endpoint taking 1.5 s stalled the whole server for 1.5 s per sign-in, and on
 * Node a provider that never answered left both callbacks unfired forever.
 * There was nowhere to put a PKCE challenge or verifier.
 *
 * The endpoint is a socket served from a thread on the sys targets and Node's
 * own http server on Node; the browser has neither and runs the PKCE cases.
 */
@:access(crossbyte.core.CrossByte)
@:timeout(30000)
class OAuthExchangeTest extends utest.Test {
	static inline final TOKEN_RESPONSE:String = '{"access_token":"at-123","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-9"}';

	public function testPkceMatchesRfc7636():Void {
		// RFC 7636 appendix B.
		Assert.equals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", OAuth.codeChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));

		var oauth:OAuth = new OAuth(new OAuthConfig("client", "secret", "https://auth.example/authorize", "https://auth.example/token",
			"https://app.example/callback"));
		var url:String = oauth.getAuthorizationUrl("s", "openid", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
		Assert.isTrue(StringTools.endsWith(url, "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"), url);
		Assert.equals(-1, oauth.getAuthorizationUrl("s", "openid").indexOf("code_challenge"));

		if (!SecureRandom.isSupported) {
			return;
		}
		var verifier:String = OAuth.createCodeVerifier();
		// 43 to 128 unreserved characters, RFC 7636 4.1.
		Assert.equals(43, verifier.length);
		Assert.isTrue(~/^[A-Za-z0-9\-._~]+$/.match(verifier), verifier);
		Assert.notEquals(verifier, OAuth.createCodeVerifier());
	}

	public function testExpiresInIsReadTheSameOnEveryTarget():Void {
		for (entry in [
			{json: '"3600"', expected: 3600},
			{json: '3600', expected: 3600},
			{json: '" 60 "', expected: 60},
			// Past an Int: Std.parseInt made 0, 2147483647, a throw or a wider
			// number of this depending on the target.
			{json: '"4294967296"', expected: 0},
			{json: '4294967296', expected: 0},
			{json: '"-5"', expected: 0},
			{json: '"soon"', expected: 0},
			{json: '1.5', expected: 0}
		]) {
			var delivered:Null<OAuthToken> = null;
			OAuth.__handleTokenResponse("exchange", '{"access_token":"at","expires_in":${entry.json}}', token -> delivered = token, null);
			Require.notNull(delivered);
			Assert.equals(entry.expected, delivered.expiresIn, entry.json);
		}
	}

	/**
		A token endpoint's answer nested deeper than any real one is a failure,
		refused before it is parsed: parsing takes a frame per level, and
		natively an answer nested 6,000 deep, 12 KB, overflowed the stack
		and ended the process. So did an error document that deep, read for
		the provider's reason. The bound is 32 levels, objects and arrays
		together: here the answer's object, then a member nesting the rest.
	**/
	public function testADeeplyNestedAnswerIsRefusedBeforeItIsParsed():Void {
		function nested(levels:Int):String {
			return StringTools.lpad("", "[", levels) + StringTools.lpad("", "]", levels);
		}

		// 32 levels: a token.
		var delivered:Null<OAuthToken> = null;
		var failure:Null<String> = null;
		OAuth.__handleTokenResponse("exchange", '{"access_token":"at","authorization_details":${nested(31)}}', token -> delivered = token,
			message -> failure = message);
		Assert.isNull(failure);
		Assert.equals("at", delivered == null ? null : delivered.accessToken);
		Assert.equals("invalid_grant", @:privateAccess OAuth.__errorBody('{"error":"invalid_grant","x":${nested(31)}}', "HTTP error 400"));

		// 33 levels, which every parser here reads without trouble, and 6,000.
		for (levels in [32, 5999]) {
			delivered = null;
			failure = null;
			OAuth.__handleTokenResponse("exchange", '{"access_token":"at","authorization_details":${nested(levels)}}', token -> delivered = token,
				message -> failure = message);
			Assert.isNull(delivered, (levels + 1) + " levels delivered a token");
			Assert.isTrue(failure != null && failure.indexOf("malformed response: nested more than 32 levels deep") >= 0, (levels + 1) + " levels: " + failure);

			// The provider's reason cannot be read; the transport's is given.
			Assert.equals("HTTP error 400", @:privateAccess OAuth.__errorBody('{"error":"invalid_grant","x":${nested(levels)}}', "HTTP error 400"),
				(levels + 1) + " levels");
		}
	}

	/**
		`timeout` is a number of seconds, or `0` for no deadline: a negative
		number or `NaN` is refused where it is set, and leaves the timeout as
		it was. `NaN` was taken, and reached the client as an idle timeout of
		whatever `Std.int` made of it on the target.
	**/
	public function testATimeoutThatIsNotSecondsIsRefused():Void {
		var oauth:OAuth = new OAuth(new OAuthConfig("client", "", "https://auth.example/authorize", "https://auth.example/token",
			"https://app.example/callback"));
		Assert.equals(30.0, oauth.timeout);
		for (bad in [Math.NaN, -1.0, -0.001, Math.NEGATIVE_INFINITY]) {
			Assert.raises(() -> oauth.timeout = bad, crossbyte.errors.ArgumentError, "a timeout of " + bad + " was taken");
			Assert.equals(30.0, oauth.timeout, "a refused timeout changed it");
		}
		for (good in [0.0, 0.25, 600.0, Math.POSITIVE_INFINITY]) {
			oauth.timeout = good;
			Assert.equals(good, oauth.timeout);
		}
	}

	#if (sys || nodejs)
	/**
		A timeout of `0` is no deadline, as it is everywhere in CrossByte: the
		exchange waits for the endpoint. It was a deadline of no time at all,
		which failed every exchange at once.
	**/
	public function testATimeoutOfZeroIsNoDeadline(async:Async):Void {
		serve(0.4, 200, TOKEN_RESPONSE, endpoint -> {
			var oauth:OAuth = client(endpoint.port);
			oauth.timeout = 0;
			var delivered:Null<OAuthToken> = null;
			var failure:Null<String> = null;

			oauth.getAccessToken("code-abc", token -> delivered = token, message -> failure = message);

			pumpUntil(() -> delivered != null || failure != null, 15, _ -> {
				Assert.isNull(failure, "an exchange with no deadline failed: " + failure);
				Assert.equals("at-123", delivered == null ? null : delivered.accessToken);
				endpoint.close();
				async.done();
			});
		});
	}

	public function testTheExchangeRunsOffTheRuntimeAndSendsTheVerifier(async:Async):Void {
		serve(0.4, 200, TOKEN_RESPONSE, endpoint -> {
			var oauth:OAuth = client(endpoint.port);
			var delivered:Null<OAuthToken> = null;
			var failure:Null<String> = null;

			var t0:Float = haxe.Timer.stamp();
			oauth.getAccessToken("code-abc", token -> delivered = token, message -> failure = message, "the-verifier");
			var returnedAfter:Float = haxe.Timer.stamp() - t0;

			#if (cpp || nodejs)
			// The endpoint takes 400 ms. Returning before it answers is the
			// point: the runtime's other connections are served meanwhile.
			Assert.isTrue(returnedAfter < 0.2, 'getAccessToken held the runtime for $returnedAfter s');
			#end

			pumpUntil(() -> delivered != null || failure != null, 15, _ -> {
				Assert.isNull(failure);
				if (delivered != null) {
					Assert.equals("at-123", delivered.accessToken);
					Assert.equals("rt-9", delivered.refreshToken);
					Assert.equals(3600, delivered.expiresIn);
				}

				var body:String = endpoint.body();
				Assert.isTrue(body.indexOf("grant_type=authorization_code") >= 0, body);
				Assert.isTrue(body.indexOf("code=code-abc") >= 0, body);
				Assert.isTrue(body.indexOf("code_verifier=the-verifier") >= 0, body);
				Assert.isTrue(body.indexOf("client_secret=s3cret") >= 0, body);
				endpoint.close();
				async.done();
			});
		});
	}

	public function testAStalledEndpointFailsAtTheDeadline(async:Async):Void {
		// Takes the request and never answers.
		serve(-1, 0, null, endpoint -> {
			var oauth:OAuth = client(endpoint.port);
			oauth.timeout = 0.5;
			var delivered:Null<OAuthToken> = null;
			var failure:Null<String> = null;

			oauth.getAccessToken("code-abc", token -> delivered = token, message -> failure = message);

			pumpUntil(() -> failure != null || delivered != null, 15, finished -> {
				Assert.isTrue(finished, "the exchange ended");
				Assert.isNull(delivered);
				Require.notNull(failure);
				// The exchange runs off the runtime on every target now, so the
				// deadline is what ends it everywhere.
				Assert.isTrue(failure.indexOf("did not answer within 0.5 s") >= 0, failure);
				endpoint.close();
				async.done();
			});
		});
	}

	/**
		A provider set up for HTTP Basic client authentication gets the secret
		in an `Authorization` header and not in the body.

		The secret went in the body whatever the provider took, and RFC 6749
		has every provider accept Basic and calls the body NOT RECOMMENDED: a
		provider configured for Basic alone answered `invalid_client`, with no
		way to send anything else.
	**/
	public function testTheSecretGoesInABasicHeaderWhenTheProviderAsks(async:Async):Void {
		serve(0, 200, TOKEN_RESPONSE, endpoint -> {
			var config:OAuthConfig = new OAuthConfig("client 1", "s3cret:/", "https://provider.example/authorize",
				'http://127.0.0.1:${endpoint.port}/token', "https://app.example/callback");
			config.clientAuthentication = SECRET_BASIC;
			var oauth:OAuth = new OAuth(config);
			var delivered:Null<OAuthToken> = null;
			var failure:Null<String> = null;

			oauth.getAccessToken("code-abc", token -> delivered = token, message -> failure = message);

			pumpUntil(() -> delivered != null || failure != null, 15, _ -> {
				Assert.isNull(failure);
				Assert.notNull(delivered);
				// RFC 6749 2.3.1: each part form-encoded, then base64.
				var expected:String = "Basic " + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString("client%201:s3cret%3A%2F"));
				Assert.equals(expected, endpoint.authorization);
				Assert.equals(-1, endpoint.body().indexOf("client_secret"), endpoint.body());
				endpoint.close();
				async.done();
			});
		});
	}

	public function testARejectedGrantReportsTheProvidersReason(async:Async):Void {
		serve(0, 400, '{"error":"invalid_grant","error_description":"authorization code has expired"}', endpoint -> {
			var oauth:OAuth = client(endpoint.port);
			var delivered:Null<OAuthToken> = null;
			var failure:Null<String> = null;

			oauth.getAccessToken("code-abc", token -> delivered = token, message -> failure = message);

			pumpUntil(() -> failure != null || delivered != null, 15, _ -> {
				Assert.isNull(delivered);
				Require.notNull(failure);
				Assert.isTrue(failure.indexOf("invalid_grant: authorization code has expired") >= 0, failure);
				endpoint.close();
				async.done();
			});
		});
	}

	static function client(port:Int):OAuth {
		return new OAuth(new OAuthConfig("client-1", "s3cret", "https://provider.example/authorize", 'http://127.0.0.1:$port/token',
			"https://app.example/callback"));
	}

	/**
	 * Pumps the runtime until `done`, then calls `then`. On Node the waiting
	 * spans event loop turns, which is where Node's own sockets report.
	 */
	static function pumpUntil(done:Void->Bool, timeout:Float, then:Bool->Void):Void {
		var runtime:CrossByte = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + timeout;

		#if nodejs
		function turn():Void {
			runtime.pump(1 / 60, 0);
			if (done()) {
				then(true);
			} else if (haxe.Timer.stamp() >= deadline) {
				then(false);
			} else {
				js.Node.setTimeout(turn, 1);
			}
		}
		turn();
		#else
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
		then(done());
		#end
	}

	/**
	 * A one-request token endpoint on a free port, answering `status` and `body`
	 * after `delay` seconds, or holding the connection unanswered when `delay`
	 * is negative. Calls `ready` once it listens.
	 */
	static function serve(delay:Float, status:Int, body:Null<String>, ready:TokenEndpoint->Void):Void {
		#if nodejs
		var endpoint:TokenEndpoint = new TokenEndpoint();
		var held:Array<Dynamic> = [];
		var server:Dynamic = js.Lib.require("http").createServer(function(req:Dynamic, res:Dynamic) {
			endpoint.authorization = req.headers.authorization;
			var chunks:Array<String> = [];
			req.on("data", function(chunk:Dynamic) chunks.push(Std.string(chunk)));
			req.on("end", function() {
				endpoint.received = chunks.join("");
				if (delay < 0) {
					held.push(res);
					return;
				}
				js.Node.setTimeout(function() {
					res.writeHead(status, {"Content-Type": "application/json", "Connection": "close"});
					res.end(body);
				}, Std.int(delay * 1000));
			});
		});
		endpoint.onClose = function() {
			for (res in held) {
				res.destroy();
			}
			server.close();
		};
		server.listen(0, "127.0.0.1", function() {
			endpoint.port = server.address().port;
			ready(endpoint);
		});
		#else
		var endpoint:TokenEndpoint = new TokenEndpoint();
		var listening:Lock = new Lock();
		Thread.create(() -> {
			var server:SysSocket = new SysSocket();
			var peer:Null<SysSocket> = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				endpoint.port = server.host().port;
				listening.release();

				peer = server.accept();
				peer.setTimeout(5.0);
				endpoint.received = readBody(peer, endpoint);
				if (delay < 0) {
					// Unanswered until the case is over, or two seconds pass:
					// where the exchange runs inline, only this close ends it.
					endpoint.released.wait(2.0);
				} else {
					crossbyte.sys.System.sleep(delay);
					peer.output.writeString('HTTP/1.1 $status X\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body');
					peer.output.flush();
				}
			} catch (_:Dynamic) {
				listening.release();
			}
			for (socket in [peer, server]) {
				try {
					if (socket != null) {
						socket.close();
					}
				} catch (_:Dynamic) {}
			}
		});
		listening.wait(5.0);
		ready(endpoint);
		#end
	}

	#if (sys && !nodejs)
	static function readBody(peer:SysSocket, endpoint:TokenEndpoint):String {
		var length:Int = 0;
		while (true) {
			var line:String = peer.input.readLine();
			if (line == "") {
				break;
			}
			var separator:Int = line.indexOf(":");
			if (separator > 0 && StringTools.trim(line.substr(0, separator)).toLowerCase() == "authorization") {
				endpoint.authorization = StringTools.trim(line.substr(separator + 1));
			}
			if (separator > 0 && StringTools.trim(line.substr(0, separator)).toLowerCase() == "content-length") {
				length = crossbyte.utils.IntParse.decimal(StringTools.trim(line.substr(separator + 1)), 65536);
			}
		}
		return length > 0 ? peer.input.read(length).toString() : "";
	}
	#end
	#end
}

#if (sys || nodejs)
private class TokenEndpoint {
	public var port:Int = 0;
	public var received:Null<String> = null;
	public var authorization:Null<String> = null;
	#if (sys && !nodejs)
	public var released:Lock = new Lock();
	#end
	public var onClose:Null<Void->Void> = null;

	public function new() {}

	public function body():String {
		return received == null ? "" : received;
	}

	public function close():Void {
		#if (sys && !nodejs)
		released.release();
		#end
		if (onClose != null) {
			onClose();
		}
	}
}
#end
