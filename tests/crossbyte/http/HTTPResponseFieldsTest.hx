package crossbyte.http;

import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.io.ByteArray;
import crossbyte.url.URLRequestHeader;
import utest.Assert;
import utest.Async;

/**
 * What a caller's fields do to the ones a response always carries, as a
 * proxy passing on another server's answer finds out: each field is said
 * once, and the response's framing is the server's.
 */
@:timeout(20000)
class HTTPResponseFieldsTest extends utest.Test {
	public function testACallersFieldStandsInPlaceOfTheServers(async:Async):Void {
		var server:HTTPServer = __serve(handler -> handler.respond(200, "text/plain", "ok", [
			new URLRequestHeader("Date", "Thu, 01 Jan 2026 00:00:00 GMT"),
			new URLRequestHeader("server", "origin"),
			new URLRequestHeader("Content-Type", "application/json"),
			new URLRequestHeader("X-Other", "kept")
		]));

		HTTPTestSupport.exchangeEach(server, ["GET / HTTP/1.1\r\nHost: x\r\n\r\n"], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			var raw:String = responses[0].raw;
			Assert.equals(1, __count(raw, "date"), raw);
			Assert.equals(1, __count(raw, "server"), raw);
			Assert.equals(1, __count(raw, "content-type"), raw);
			Assert.isTrue(raw.indexOf("Thu, 01 Jan 2026") >= 0, raw);
			Assert.isTrue(raw.indexOf("server: origin") >= 0, raw);
			Assert.isTrue(raw.indexOf("application/json") >= 0, raw);
			Assert.isTrue(raw.indexOf("X-Other: kept") >= 0, raw);
			Assert.equals(1, __count(raw, "x-content-type-options"), "a field nobody named went: " + raw);
			async.done();
		});
	}

	/** Given empty, the server's own goes, and a null `contentType` sends none rather than an empty one. **/
	public function testAnEmptyFieldTakesTheServersOut(async:Async):Void {
		var server:HTTPServer = __serve(handler -> handler.respond(200, null, "ok", [
			new URLRequestHeader("Server", ""),
			new URLRequestHeader("X-Content-Type-Options", "")
		]));

		HTTPTestSupport.exchangeEach(server, ["GET / HTTP/1.1\r\nHost: x\r\n\r\n"], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			var raw:String = responses[0].raw;
			Assert.equals(200, responses[0].status);
			Assert.equals("ok", responses[0].body);
			Assert.equals(0, __count(raw, "server"), raw);
			Assert.equals(0, __count(raw, "x-content-type-options"), raw);
			Assert.equals(0, __count(raw, "content-type"), raw);
			Assert.equals(1, __count(raw, "date"), raw);
			async.done();
		});
	}

	/**
		A field the server has no field of its own for is the caller's, however
		many there are and whatever the server left out: with no `contentType`,
		or one of its fields taken out, the first of a caller's is where the
		server's would have been, and is not one to stand in for.
	**/
	public function testRepeatedFieldsAreAllKept(async:Async):Void {
		var server:HTTPServer = __serve(handler -> {
			var cookies:Array<URLRequestHeader> = [new URLRequestHeader("Set-Cookie", "a=1"), new URLRequestHeader("Set-Cookie", "b=2")];
			switch (handler.requestPath) {
				case "/none":
					handler.respond(302, null, "", cookies);
				case "/out":
					handler.respond(200, "text/plain", "ok", [new URLRequestHeader("Server", "")].concat(cookies));
				case "/both":
					handler.respond(200, null, "ok", [new URLRequestHeader("Server", ""), new URLRequestHeader("X-Content-Type-Options", "")].concat(cookies));
				default:
					handler.respond(200, "text/plain", "ok", cookies);
			}
		});

		HTTPTestSupport.exchangeEach(server, [
			"GET /none HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /out HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /both HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /all HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			for (response in responses) {
				Assert.equals(2, __count(response.raw, "set-cookie"), "a cookie was lost: " + response.raw);
				Assert.isTrue(response.raw.indexOf("a=1") >= 0, response.raw);
				Assert.isTrue(response.raw.indexOf("b=2") >= 0, response.raw);
			}
			async.done();
		});
	}

	/** Named twice, the server's own field is still said once, and a name of the server's it left out goes as given. **/
	public function testAFieldOfTheServersIsSaidOnceHoweverOftenItIsNamed(async:Async):Void {
		var server:HTTPServer = __serve(handler -> handler.respond(200, null, "ok", [
			new URLRequestHeader("Server", "one"),
			new URLRequestHeader("Server", "two"),
			new URLRequestHeader("Content-Type", "application/json")
		]));

		HTTPTestSupport.exchangeEach(server, ["GET / HTTP/1.1\r\nHost: x\r\n\r\n"], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			var raw:String = responses[0].raw;
			Assert.equals(1, __count(raw, "server"), raw);
			Assert.isTrue(raw.indexOf("Server: two") >= 0, raw);
			Assert.equals(1, __count(raw, "content-type"), raw);
			Assert.isTrue(raw.indexOf("application/json") >= 0, raw);
			async.done();
		});
	}

	/** Listened to, a response's fields are handed out rather than kept, and read the same. **/
	public function testAListenerHearsTheFieldsThatWent(async:Async):Void {
		var heard:Array<String> = [];
		var server:HTTPServer = __serve(handler -> {
			handler.addEventListener(crossbyte.events.HTTPStatusEvent.HTTP_RESPONSE_STATUS, function(e:crossbyte.events.HTTPStatusEvent):Void {
				heard = [for (field in e.responseHeaders) field.name + "=" + field.value];
			});
			handler.respond(200, null, "ok", [new URLRequestHeader("Server", "origin")]);
		});

		HTTPTestSupport.exchangeEach(server, ["GET / HTTP/1.1\r\nHost: x\r\n\r\n"], function(_):Void {
			try server.close() catch (_:Dynamic) {}
			Assert.isTrue(heard.indexOf("Server=origin") >= 0, heard.join(", "));
			Assert.equals(-1, heard.indexOf("Server=CrossByte"), heard.join(", "));
			Assert.equals(0, heard.filter(field -> StringTools.startsWith(field, "Content-Type")).length, heard.join(", "));
			async.done();
		});
	}

	/**
		The connection after a response with its fields replaced is served as
		usual: the kept fields a response begins from are not the caller's.
	**/
	public function testTheNextResponseHasTheServersFieldsAgain(async:Async):Void {
		var first:Bool = true;
		var server:HTTPServer = __serve(handler -> {
			var headers:Array<URLRequestHeader> = first ? [new URLRequestHeader("Server", ""), new URLRequestHeader("Date", "x")] : [];
			first = false;
			handler.respond(200, "text/plain", "ok", headers);
		});

		HTTPTestSupport.exchangeEach(server, ["GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			var raw:String = responses[0].raw;
			var second:Int = raw.indexOf("HTTP/1.1 200", 10);
			Assert.isTrue(second > 0, raw);
			Assert.equals(1, __count(raw.substr(second), "server"), raw);
			Assert.equals(-1, raw.substr(second).indexOf("Date: x"), raw);
			async.done();
		}, true);
	}

	/** A body's length is the server's to say: a caller's beside it went out as a second, and could be a lie. **/
	public function testFramingIsTheServers(async:Async):Void {
		var server:HTTPServer = __serve(handler -> handler.respond(200, "text/plain", "hello", [
			new URLRequestHeader("Content-Length", "999"),
			new URLRequestHeader("Transfer-Encoding", "chunked")
		]));

		HTTPTestSupport.exchangeEach(server, ["GET / HTTP/1.1\r\nHost: x\r\n\r\n"], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			var raw:String = responses[0].raw;
			Assert.equals(1, __count(raw, "content-length"), raw);
			Assert.isTrue(raw.indexOf("Content-Length: 5") >= 0, raw);
			Assert.equals(0, __count(raw, "transfer-encoding"), raw);
			Assert.equals("hello", responses[0].body);
			async.done();
		});
	}

	/**
		A `HEAD` has no body to give its length by, so a proxy names it, and
		one left unnamed says what it always did. What the `GET` would say, for
		`respond` and `respondBytes` alike.
	**/
	public function testAHeadMayNameItsLength(async:Async):Void {
		var server:HTTPServer = __serve(handler -> {
			switch (handler.requestPath) {
				case "/named":
					handler.respondBytes(200, "text/plain", new ByteArray(), [new URLRequestHeader("Content-Length", "123")]);
				case "/text":
					handler.respond(200, "text/plain", "", [new URLRequestHeader("Content-Length", "45")]);
				case "/wrong":
					handler.respondBytes(200, "text/plain", new ByteArray(), [new URLRequestHeader("Content-Length", "12x")]);
				case "/body":
					var body:ByteArray = new ByteArray();
					body.writeUtfBytes("hello");
					handler.respondBytes(200, "text/plain", body, [new URLRequestHeader("Content-Length", "123")]);
				default:
					handler.respondBytes(200, "text/plain", new ByteArray());
			}
		});

		HTTPTestSupport.exchangeEach(server, [
			"HEAD /named HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
			"HEAD /text HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
			"HEAD /wrong HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
			"HEAD /body HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
			"HEAD /plain HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			Assert.isTrue(responses[0].raw.indexOf("Content-Length: 123") >= 0, responses[0].raw);
			Assert.isTrue(responses[1].raw.indexOf("Content-Length: 45") >= 0, responses[1].raw);
			Assert.isTrue(responses[2].raw.indexOf("Content-Length: 0") >= 0, "a length that is none was taken: " + responses[2].raw);
			Assert.isTrue(responses[3].raw.indexOf("Content-Length: 5") >= 0, "a body said one length and the caller another: " + responses[3].raw);
			Assert.isTrue(responses[4].raw.indexOf("Content-Length: 0") >= 0, responses[4].raw);
			for (response in responses) {
				Assert.equals(1, __count(response.raw, "content-length"), response.raw);
				Assert.equals(200, response.status);
			}
			async.done();
		}, true);
	}

	private function __serve(answer:HTTPRequestHandler->Void):HTTPServer {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.compression.enabled = false;
		config.middleware.push(function(handler:HTTPRequestHandler, _:?Dynamic->Void):Void {
			answer(handler);
		});
		return new HTTPServer(config);
	}

	/** How many lines of `raw`'s first head name `field`. */
	private static function __count(raw:String, field:String):Int {
		var head:String = raw.substr(0, raw.indexOf("\r\n\r\n"));
		var count:Int = 0;
		for (line in head.split("\r\n")) {
			if (StringTools.startsWith(line.toLowerCase(), field + ":")) {
				count++;
			}
		}
		return count;
	}
}
