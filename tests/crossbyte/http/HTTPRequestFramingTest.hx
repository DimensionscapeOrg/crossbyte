package crossbyte.http;

import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.test.Require;
import utest.Assert;
import utest.Async;

/**
 * Where one request ends and the next begins, as a peer can bend it.
 *
 * A server and whatever stands in front of it have to agree on that, or a
 * request can travel inside another: the proxy passes one request it
 * inspected, and the server reads two. So every case here sends what should
 * be one request, and checks both the answer and that nothing after it was
 * parsed as a second.
 */
@:timeout(20000)
class HTTPRequestFramingTest extends utest.Test {
	/**
		A `Content-Length` no `Int` can hold is refused rather than read as
		some smaller number.

		On Linux and macOS native, `Std.parseInt` is `strtol` cast to an
		`int`, so 4294967296 read as 0 and 4294967396 as 100. At 0 the server
		read no body and parsed the body as the next request, a smuggled
		request, unseen by anything that inspected the outer one. On the jvm
		the same field threw and was answered 500. The request carried in the
		body here must never reach the application.
	**/
	public function testALengthNoIntCanHoldIsRefused(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen);
		var smuggled:String = "GET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n";

		HTTPTestSupport.exchangeEach(server, [
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967296\r\n\r\n" + smuggled,
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967396\r\n\r\n" + smuggled,
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 18446744073709551616\r\n\r\n" + smuggled,
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\n" + smuggled
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			for (i in 0...responses.length) {
				Assert.equals(400, responses[i].status, "request " + i + " was not refused as malformed");
				Assert.equals(1, HTTPTestSupport.countResponses(responses[i].raw), "request " + i + " drew more than one response");
			}
			Assert.equals(0, seen.length, "a request reached the application: " + seen.join(", "));
			async.done();
		}, true);
	}

	/** RFC 9112 6.3: repeated lengths that disagree are refused, equal ones read. **/
	public function testRepeatedLengthsMustAgree(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen);

		HTTPTestSupport.exchangeEach(server, [
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\nhello",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: +5\r\n\r\nhello",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 0x5\r\n\r\nhello"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(400, responses[0].status, "5 and 6 were accepted together");
			Assert.equals(200, responses[1].status, "an agreeing repeat was refused");
			Assert.equals("got 5", responses[1].body);
			Assert.equals(400, responses[2].status, "a signed length was accepted");
			Assert.equals(400, responses[3].status, "a hex length was accepted");
			Assert.equals(1, seen.length, "only the agreeing request should have reached the application");
			async.done();
		});
	}

	/**
		A body too big is `413`, not `400`, and is refused on its
		`Content-Length` before any of it is read.
	**/
	public function testALengthPastTheLimitIs413(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen);

		HTTPTestSupport.exchangeEach(server, [
			'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${HTTPServerConfig.DEFAULT_MAX_REQUEST_BODY + 1}\r\n\r\n'
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(413, responses[0].status, "a body one byte past the limit was not refused as too large");
			Assert.equals(0, seen.length, "an oversized request reached the application");
			async.done();
		}, true);
	}

	/** The limit is the application's to set, both ways. **/
	public function testTheBodyLimitIsConfigurable(async:Async):Void {
		var seen:Array<String> = [];
		var small:HTTPServer = __serve(seen, config -> config.maxRequestBodySize = 10);

		HTTPTestSupport.exchangeEach(small, [
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhelloworld",
			"POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try small.close() catch (_:Dynamic) {}

			Assert.equals(413, responses[0].status, "a lowered limit was not applied");
			Assert.equals(200, responses[1].status);
			Assert.equals(413, responses[2].status, "a chunked body past a lowered limit was not refused");

			var large:HTTPServer = __serve(seen, config -> config.maxRequestBodySize = 2 * 1024 * 1024);
			var body:String = StringTools.rpad("", "x", 1536 * 1024);
			HTTPTestSupport.exchangeEach(large, ['POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${body.length}\r\n\r\n' + body], function(big):Void {
				try large.close() catch (_:Dynamic) {}

				Assert.equals(200, big[0].status, "a raised limit was not applied");
				Assert.equals("got " + body.length, big[0].body);
				async.done();
			}, false, 10.0);
		});
	}

	/**
		`Expect: 100-continue` waits for the application.

		The server told every such client to send before any middleware had
		seen the request, so an unauthenticated upload was invited in full.
	**/
	public function testExpectContinueAsksTheApplicationFirst(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen, config -> config.onExpectContinue = handler -> {
			if (handler.getHeader("authorization") == "Bearer ok") {
				return true;
			}
			handler.respond(401, "text/plain", "sign in first");
			return false;
		});

		HTTPTestSupport.exchangeEach(server, [
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n",
			"POST /upload HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ok\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\nhello"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(401, responses[0].status);
			Assert.isTrue(responses[0].raw.indexOf("100 Continue") < 0, "an unauthenticated client was told to send its body");
			Assert.isTrue(responses[1].raw.indexOf("HTTP/1.1 100 Continue") == 0, "an accepted client was not told to continue");
			Assert.equals(200, responses[1].status);
			Assert.equals("got 5", responses[1].body);
			async.done();
		});
	}

	/** Headers have a limit of their own, rather than a share of the body's. **/
	public function testAnOversizedHeaderBlockIs431(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen);
		var filler:String = StringTools.rpad("", "a", 70 * 1024);

		HTTPTestSupport.exchangeEach(server, ['GET /upload HTTP/1.1\r\nHost: x\r\nX-Filler: $filler\r\n\r\n'], function(responses):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(431, responses[0].status);
			Assert.equals(0, seen.length);
			async.done();
		});
	}

	#if nodejs
	/**
		Node's client frames a body on any method.

		Node frames a body only for the methods it expects one on, so a body on
		a DELETE went out bare: this server read it as the start of the next
		request, and the next call on the pooled socket got a 400.
	**/
	public function testTheNodeClientFramesABodyOnAnyMethod(async:Async):Void {
		var router:Router = new Router();
		router.delete("/item", ctx -> ctx.handler.respond(200, "text/plain", "deleted " + ctx.handler.requestText));
		router.get("/item", ctx -> ctx.handler.respond(200, "text/plain", "still here"));
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.middleware.push(router.middleware());
		var server:HTTPServer = new HTTPServer(config);

		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, function(_):Void {
			var base:String = 'http://127.0.0.1:${server.localPort}/item';
			var delete = new crossbyte.url.URLRequest(base);
			delete.method = "DELETE";
			delete.data = "payload";

			__send(delete, function(first:String):Void {
				__send(new crossbyte.url.URLRequest(base), function(second:String):Void {
					try server.close() catch (_:Dynamic) {}

					Assert.equals("200 deleted payload", first, "a DELETE's body did not arrive framed");
					Assert.equals("200 still here", second, "the next request on the socket was corrupted");
					async.done();
				});
			});
		});
	}

	/** A `URLVariables` is a form: the query of a GET, the body of a POST. **/
	public function testTheNodeClientSendsURLVariablesAsAForm(async:Async):Void {
		var router:Router = new Router();
		router.post("/form", ctx -> ctx.handler.respond(200, "text/plain", ctx.handler.getHeader("content-type") + "|" + ctx.handler.requestText));
		router.get("/form", ctx -> ctx.handler.respond(200, "text/plain", ctx.handler.queryString));
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.middleware.push(router.middleware());
		var server:HTTPServer = new HTTPServer(config);

		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, function(_):Void {
			var url:String = 'http://127.0.0.1:${server.localPort}/form';
			var post = new crossbyte.url.URLRequest(url);
			post.method = "POST";
			post.data = new crossbyte.url.URLVariables("name=Ada%20L&tag=a&tag=b");
			var get = new crossbyte.url.URLRequest(url);
			get.data = new crossbyte.url.URLVariables("q=x%20y");

			__send(post, function(posted:String):Void {
				__send(get, function(queried:String):Void {
					try server.close() catch (_:Dynamic) {}

					Assert.isTrue(StringTools.startsWith(posted, "200 application/x-www-form-urlencoded|"), posted);
					var form:Array<String> = posted.substr(posted.indexOf("|") + 1).split("&");
					form.sort(Reflect.compare);
					Assert.same(["name=Ada%20L", "tag=a", "tag=b"], form);
					Assert.equals("200 q=x%20y", queried);
					async.done();
				});
			});
		});
	}

	/**
		On Node a 404 is an IO_ERROR carrying its body, and the response's
		headers reach the loader, as on native. It completed here, and no
		target dispatched HTTP_RESPONSE_STATUS at all.
	**/
	public function testTheNodeLoaderKeepsTheNativeStatusContract(async:Async):Void {
		var router:Router = new Router();
		router.get("/missing", ctx -> ctx.handler.respond(404, "text/plain", "not here", [new crossbyte.url.URLRequestHeader("Retry-After", "30")]));
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.middleware.push(router.middleware());
		var server:HTTPServer = new HTTPServer(config);

		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, function(_):Void {
			var url:String = 'http://127.0.0.1:${server.localPort}/missing';
			__load(new crossbyte.url.URLRequest(url), function(outcome:LoaderOutcome):Void {
				try server.close() catch (_:Dynamic) {}

				Assert.equals("HTTP error 404", outcome.error, "a 404 was not an error on Node");
				Assert.isFalse(outcome.complete);
				Assert.equals("not here", outcome.data);
				Require.notNull(outcome.response, "HTTP_RESPONSE_STATUS was not dispatched");
				Assert.equals(404, outcome.response.status);
				Assert.equals(url, outcome.response.responseURL);
				Assert.equals("30", __responseHeader(outcome.response, "retry-after"));
				async.done();
			});
		});
	}

	/**
		Node follows redirects as the native client does, dropping credentials
		once one leaves the origin. A 3xx used to complete the load on Node.
	**/
	public function testTheNodeLoaderFollowsRedirectsSafely(async:Async):Void {
		var elsewhereRouter:Router = new Router();
		elsewhereRouter.get("/landing", ctx -> ctx.handler.respond(200, "text/plain", "auth=" + ctx.handler.getHeader("authorization")));
		var elsewhereConfig:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		elsewhereConfig.middleware.push(elsewhereRouter.middleware());
		var elsewhere:HTTPServer = new HTTPServer(elsewhereConfig);

		var originRouter:Router = new Router();
		originRouter.get("/old", ctx -> ctx.handler.respond(302, "text/plain", "", [new crossbyte.url.URLRequestHeader("Location", "/new")]));
		originRouter.get("/new", ctx -> ctx.handler.respond(200, "text/plain", "moved, auth=" + ctx.handler.getHeader("authorization")));
		originRouter.get("/away", ctx -> ctx.handler.respond(302, "text/plain", "",
			[new crossbyte.url.URLRequestHeader("Location", 'http://127.0.0.1:${elsewhere.localPort}/landing')]));
		var originConfig:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		originConfig.middleware.push(originRouter.middleware());
		var origin:HTTPServer = new HTTPServer(originConfig);

		HTTPTestSupport.pumpUntilAsync(() -> origin.localPort != 0 && elsewhere.localPort != 0, 2.0, function(_):Void {
			var local = new crossbyte.url.URLRequest('http://127.0.0.1:${origin.localPort}/old');
			local.requestHeaders.push(new crossbyte.url.URLRequestHeader("Authorization", "Bearer secret"));

			__load(local, function(followed:LoaderOutcome):Void {
				var away = new crossbyte.url.URLRequest('http://127.0.0.1:${origin.localPort}/away');
				away.requestHeaders.push(new crossbyte.url.URLRequestHeader("Authorization", "Bearer secret"));

				__load(away, function(crossed:LoaderOutcome):Void {
					try origin.close() catch (_:Dynamic) {}
					try elsewhere.close() catch (_:Dynamic) {}

					Assert.isTrue(followed.complete, "a redirect was not followed on Node: " + followed.error);
					Assert.equals("moved, auth=Bearer secret", followed.data, "credentials were dropped within the origin");
					Require.notNull(followed.response);
					Assert.isTrue(followed.response.redirected);
					Assert.equals('http://127.0.0.1:${origin.localPort}/new', followed.response.responseURL);

					Assert.isTrue(crossed.complete, "a cross-origin redirect was not followed: " + crossed.error);
					Assert.equals("auth=null", crossed.data, "Authorization followed a redirect to another origin");
					async.done();
				});
			});
		});
	}

	private static function __load(request:crossbyte.url.URLRequest, done:LoaderOutcome->Void):Void {
		var loader = new crossbyte.url.URLLoader();
		var outcome:LoaderOutcome = {complete: false, error: null, data: null, response: null};
		loader.addEventListener(crossbyte.events.HTTPStatusEvent.HTTP_RESPONSE_STATUS, e -> outcome.response = e);
		loader.addEventListener(crossbyte.events.Event.COMPLETE, _ -> {
			outcome.complete = true;
			outcome.data = Std.string(loader.data);
		});
		loader.addEventListener(crossbyte.events.IOErrorEvent.IO_ERROR, e -> {
			outcome.error = e.text;
			outcome.data = loader.data == null ? null : Std.string(loader.data);
		});
		loader.load(request);
		HTTPTestSupport.pumpUntilAsync(() -> outcome.complete || outcome.error != null, 5.0, _ -> done(outcome));
	}

	private static function __responseHeader(event:crossbyte.events.HTTPStatusEvent, name:String):Null<String> {
		for (header in event.responseHeaders) {
			if (header.name == name) {
				return header.value;
			}
		}
		return null;
	}

	/** Sends through the Node client and hands back "status body". **/
	private static function __send(request:crossbyte.url.URLRequest, done:String->Void):Void {
		var status:Int = 0;
		var answer:String = null;
		crossbyte.url._internal.JsHttpClient.send(request, code -> status = code, (_, _) -> {}, bytes -> answer = status + " " + bytes.toString(),
			message -> answer = "error " + message);
		HTTPTestSupport.pumpUntilAsync(() -> answer != null, 5.0, _ -> done(answer));
	}
	#end

	private function __serve(seen:Array<String>, ?configure:HTTPServerConfig->Void):HTTPServer {
		var router:Router = new Router();
		router.post("/upload", ctx -> ctx.handler.respond(200, "text/plain", "got " + ctx.handler.requestBody.length));

		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		if (configure != null) {
			configure(config);
		}
		config.middleware.push(function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
			seen.push(handler.method + " " + handler.requestPath);
			next();
		});
		config.middleware.push(router.middleware());
		return new HTTPServer(config);
	}
}

#if nodejs
private typedef LoaderOutcome = {
	var complete:Bool;
	var error:String;
	var data:String;
	var response:crossbyte.events.HTTPStatusEvent;
}
#end
