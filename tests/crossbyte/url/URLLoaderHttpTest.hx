package crossbyte.url;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Thread;
import utest.Assert;

class URLLoaderHttpTest extends utest.Test {
	public function testLoadsFixedLengthTextAndReportsPublicEvents():Void {
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 5"], "hello"), 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/fixed');

		fixture.waitDone();

		Assert.equals("hello", result.data);
		Assert.same([200], result.statuses);
		Assert.equals(0, result.progress[0].loaded);
		Assert.equals(5, result.progress[0].total);
		Assert.equals(5, result.progress[result.progress.length - 1].loaded);
		Assert.isNull(result.error);
		Assert.isTrue(fixture.requests[0].raw.indexOf("GET /fixed HTTP/1.1") == 0);
	}

	public function testLoadsChunkedTextWithUnknownTotal():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/chunked');

		fixture.waitDone();

		Assert.equals("hello world", result.data);
		Assert.equals(-1, result.progress[0].total);
		Assert.equals(11, result.progress[result.progress.length - 1].loaded);
		Assert.isNull(result.error);
	}

	public function testLoadsCloseDelimitedText():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nclose body", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/close-delimited');

		fixture.waitDone();

		Assert.equals("close body", result.data);
		Assert.isNull(result.error);
	}

	public function testHeadCompletesWithoutReadingResponseBody():Void {
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 5"], "hello"), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/head');
		request.method = URLRequestMethod.HEAD;
		var result = load(request);

		fixture.waitDone();

		Assert.equals("", result.data);
		Assert.isNull(result.error);
		Assert.equals(5, result.progress[0].total);
		Assert.isTrue(fixture.requests[0].raw.indexOf("HEAD /head HTTP/1.1") == 0);
	}

	public function testInformationalStatusIsSkippedBeforeFinalResponse():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/continue');

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.same([100, 200], result.statuses);
		Assert.isNull(result.error);
	}

	public function testHttpErrorDispatchesIoErrorAndKeepsResponseBody():Void {
		var fixture = serveRequests(_ -> response(404, "Not Found", ["Content-Length: 7"], "missing"), 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/missing');

		fixture.waitDone();

		Assert.equals("HTTP error 404", result.error);
		Assert.equals("missing", result.data);
		Assert.same([404], result.statuses);
		Assert.isFalse(result.complete);
	}

	public function testPostObjectDataIsFormEncoded():Void {
		var fixture = serveRequests(_ -> response(204, "No Content", ["Content-Length: 0"], ""), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/submit');
		request.method = URLRequestMethod.POST;
		request.requestHeaders.push(new URLRequestHeader("X-Test", "yes"));
		request.data = {
			field: "a b",
			ok: false
		};
		var result = load(request);

		fixture.waitDone();

		Assert.equals("", result.data);
		Assert.isNull(result.error);
		Assert.isTrue(fixture.requests[0].raw.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.equals("yes", fixture.requests[0].headers.get("x-test"));
		Assert.equals("application/x-www-form-urlencoded; charset=utf-8", fixture.requests[0].headers.get("content-type"));
		Assert.isTrue(fixture.requests[0].body.indexOf("field=a%20b") >= 0);
		Assert.isTrue(fixture.requests[0].body.indexOf("ok=false") >= 0);
	}

	public function testRelativeRedirectNormalizesDotSegments():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/dir/start":
					response(302, "Found", ["Location: ../final?token=1", "Content-Length: 0"], "");
				case "/final?token=1":
					response(200, "OK", ["Content-Length: 4"], "done");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var result = loadText('http://127.0.0.1:${fixture.port}/dir/start');

		fixture.waitDone();

		Assert.equals("done", result.data);
		Assert.same([302, 200], result.statuses);
		Assert.equals("/dir/start", fixture.requests[0].target);
		Assert.equals("/final?token=1", fixture.requests[1].target);
		Assert.isNull(result.error);
	}

	public function testQueryOnlyRedirectPreservesBasePath():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/dir/start?old=1":
					response(302, "Found", ["Location: ?token=1", "Content-Length: 0"], "");
				case "/dir/start?token=1":
					response(200, "OK", ["Content-Length: 4"], "done");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var result = loadText('http://127.0.0.1:${fixture.port}/dir/start?old=1');

		fixture.waitDone();

		Assert.equals("done", result.data);
		Assert.same([302, 200], result.statuses);
		Assert.equals("/dir/start?old=1", fixture.requests[0].target);
		Assert.equals("/dir/start?token=1", fixture.requests[1].target);
		Assert.isNull(result.error);
	}

	public function testFollowRedirectsFalseCompletesWithRedirectResponse():Void {
		var fixture = serveRequests(_ -> response(302, "Found", ["Location: /final", "Content-Length: 0"], ""), 1);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/start');
		request.followRedirects = false;
		var result = load(request);

		fixture.waitDone();

		Assert.isTrue(result.complete);
		Assert.equals("", result.data);
		Assert.same([302], result.statuses);
		Assert.equals(1, fixture.requests.length);
	}

	public function testSeeOtherRedirectConvertsPostToGetAndDropsBody():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/submit":
					response(303, "See Other", ["Location: /final", "Content-Length: 0"], "");
				case "/final":
					response(200, "OK", ["Content-Length: 2"], "ok");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/submit');
		request.method = URLRequestMethod.POST;
		request.data = "payload";
		var result = load(request);

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.same([303, 200], result.statuses);
		Assert.isTrue(fixture.requests[0].raw.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.equals("payload", fixture.requests[0].body);
		Assert.isTrue(fixture.requests[1].raw.indexOf("GET /final HTTP/1.1") == 0);
		Assert.equals("", fixture.requests[1].body);
	}

	public function testTemporaryRedirectPreservesPostMethodAndBody():Void {
		var fixture = serveRequests(request -> {
			return switch (request.target) {
				case "/submit":
					response(307, "Temporary Redirect", ["Location: /final", "Content-Length: 0"], "");
				case "/final":
					response(200, "OK", ["Content-Length: 2"], "ok");
				default:
					response(500, "Unexpected", ["Content-Length: 0"], "");
			}
		}, 2);
		var request = new URLRequest('http://127.0.0.1:${fixture.port}/submit');
		request.method = URLRequestMethod.POST;
		request.data = "payload";
		var result = load(request);

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.same([307, 200], result.statuses);
		Assert.isTrue(fixture.requests[0].raw.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.equals("payload", fixture.requests[0].body);
		Assert.isTrue(fixture.requests[1].raw.indexOf("POST /final HTTP/1.1") == 0);
		Assert.equals("payload", fixture.requests[1].body);
	}

	public function testInvalidContentLengthDispatchesIoError():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\nbad", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/invalid-length');

		fixture.waitDone();

		Assert.equals("Download failed: invalid Content-Length", result.error);
		Assert.isFalse(result.complete);
	}

	public function testConflictingDuplicateContentLengthDispatchesIoError():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nbad", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/conflicting-length');

		fixture.waitDone();

		Assert.equals("Download failed: invalid Content-Length", result.error);
		Assert.isFalse(result.complete);
	}

	public function testMatchingDuplicateContentLengthIsAccepted():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/matching-length');

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.isNull(result.error);
	}

	public function testInvalidChunkTerminatorDispatchesIoError():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nokXX0\r\n\r\n", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/bad-chunk');

		fixture.waitDone();

		Assert.equals("Download failed", result.error);
		Assert.isFalse(result.complete);
	}

	public function testChunkedTransferIgnoresContentLength():Void {
		var fixture = serveRequests(_ -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: nope\r\n\r\n2\r\nok\r\n0\r\n\r\n", 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/chunked-over-length');

		fixture.waitDone();

		Assert.equals("ok", result.data);
		Assert.isNull(result.error);
		Assert.equals(-1, result.progress[0].total);
	}

	private static function loadText(url:String):URLLoaderHttpResult {
		return load(new URLRequest(url));
	}

	private static function load(request:URLRequest):URLLoaderHttpResult {
		request.idleTimeout = 2000;
		var loader = new URLLoader();
		var result:URLLoaderHttpResult = {
			complete: false,
			error: null,
			data: null,
			statuses: [],
			progress: []
		};

		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, (event:HTTPStatusEvent) -> result.statuses.push(event.status));
		loader.addEventListener(ProgressEvent.PROGRESS, (event:ProgressEvent) -> result.progress.push({loaded: event.bytesLoaded, total: event.bytesTotal}));
		loader.addEventListener(Event.COMPLETE, (_:Event) -> {
			result.complete = true;
			result.data = Std.string(loader.data);
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> {
			result.error = event.text;
			result.data = loader.data == null ? null : Std.string(loader.data);
		});

		loader.load(request);
		pumpUntil(() -> result.complete || result.error != null);

		Assert.isTrue(result.complete || result.error != null);
		return result;
	}

	private static function serveRequests(responder:URLLoaderHttpFixtureRequest->String, expectedRequests:Int):URLLoaderHttpFixture {
		var fixture = new URLLoaderHttpFixture(expectedRequests);
		Thread.create(() -> {
			var server = new SysSocket();
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(expectedRequests);
				fixture.port = server.host().port;
				fixture.ready.release();

				for (_ in 0...expectedRequests) {
					var peer:SysSocket = null;
					try {
						peer = server.accept();
						peer.setTimeout(2.0);
						var request = readRequest(peer);
						fixture.requests.push(request);
						peer.output.writeString(responder(request));
						peer.output.flush();
					} catch (error:Dynamic) {
						fixture.error = error;
						break;
					}
					closeQuietly(peer);
				}
			} catch (error:Dynamic) {
				fixture.error = error;
				fixture.ready.release();
			}

			closeQuietly(server);
			fixture.done.release();
		});

		if (!fixture.ready.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture server");
		}
		if (fixture.error != null) {
			Assert.fail("HTTP fixture server failed to start: " + fixture.error);
		}
		return fixture;
	}

	private static function readRequest(peer:SysSocket):URLLoaderHttpFixtureRequest {
		var rawLines:Array<String> = [];
		var headers:Map<String, String> = new Map();
		var firstLine:String = peer.input.readLine();
		rawLines.push(firstLine);
		var firstParts = firstLine.split(" ");
		var target = firstParts.length > 1 ? firstParts[1] : "";
		var contentLength = 0;

		while (true) {
			var line = peer.input.readLine();
			rawLines.push(line);
			if (line == "") {
				break;
			}

			var separator = line.indexOf(":");
			if (separator > 0) {
				var key = StringTools.trim(line.substr(0, separator)).toLowerCase();
				var value = StringTools.trim(line.substr(separator + 1));
				headers.set(key, value);
				if (key == "content-length") {
					contentLength = Std.parseInt(value);
				}
			}
		}

		var body = contentLength > 0 ? peer.input.read(contentLength).toString() : "";
		return {
			raw: rawLines.join("\n") + "\n" + body,
			target: target,
			headers: headers,
			body: body
		};
	}

	private static function response(status:Int, reason:String, headers:Array<String>, body:String):String {
		return 'HTTP/1.1 ${status} ${reason}\r\n' + headers.join("\r\n") + "\r\n\r\n" + body;
	}

	private static function pumpUntil(done:Void->Bool, timeoutSeconds:Float = 2.0):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeoutSeconds;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}

typedef URLLoaderHttpResult = {
	var complete:Bool;
	var error:String;
	var data:String;
	var statuses:Array<Int>;
	var progress:Array<{loaded:UInt, total:UInt}>;
}

typedef URLLoaderHttpFixtureRequest = {
	var raw:String;
	var target:String;
	var headers:Map<String, String>;
	var body:String;
}

private class URLLoaderHttpFixture {
	public var port:Int = 0;
	public var requests:Array<URLLoaderHttpFixtureRequest> = [];
	public var error:Dynamic = null;
	public var ready:Lock = new Lock();
	public var done:Lock = new Lock();
	private var expectedRequests:Int;

	public function new(expectedRequests:Int) {
		this.expectedRequests = expectedRequests;
	}

	public function waitDone():Void {
		if (!done.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture requests");
		}
		if (error != null) {
			Assert.fail("HTTP fixture request failed: " + error);
		}
		Assert.equals(expectedRequests, requests.length);
	}
}
