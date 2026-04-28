package crossbyte._internal.http;

import crossbyte.http.HTTPBackend;
import crossbyte.http.HTTPBackendRegistry;
import crossbyte.http.HTTPRequestContext;
import crossbyte.url.URL;
import haxe.io.Bytes;
import haxe.exceptions.NotImplementedException;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Thread;
import utest.Assert;

@:access(crossbyte._internal.http.Http)
class HttpTest extends utest.Test {
	public function testValidateHttpVersionOnlyAllowsImplementedVersions():Void {
		Assert.isTrue(Http.validateHttpVersion(HttpVersion.HTTP_1));
		Assert.isTrue(Http.validateHttpVersion(HttpVersion.HTTP_1_1));
		Assert.isFalse(Http.validateHttpVersion(HttpVersion.HTTP_2));
		Assert.isFalse(Http.validateHttpVersion(HttpVersion.HTTP_3));
	}

	public function testConstructorRejectsUnsupportedVersions():Void {
		HTTPBackendRegistry.clear();

		Assert.raises(() -> new Http("http://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_2), NotImplementedException);
		Assert.raises(() -> new Http("http://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_3), NotImplementedException);

		HTTPBackendRegistry.clear();
	}

	public function testRegisteredBackendAllowsHttp2ConstructionAndLoad():Void {
		HTTPBackendRegistry.clear();
		var backend = new FakeHTTP2Backend();
		HTTPBackendRegistry.register(backend);
		var statusCodes:Array<Int> = [];
		var progress:Array<{loaded:Int, total:Int}> = [];
		var completed:Bytes = null;
		var error:String = null;

		var http = new Http("https://example.com/resource", "POST", ["X-Test: yes"], {page: 1}, "text/plain", "body", HttpVersion.HTTP_2, 5000,
			"TestAgent", false);
		http.onStatus = code -> statusCodes.push(code);
		http.onProgress = (loaded:Int, total:Int) -> progress.push({loaded: loaded, total: total});
		http.onComplete = data -> completed = data;
		http.onError = (message:String, ?data:Bytes) -> error = message;

		http.load();

		Assert.isNull(error);
		Assert.notNull(completed);
		Assert.equals("ok", completed.toString());
		Assert.same([200], statusCodes);
		Assert.equals(2, progress[progress.length - 1].loaded);
		Assert.equals(2, progress[progress.length - 1].total);
		Assert.notNull(backend.lastContext);
		Assert.equals("https://example.com/resource", backend.lastContext.url);
		Assert.equals("POST", backend.lastContext.method);
		Assert.equals(HttpVersion.HTTP_2, backend.lastContext.version);
		Assert.equals("X-Test: yes", backend.lastContext.headers[0]);
		Assert.equals("text/plain", backend.lastContext.contentType);
		Assert.equals("body", backend.lastContext.data);
		Assert.equals(5000, backend.lastContext.timeout);
		Assert.equals("TestAgent", backend.lastContext.userAgent);
		Assert.isFalse(backend.lastContext.followRedirects);

		HTTPBackendRegistry.clear();
	}

	public function testMostRecentlyRegisteredBackendWins():Void {
		HTTPBackendRegistry.clear();
		var first = new FakeHTTP2Backend("first");
		var second = new FakeHTTP2Backend("second");

		HTTPBackendRegistry.register(first);
		HTTPBackendRegistry.register(second);

		var http = new Http("https://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_2);
		var completed:Bytes = null;
		http.onComplete = data -> completed = data;

		http.load();

		Assert.notNull(completed);
		Assert.equals("second", completed.toString());
		Assert.isNull(first.lastContext);
		Assert.notNull(second.lastContext);

		HTTPBackendRegistry.clear();
	}

	public function testUnregisterBackendRemovesHttp2Support():Void {
		HTTPBackendRegistry.clear();
		var backend = new FakeHTTP2Backend();

		HTTPBackendRegistry.register(backend);
		Assert.isTrue(HTTPBackendRegistry.isRegistered(HttpVersion.HTTP_2));
		Assert.isTrue(HTTPBackendRegistry.unregister(backend));
		Assert.isFalse(HTTPBackendRegistry.isRegistered(HttpVersion.HTTP_2));
		Assert.raises(() -> new Http("https://example.com/", "GET", null, null, null, null, HttpVersion.HTTP_2), NotImplementedException);

		HTTPBackendRegistry.clear();
	}

	public function testResolveLocationHandlesAbsoluteAndRootRelativeUrls():Void {
		var http = new Http("http://example.com/dir/page");
		var base = new URL("http://example.com/dir/page");

		Assert.equals("https://other.example/path?q=1", http.__resolveLocation(base, "https://other.example/path?q=1"));
		Assert.equals("http://example.com/root?x=1", http.__resolveLocation(base, "/root?x=1"));
	}

	public function testResolveLocationKeepsNonDefaultPortAndRelativeDirectory():Void {
		var http = new Http("http://example.com:8080/dir/page");
		var base = new URL("http://example.com:8080/dir/page");

		Assert.equals("http://example.com:8080/dir/next", http.__resolveLocation(base, "next"));
		Assert.equals("http://example.com:8080/dir/sub/next?x=1", http.__resolveLocation(base, "sub/next?x=1"));
	}

	public function testBuildQueryEncodesScalarsArraysAndNestedObjects():Void {
		var http = new Http("http://example.com/");
		var query = http.__buildQuery({
			search: "hello world",
			page: 2,
			active: true,
			tags: ["one", "two"],
			filter: {
				kind: "exact",
				limit: 3
			},
			empty: null
		});
		var parts = query.split("&");

		Assert.isTrue(parts.indexOf("search=hello%20world") >= 0);
		Assert.isTrue(parts.indexOf("page=2") >= 0);
		Assert.isTrue(parts.indexOf("active=true") >= 0);
		Assert.isTrue(parts.indexOf("tags%5B%5D=one") >= 0);
		Assert.isTrue(parts.indexOf("tags%5B%5D=two") >= 0);
		Assert.isTrue(parts.indexOf("filter%5Bkind%5D=exact") >= 0);
		Assert.isTrue(parts.indexOf("filter%5Blimit%5D=3") >= 0);
		Assert.equals(-1, parts.indexOf("empty=null"));
	}

	public function testLoadReadsFixedLengthBodyAndSendsDefaultHeaders():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
		var http = new Http('http://127.0.0.1:${fixture.port}/fixed?existing=1');
		var statusCodes:Array<Int> = [];
		var progress:Array<{loaded:Int, total:Int}> = [];
		var completed:Bytes = null;
		var error:String = null;

		http.onStatus = code -> statusCodes.push(code);
		http.onProgress = (loaded:Int, total:Int) -> progress.push({loaded: loaded, total: total});
		http.onComplete = data -> completed = data;
		http.onError = (message:String, ?data:Bytes) -> error = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(error);
		Assert.notNull(completed);
		Assert.equals("hello", completed.toString());
		Assert.same([200], statusCodes);
		Assert.equals(0, progress[0].loaded);
		Assert.equals(5, progress[0].total);
		Assert.equals(5, progress[progress.length - 1].loaded);
		Assert.equals(5, progress[progress.length - 1].total);
		Assert.isTrue(fixture.request.indexOf("GET /fixed?existing=1 HTTP/1.1") == 0);
		Assert.isTrue(fixture.request.indexOf("Host: 127.0.0.1:" + fixture.port) >= 0);
		Assert.isTrue(fixture.request.indexOf("Connection: close") >= 0);
		Assert.isTrue(fixture.request.indexOf("Accept-Encoding: identity") >= 0);
	}

	public function testLoadReadsChunkedBody():Void {
		var fixture = serveOnce("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/chunked');
		var completed:Bytes = null;
		var progress:Array<{loaded:Int, total:Int}> = [];

		http.onProgress = (loaded:Int, total:Int) -> progress.push({loaded: loaded, total: total});
		http.onComplete = data -> completed = data;

		http.load();
		fixture.waitDone();

		Assert.notNull(completed);
		Assert.equals("hello world", completed.toString());
		Assert.equals(-1, progress[0].total);
		Assert.equals(11, progress[progress.length - 1].loaded);
		Assert.equals(-1, progress[progress.length - 1].total);
	}

	public function testLoadReportsHttpErrorsWithResponseData():Void {
		var fixture = serveOnce("HTTP/1.1 404 Not Found\r\nContent-Length: 7\r\n\r\nmissing");
		var http = new Http('http://127.0.0.1:${fixture.port}/missing');
		var completeCalled = false;
		var errorMessage:String = null;
		var errorData:Bytes = null;

		http.onComplete = _ -> completeCalled = true;
		http.onError = (message:String, ?data:Bytes) -> {
			errorMessage = message;
			errorData = data;
		}

		http.load();
		fixture.waitDone();

		Assert.isFalse(completeCalled);
		Assert.equals("HTTP error 404", errorMessage);
		Assert.notNull(errorData);
		Assert.equals("missing", errorData.toString());
	}

	public function testLoadSerializesPostFormData():Void {
		var fixture = serveOnce("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
		var http = new Http('http://127.0.0.1:${fixture.port}/submit', "POST", ["X-Test: yes"], {
			field: "a b",
			ok: false
		});
		var completed:Bytes = null;
		var error:String = null;

		http.onComplete = data -> completed = data;
		http.onError = (message:String, ?data:Bytes) -> error = message;

		http.load();
		fixture.waitDone();

		Assert.isNull(error);
		Assert.notNull(completed);
		Assert.equals(0, completed.length);
		Assert.isTrue(fixture.request.indexOf("POST /submit HTTP/1.1") == 0);
		Assert.isTrue(fixture.request.indexOf("X-Test: yes") >= 0);
		Assert.isTrue(fixture.request.indexOf("Content-Type: application/x-www-form-urlencoded; charset=utf-8") >= 0);
		Assert.isTrue(fixture.request.indexOf("content-length: ") >= 0);
		Assert.isTrue(fixture.request.indexOf("field=a%20b") >= 0);
		Assert.isTrue(fixture.request.indexOf("ok=false") >= 0);
	}

	private static function serveOnce(response:String):OneShotHttpServer {
		var fixture = new OneShotHttpServer();
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				fixture.port = server.host().port;
				fixture.ready.release();

				peer = server.accept();
				peer.setTimeout(2.0);
				fixture.request = readRequest(peer);
				peer.output.writeString(response);
				peer.output.flush();
			} catch (e:Dynamic) {
				fixture.error = e;
				fixture.ready.release();
			}

			closeQuietly(peer);
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

	private static function readRequest(peer:SysSocket):String {
		var lines:Array<String> = [];
		var contentLength = 0;
		while (true) {
			var line = peer.input.readLine();
			lines.push(line);
			if (line == "") {
				break;
			}

			var separator = line.indexOf(":");
			if (separator > 0 && line.substr(0, separator).toLowerCase() == "content-length") {
				contentLength = Std.parseInt(StringTools.trim(line.substr(separator + 1)));
			}
		}

		var body = contentLength > 0 ? peer.input.read(contentLength).toString() : "";
		return lines.join("\n") + "\n" + body;
	}

	private static function closeQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}

private class OneShotHttpServer {
	public var port:Int = 0;
	public var request:String = "";
	public var error:Dynamic = null;
	public var ready:Lock = new Lock();
	public var done:Lock = new Lock();

	public function new() {}

	public function waitDone():Void {
		if (!done.wait(2.0)) {
			Assert.fail("Timed out waiting for HTTP fixture request");
		}
		if (error != null) {
			Assert.fail("HTTP fixture request failed: " + error);
		}
	}
}

private class FakeHTTP2Backend implements HTTPBackend {
	public var lastContext:HTTPRequestContext;
	private var response:String;

	public function new(response:String = "ok") {
		this.response = response;
	}

	public function supports(version:crossbyte.http.HTTPVersion):Bool {
		return version == HttpVersion.HTTP_2;
	}

	public function load(context:HTTPRequestContext):Void {
		lastContext = context;
		var bytes = Bytes.ofString(response);
		context.onStatus(200);
		context.onProgress(0, bytes.length);
		context.onProgress(bytes.length, bytes.length);
		context.onComplete(bytes);
	}
}
