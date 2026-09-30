package crossbyte.url;

// Node only: the client under test is Node's own, behind JsHttpClient.
#if nodejs
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.http.HTTPTestSupport;
import crossbyte.net.TLSTestFixture;
import utest.Assert;
import utest.Async;

/**
 * `URLLoader` on Node, where it runs over Node's http client rather than
 * CrossByte's own.
 *
 * That client never decoded a content coding: a gzip answer reached the
 * caller as gzip, garbage as text, and the next such body threw a RangeError
 * out of `getString` inside the loader's completion, which ended the process.
 * jvm and eval decoded the same responses. It decodes them now, with Node's
 * zlib and within `URLRequest.maxDecompressedSize`, and a body that cannot be
 * read as text is an `IO_ERROR`.
 *
 * And a request's TLS settings -- the authority it trusts, `verifyCert`, a
 * client certificate, pinned keys -- reach Node's client, against Node's own
 * https server.
 */
@:timeout(20000)
class URLLoaderNodeTest extends utest.Test {
	static inline final JSON:String = '{"name":"crossbyte","items":[1,2,3,4,5,6,7,8,9,10],"text":"the same words over and over and over again"}';

	public function testCompressedAnswersAreDecoded(async:Async):Void {
		serve(function(port:Int, close:Void->Void):Void {
			var paths:Array<String> = ["gzip", "br", "deflate", "raw", "stacked"];
			var results:Array<String> = [];

			function next(index:Int):Void {
				if (index >= paths.length) {
					close();
					for (i in 0...paths.length) {
						Assert.equals("ok " + JSON, results[i], paths[i]);
					}
					async.done();
					return;
				}
				load('http://127.0.0.1:$port/${paths[index]}', null, outcome -> {
					results.push(outcome);
					next(index + 1);
				});
			}
			next(0);
		});
	}

	public function testABodyThatIsNotTextIsAnErrorNotACrash(async:Async):Void {
		// F8 88 80 80 80 is a five-byte UTF-8 lead nothing decodes to a code
		// point: getString threw a RangeError here, out of the completion.
		serve(function(port:Int, close:Void->Void):Void {
			load('http://127.0.0.1:$port/binary', null, outcome -> {
				close();
				Assert.isTrue(StringTools.startsWith(outcome, "error "), outcome);
				Assert.isTrue(outcome.indexOf("could not be read as text") >= 0, outcome);
				async.done();
			});
		});
	}

	public function testTheDecodeLimitHolds(async:Async):Void {
		// A megabyte of zeros is about a kilobyte of gzip.
		serve(function(port:Int, close:Void->Void):Void {
			load('http://127.0.0.1:$port/bomb', 64 * 1024, outcome -> {
				close();
				Assert.isTrue(StringTools.startsWith(outcome, "error "), "a body past the decode limit was taken: " + outcome.substr(0, 60));
				Assert.isTrue(outcome.indexOf("decode") >= 0, outcome);
				async.done();
			});
		});
	}

	/**
		A request's TLS settings reach Node's client: the authority it trusts,
		`verifyCert`, and a connection opened without checking is not handed
		to a request that checks. There were no settings to reach it.
	**/
	public function testARequestTrustsTheAuthorityItNames(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			async.done();
			return;
		}
		serveTls(fixture, null, function(port:Int, served:Void->Int, close:Void->Void):Void {
			var url:String = 'https://127.0.0.1:$port/';
			loadWith(url, _ -> {}, unconfigured -> {
				loadWith(url, request -> request.certAuthority = fixture.certificate, trusting -> {
					loadWith(url, request -> request.verifyCert = false, unchecked -> {
						// The agent holds the unchecked connection now.
						loadWith(url, _ -> {}, checkedAfter -> {
							close();
							Assert.isTrue(StringTools.startsWith(unconfigured, "error "), "an untrusted server was not refused: " + unconfigured);
							Assert.equals("ok hello", trusting, "the authority the request named was not trusted");
							Assert.equals("ok hello", unchecked, "verifyCert = false still checked");
							Assert.isTrue(StringTools.startsWith(checkedAfter, "error "), "a checking request was sent down an unchecked connection: " + checkedAfter);
							async.done();
						});
					});
				});
			});
		});
	}

	/**
		A pin is checked whether or not the chain is, and a request that fails
		it sends nothing. Checked in `checkServerIdentity`, which Node calls
		only for a chain that verified, a pin with `verifyCert` off -- pinning
		a self-signed server's key rather than trusting it -- was ignored, and
		the request went to whatever server answered.
	**/
	public function testAPinIsCheckedWithOrWithoutTheChain(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			async.done();
			return;
		}
		var pin:String = pinOf(fixture.certificatePath);
		var wrong:String = "sha256/" + haxe.crypto.Base64.encode(haxe.io.Bytes.alloc(32));
		serveTls(fixture, null, function(port:Int, served:Void->Int, close:Void->Void):Void {
			var url:String = 'https://127.0.0.1:$port/';
			loadWith(url, request -> {
				request.verifyCert = false;
				request.pinnedPublicKeys = [wrong];
			}, uncheckedWrong -> {
				loadWith(url, request -> {
					request.certAuthority = fixture.certificate;
					request.pinnedPublicKeys = [wrong];
				}, checkedWrong -> {
					var servedWrong:Int = served();
					loadWith(url, request -> {
						request.verifyCert = false;
						request.pinnedPublicKeys = [wrong, pin];
					}, uncheckedRight -> {
						loadWith(url, request -> {
							request.certAuthority = fixture.certificate;
							request.pinnedPublicKeys = [pin];
						}, checkedRight -> {
							close();
							Assert.isTrue(uncheckedWrong.indexOf("is not one this request pins") >= 0, "an unpinned key passed with verifyCert off: " + uncheckedWrong);
							Assert.isTrue(checkedWrong.indexOf("is not one this request pins") >= 0, "an unpinned key passed: " + checkedWrong);
							Assert.equals(0, servedWrong, "a request reached a server whose key it did not pin");
							Assert.equals("ok hello", uncheckedRight, "a pinned key was refused with verifyCert off");
							Assert.equals("ok hello", checkedRight, "a pinned key was refused");
							async.done();
						});
					});
				});
			});
		});
	}

	/**
		The client certificate is presented to a server that asks, and left
		behind by a redirect to another origin.
	**/
	public function testAClientCertificateIsPresentedToTheOriginNamed(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		var client = TLSTestFixture.trusted(["crossbyte-client"]);
		if (fixture == null || client == null) {
			Assert.pass();
			async.done();
			return;
		}
		serveTls(fixture, client.certificatePath, function(port:Int, served:Void->Int, close:Void->Void):Void {
			var guarded:String = 'https://127.0.0.1:$port/';
			// Another origin, sending the request on to the guarded one.
			serveTls(fixture, null, function(otherPort:Int, _, closeOther:Void->Void):Void {
				function presenting(request:URLRequest):Void {
					request.certAuthority = fixture.certificate;
					request.clientCertificate = client.certificate;
					request.clientKey = client.key;
				}
				loadWith(guarded, request -> request.certAuthority = fixture.certificate, anonymous -> {
					loadWith(guarded, presenting, presented -> {
						loadWith('https://127.0.0.1:$otherPort/away?to=$port', presenting, redirected -> {
							var servedGuarded:Int = served();
							close();
							closeOther();
							Assert.isTrue(StringTools.startsWith(anonymous, "error "), "a server requiring a certificate answered a request presenting none: " + anonymous);
							Assert.equals("ok hello", presented, "the client certificate was not presented");
							Assert.isTrue(StringTools.startsWith(redirected, "error "), "the client certificate followed a redirect to another origin: " + redirected);
							Assert.equals(1, servedGuarded, "the guarded server answered other than the one request that presented a certificate");
							async.done();
						});
					});
				});
			});
		});
	}

	/** Loads `url` as text, and calls `done` with "ok <data>" or "error <text>". */
	private static function load(url:String, limit:Null<Int>, done:String->Void):Void {
		loadWith(url, request -> {
			request.requestHeaders.push(new URLRequestHeader("Accept-Encoding", "gzip, br, deflate"));
			if (limit != null) {
				request.maxDecompressedSize = limit;
			}
		}, done);
	}

	/** Loads `url` as text, with the request as `configure` leaves it. */
	private static function loadWith(url:String, configure:URLRequest->Void, done:String->Void):Void {
		var loader:URLLoader = new URLLoader();
		var outcome:Null<String> = null;
		loader.addEventListener(Event.COMPLETE, _ -> outcome = "ok " + Std.string(loader.data));
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> outcome = "error " + event.text);
		var request:URLRequest = new URLRequest(url);
		configure(request);
		loader.load(request);
		HTTPTestSupport.pumpUntilAsync(() -> outcome != null, 10.0, _ -> done(outcome == null ? "error timed out" : outcome));
	}

	/**
		Node's https server on `fixture`, answering "hello" -- or, at
		`/away?to=PORT`, sending the request on to that port -- and, given
		`clientAuthority`, requiring a client certificate it signed. `served`
		counts the requests answered.
	**/
	private static function serveTls(fixture:crossbyte.net.TLSTestFixture.TLSFixtureData, clientAuthority:Null<String>,
			then:(port:Int, served:Void->Int, close:Void->Void) -> Void):Void {
		var options:Dynamic = {
			key: sys.io.File.getContent(fixture.keyPath),
			cert: sys.io.File.getContent(fixture.certificatePath)
		};
		if (clientAuthority != null) {
			options.ca = [sys.io.File.getContent(clientAuthority)];
			options.requestCert = true;
			options.rejectUnauthorized = true;
		}
		var served:Int = 0;
		var server:Dynamic = js.Lib.require("https").createServer(options, function(request:Dynamic, response:Dynamic):Void {
			var url:String = Std.string(request.url);
			if (StringTools.startsWith(url, "/away?to=")) {
				response.writeHead(302, {"Location": "https://127.0.0.1:" + url.substr("/away?to=".length) + "/"});
				response.end();
				return;
			}
			served++;
			response.writeHead(200, {"Content-Type": "text/plain"});
			response.end("hello");
		});
		server.listen(0, "127.0.0.1", function():Void {
			then(server.address().port, () -> served, () -> {
				server.close();
				// Kept-alive sockets would hold the server, and the process, open.
				if (server.closeAllConnections != null) {
					server.closeAllConnections();
				}
			});
		});
	}

	/** The pin of the certificate in the PEM file at `path`. */
	private static function pinOf(path:String):String {
		var pem:String = sys.io.File.getContent(path);
		var begin:String = "-----BEGIN CERTIFICATE-----";
		var body:String = pem.substring(pem.indexOf(begin) + begin.length, pem.indexOf("-----END CERTIFICATE-----"));
		return crossbyte._internal.http.PublicKeyPins.pinOf(haxe.crypto.Base64.decode(~/\s/g.replace(body, "")));
	}

	/** Starts Node's http server with the answers this suite asks for. */
	private static function serve(then:(port:Int, close:Void->Void) -> Void):Void {
		var zlib:Dynamic = js.Lib.require("zlib");
		var json:js.node.Buffer = js.node.Buffer.from(JSON);
		var server:js.node.http.Server = js.node.Http.createServer(function(request, response):Void {
			var url:String = Std.string(request.url);
			var headers:Dynamic = {"Content-Type": "application/json"};
			var body:js.node.Buffer = json;
			switch (url) {
				case "/gzip":
					body = zlib.gzipSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "gzip"};
				case "/br":
					body = zlib.brotliCompressSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "br"};
				case "/deflate":
					body = zlib.deflateSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "deflate"};
				case "/raw":
					// Raw deflate, which CrossByte's own server has sent as deflate.
					body = zlib.deflateRawSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "deflate"};
				case "/stacked":
					body = zlib.brotliCompressSync(zlib.gzipSync(json));
					headers = {"Content-Type": "application/json", "Content-Encoding": "gzip, br"};
				case "/binary":
					body = js.node.Buffer.from([0xF8, 0x88, 0x80, 0x80, 0x80]);
					headers = {"Content-Type": "text/plain"};
				case "/bomb":
					body = zlib.gzipSync(js.node.Buffer.alloc(1024 * 1024));
					headers = {"Content-Type": "application/octet-stream", "Content-Encoding": "gzip"};
				case _:
			}
			response.writeHead(200, headers);
			response.end(body);
		});
		server.listen(0, "127.0.0.1", function():Void {
			var port:Int = (server.address() : Dynamic).port;
			then(port, () -> server.close());
		});
	}
}
#end
