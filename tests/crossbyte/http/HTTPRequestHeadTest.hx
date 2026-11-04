package crossbyte.http;

import crossbyte.errors.IllegalOperationError;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.net.RateLimiter;
import crossbyte.net.Socket;
import crossbyte.url.URLRequestHeader;
import utest.Assert;
import utest.Async;

/**
 * `HTTPServerConfig.onRequestHead`: a request refused on its headers, before
 * its body is read, and what comes ahead of being asked and after it.
 */
@:timeout(20000)
class HTTPRequestHeadTest extends utest.Test {
	public function testItIsOffByDefault():Void {
		Assert.isNull(new HTTPServerConfig("127.0.0.1", 0).onRequestHead);
	}

	/**
		The case this exists for: a request for a host this server does not
		serve hears that, ahead of what it would be told about its length,
		however long, and no body it may have is read.
	**/
	public function testARefusalComesAheadOfTheBodysLimit(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen, handler -> {
			if (handler.getHeader("host") != "ours") {
				handler.respond(421, "text/plain", "Misdirected Request");
				return false;
			}
			return true;
		}, config -> config.maxRequestBodySize = 10);

		HTTPTestSupport.exchangeEach(server, [
			"POST /upload HTTP/1.1\r\nHost: theirs\r\nContent-Length: 1000\r\n\r\n",
			"POST /upload HTTP/1.1\r\nHost: theirs\r\nContent-Length: 5000000000\r\n\r\n",
			"POST /upload HTTP/1.1\r\nHost: ours\r\nContent-Length: 1000\r\n\r\n",
			"POST /upload HTTP/1.1\r\nHost: ours\r\nContent-Length: 5000000000\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(421, responses[0].status, "a foreign host heard about its length first");
			Assert.equals(421, responses[1].status, "a foreign host heard about its length first");
			Assert.equals(413, responses[2].status, "a body past the limit was let through");
			Assert.equals(413, responses[3].status, "a length past an Int was let through");
			Assert.equals(0, seen.length, "a request reached the application: " + seen.join(", "));
			async.done();
		}, true);
	}

	/** Let through, a request goes on as it would have, its body read and decoded before the chain runs. **/
	public function testALetThroughRequestGoesOnAsBefore(async:Async):Void {
		var asked:Array<String> = [];
		var server:HTTPServer = __serve([], handler -> {
			asked.push(handler.method + " " + handler.requestPath + " " + handler.getHeader("x-who") + " " + handler.requestBody.length);
			return true;
		});

		HTTPTestSupport.exchangeEach(server, ["POST /upload HTTP/1.1\r\nHost: x\r\nX-Who: me\r\nContent-Length: 5\r\n\r\nhello"],
			function(responses:Array<HTTPTestResponse>):Void {
				try server.close() catch (_:Dynamic) {}

				Assert.equals(200, responses[0].status);
				Assert.equals("got 5", responses[0].body);
				Assert.equals("POST /upload me 0", asked[0], "the hook was not asked once, before the body");
				Assert.equals(1, asked.length);
				async.done();
			});
	}

	public function testFalseWithNoAnswerIs403AndAThrowIs500(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(seen, handler -> {
			if (handler.requestPath == "/throw") {
				throw "the hook broke";
			}
			return false;
		});

		HTTPTestSupport.exchangeEach(server, [
			"GET /no HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /throw HTTP/1.1\r\nHost: x\r\n\r\n",
			"POST /no HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(403, responses[0].status);
			Assert.equals(500, responses[1].status);
			Assert.equals(403, responses[2].status);
			Assert.equals(0, seen.length, "a refused request reached the application");
			async.done();
		});
	}

	/** A request whose framing is refused is not one the application is asked about. **/
	public function testFramingIsRefusedBeforeItIsAsked(async:Async):Void {
		var asked:Int = 0;
		var server:HTTPServer = __serve([], handler -> {
			asked++;
			return true;
		});

		HTTPTestSupport.exchangeEach(server, [
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
			"POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n",
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 6\r\n\r\n",
			"POST /upload HTTP/1.1\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(400, responses[0].status);
			Assert.equals(501, responses[1].status);
			Assert.equals(400, responses[2].status);
			Assert.equals(400, responses[3].status);
			Assert.equals(0, asked, "a request of no sound framing was asked about");
			async.done();
		}, true);
	}

	public function testTheRateLimiterComesFirst(async:Async):Void {
		var asked:Int = 0;
		var server:HTTPServer = __serve([], handler -> {
			asked++;
			return true;
		}, config -> config.rateLimiter = new RateLimiter(1, 3600));

		HTTPTestSupport.exchangeEach(server, ["GET /a HTTP/1.1\r\nHost: x\r\n\r\n", "GET /b HTTP/1.1\r\nHost: x\r\n\r\n"],
			function(responses:Array<HTTPTestResponse>):Void {
				try server.close() catch (_:Dynamic) {}

				Assert.equals(429, responses[1].status);
				Assert.equals(1, asked, "a rate limited request was asked about");
				async.done();
			});
	}

	/** Refused before it is told to send, a body is never invited. **/
	public function testARefusalAheadOfExpectInvitesNothing(async:Async):Void {
		var server:HTTPServer = __serve([], handler -> {
			handler.respond(401, "text/plain", "who are you");
			return false;
		});

		HTTPTestSupport.exchangeEach(server, ["POST /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"],
			function(responses:Array<HTTPTestResponse>):Void {
				try server.close() catch (_:Dynamic) {}

				Assert.equals(401, responses[0].status, "the expectation was answered first: " + responses[0].raw);
				Assert.equals(-1, responses[0].raw.indexOf("100 Continue"), "the client was told to send");
				async.done();
			}, true);
	}

	/**
		A request with nothing left to read keeps its connection through a
		refusal, and the request behind it is served; one with a body to come
		closes, what follows it being unread.
	**/
	public function testARefusalClosesOnlyOverABody(async:Async):Void {
		var server:HTTPServer = __serve([], handler -> {
			if (handler.requestPath == "/no") {
				handler.respond(404, "text/plain", "no");
				return false;
			}
			return true;
		});

		var pipelined:String = "GET /no HTTP/1.1\r\nHost: x\r\n\r\nPOST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi";
		var overBody:String = "POST /no HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloGET /index HTTP/1.1\r\nHost: x\r\n\r\n";
		__send(server, pipelined, raw -> HTTPTestSupport.countResponses(raw) >= 2, function(first:String, _):Void {
			Assert.equals(2, HTTPTestSupport.countResponses(first), "the request behind a refusal was lost: " + first);
			Assert.isTrue(first.indexOf("got 2") >= 0, "the request behind a refusal was not served: " + first);

			__send(server, overBody, _ -> false, function(second:String, closed:Bool):Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals(1, HTTPTestSupport.countResponses(second), "bytes after a refused request were read as a request: " + second);
				Assert.isTrue(second.indexOf("Connection: close") >= 0, "a refusal over a body did not say it closes: " + second);
				Assert.isTrue(closed, "a refusal over a body did not close");
				async.done();
			});
		});
	}

	/** A refusal saying `Connection: close` closes, with nothing left to read too. **/
	public function testARefusalCanCloseItsConnection(async:Async):Void {
		var server:HTTPServer = __serve([], handler -> {
			handler.respond(421, "text/plain", "Misdirected Request", [new URLRequestHeader("Connection", "close")]);
			return false;
		});

		__send(server, "GET / HTTP/1.1\r\nHost: x\r\n\r\n", _ -> false, function(raw:String, closed:Bool):Void {
			try server.close() catch (_:Dynamic) {}
			Assert.isTrue(StringTools.startsWith(raw, "HTTP/1.1 421 "), raw);
			Assert.isTrue(closed, "the connection stayed open");
			async.done();
		});
	}

	/** A body is chosen at the head or not at all: past it the body has been read. **/
	public function testAReaderIsChosenAtTheHeadOrNotAtAll(async:Async):Void {
		var thrown:Null<Dynamic> = null;
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.middleware.push(function(handler:HTTPRequestHandler, _:?Dynamic->Void):Void {
			try {
				handler.streamRequestBody();
			} catch (error:Dynamic) {
				thrown = error;
			}
			handler.respond(200, "text/plain", "ok");
		});
		var server:HTTPServer = new HTTPServer(config);

		HTTPTestSupport.exchangeEach(server, ["POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi"], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(200, responses[0].status);
			Assert.isTrue(Std.isOfType(thrown, IllegalOperationError), "a late choice was not refused: " + thrown);
			async.done();
		});
	}

	private function __serve(seen:Array<String>, hook:HTTPRequestHandler->Bool, ?configure:HTTPServerConfig->Void):HTTPServer {
		var router:Router = new Router();
		router.post("/upload", ctx -> ctx.handler.respond(200, "text/plain", "got " + ctx.handler.requestBody.length));

		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.onRequestHead = hook;
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

	/** Sends `request` on one connection, and calls `then` with what came back once `done` says so, the connection closes, or 3 s pass. **/
	private function __send(server:HTTPServer, request:String, done:String->Bool, then:(String, Bool) -> Void):Void {
		var client:Socket = new Socket();
		var raw:String = "";
		var closed:Bool = false;
		client.addEventListener(Event.CONNECT, function(_):Void {
			client.writeUtfBytes(request);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			while (client.bytesAvailable > 0) {
				raw += String.fromCharCode(client.readUnsignedByte());
			}
		});
		client.addEventListener(Event.CLOSE, _ -> closed = true);
		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpWallUntilAsync(() -> closed || done(raw), 3.0, function(_):Void {
				var result:Bool = closed;
				try client.close() catch (_:Dynamic) {}
				then(raw, result);
			});
		});
	}
}
