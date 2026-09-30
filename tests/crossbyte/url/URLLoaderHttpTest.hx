package crossbyte.url;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.http.HTTPBackend;
import crossbyte.http.HTTPBackendRegistry;
import crossbyte.http.HTTPRequestContext;
import crossbyte.http.HTTPVersion;
import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
import utest.Assert;
import crossbyte.test.Require;

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

	public function testTheResponseReachesTheLoaderWithItsHeaders():Void {
		// HTTP_RESPONSE_STATUS was never dispatched, so Retry-After, ETag and
		// Location could not be read at all.
		var fixture = serveRequests(_ -> response(200, "OK", [
			"Content-Length: 2", "ETag: \"abc\"", "Retry-After: 120", "Set-Cookie: a=1; Path=/", "Set-Cookie: b=2; Expires=Wed, 09 Jun 2100 10:18:14 GMT"
		], "ok"), 1);
		var url = 'http://127.0.0.1:${fixture.port}/resource';
		var result = loadText(url);

		fixture.waitDone();

		Assert.equals(1, result.responses.length, "HTTP_RESPONSE_STATUS was not dispatched once");
		if (result.responses.length > 0) {
			var event:HTTPStatusEvent = result.responses[0];
			Assert.equals(200, event.status);
			Assert.equals(url, event.responseURL);
			Assert.isFalse(event.redirected);
			Assert.equals("\"abc\"", __header(event, "etag"));
			Assert.equals("120", __header(event, "retry-after"));
			var cookies = event.responseHeaders.filter(h -> h.name == "set-cookie").map(h -> h.value);
			Assert.equals(2, cookies.length, "the two Set-Cookie fields were not kept apart: " + cookies);
		}
		Assert.isTrue(result.complete);
	}

	public function testARedirectedResponseNamesWhereItCameFrom():Void {
		var fixture = serveRequests(request -> request.target == "/start" ? response(302, "Found", ["Location: /final", "Content-Length: 0"], "")
			: response(200, "OK", ["Content-Length: 4", "X-Served-By: final"], "done"), 2);
		var result = loadText('http://127.0.0.1:${fixture.port}/start');

		fixture.waitDone();

		Assert.equals(1, result.responses.length, "a redirect's own response was reported as the answer");
		if (result.responses.length > 0) {
			Assert.equals(200, result.responses[0].status);
			Assert.isTrue(result.responses[0].redirected);
			Assert.equals('http://127.0.0.1:${fixture.port}/final', result.responses[0].responseURL);
			Assert.equals("final", __header(result.responses[0], "x-served-by"));
		}
	}

	public function testAnErrorResponseIsReportedBeforeTheError():Void {
		var fixture = serveRequests(_ -> response(503, "Service Unavailable", ["Content-Length: 4", "Retry-After: 30"], "busy"), 1);
		var result = loadText('http://127.0.0.1:${fixture.port}/busy');

		fixture.waitDone();

		Assert.equals("HTTP error 503", result.error);
		Assert.equals("busy", result.data);
		Assert.equals(1, result.responses.length);
		if (result.responses.length > 0) {
			Assert.equals("30", __header(result.responses[0], "retry-after"));
		}
	}

	private static function __header(event:HTTPStatusEvent, name:String):Null<String> {
		if (event.responseHeaders == null) {
			return null;
		}
		for (header in event.responseHeaders) {
			if (header.name == name) {
				return header.value;
			}
		}
		return null;
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

		// The cause travels with the message now. It used to be dropped, so a
		// bad chunk size, a truncated chunk and a missing terminator all
		// reached the caller as the same four words.
		var error:String = Require.notNull(result.error);
		Assert.equals(0, error.indexOf("Download failed"), error);
		Assert.isTrue(error.indexOf("Invalid chunk terminator") > 0, error);
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

	public function testTheNextLoadCanStartFromComplete():Void {
		// The loader was still busy while COMPLETE was dispatched, it was
		// freed after the listeners ran, so a listener starting the next
		// load on it was refused with "URLLoader is already loading".
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 2"], "ok"), 2);
		var loader = new URLLoader();
		var events:Array<String> = [];
		var loads:Int = 0;
		loader.addEventListener(Event.COMPLETE, _ -> {
			events.push("complete " + loader.data);
			if (++loads == 1) {
				var next = new URLRequest('http://127.0.0.1:${fixture.port}/second');
				next.idleTimeout = 2000;
				loader.load(next);
			}
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> events.push("error " + event.text));
		var first = new URLRequest('http://127.0.0.1:${fixture.port}/first');
		first.idleTimeout = 2000;
		loader.load(first);

		pumpUntil(() -> events.length >= 2);
		fixture.waitDone();
		Assert.same(["complete ok", "complete ok"], events);
	}

	#if target.threaded
	public function testLoadsReuseTheirThreadsAndStayOffTheRuntime():Void {
		// Every load started a thread of its own and let it end: a hundred
		// loads a second were a hundred thread starts, and on the jvm each
		// thread's selector, never closed, left two sockets open per load.
		// A backend of the test's own, on HTTP/3, which nothing else serves,
		// says which thread each load ran on.
		var backend = new ThreadRecordingBackend();
		HTTPBackendRegistry.register(backend);
		var loader = new URLLoader();
		var completed:Int = 0;
		var failures:Array<String> = [];
		loader.addEventListener(Event.COMPLETE, _ -> completed++);
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> failures.push(event.text));
		try {
			for (i in 0...12) {
				var request = new URLRequest('http://127.0.0.1/n$i');
				request.httpVersion = HTTPVersion.HTTP_3;
				var before:Int = completed + failures.length;
				loader.load(request);
				pumpUntil(() -> completed + failures.length > before);
			}
		} catch (e:Dynamic) {
			HTTPBackendRegistry.unregister(backend);
			throw e;
		}
		HTTPBackendRegistry.unregister(backend);

		Assert.equals(12, completed, failures.join("; "));
		// And off the runtime's thread, where a blocking request, or the
		// name lookup at its start, would stop every socket and timer.
		Assert.equals(0, backend.onRuntime(), "a load ran on the runtime's thread");
		// One thread, or two when the next load is queued in the moment
		// before the thread that finished the last one is waiting again.
		var threads:Int = backend.distinctThreads();
		Assert.isTrue(threads <= 2, '12 loads, one after another, ran on $threads threads');
	}

	// Only where the loader's worker is a thread: elsewhere it runs the load
	// inside load(), so nothing can close it while it is in flight.
	public function testClosingALoadInFlightEndsItQuietly():Void {
		// A server that takes the request and holds it, answering nothing,
		// and notes how its wait for the client ended.
		var ready = new Lock();
		var finished = new Lock();
		// Strings, not Bools. On the jvm a Deque of a basic type answers
		// `pop(false)` on an empty queue with false or 0 rather than null, so
		// a Deque<Bool> here said the request had arrived before it was sent:
		// the loader was closed before its load began, and the server waited
		// in accept() for a client that never came.
		var arrived = new sys.thread.Deque<String>();
		var ended:String = null;
		var port = 0;
		Thread.create(() -> {
			var server = new SysSocket();
			var peer:SysSocket = null;
			try {
				server.bind(new Host("127.0.0.1"), 0);
				server.listen(1);
				port = server.host().port;
				ready.release();
				peer = server.accept();
				// Longer than the test waits for this thread below, so only the
				// client going ends the wait in time.
				peer.setTimeout(5.0);
				readRequest(peer);
				arrived.add("arrived");
				try {
					peer.input.readByte();
					ended = "a byte arrived";
				} catch (_:haxe.io.Eof) {
					ended = "the client went";
				} catch (e:Dynamic) {
					ended = Std.string(e);
				}
			} catch (_:Dynamic) {
				ready.release();
			}
			closeQuietly(peer);
			closeQuietly(server);
			finished.release();
		});
		if (!ready.wait(2.0) || port == 0) {
			Assert.fail("the fixture server did not start");
			return;
		}

		var loader = new URLLoader();
		var events:Array<String> = [];
		loader.addEventListener(Event.COMPLETE, _ -> events.push("complete"));
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> events.push("error: " + event.text));
		var request = new URLRequest('http://127.0.0.1:${port}/held');
		request.idleTimeout = 2000;
		loader.load(request);

		var inFlight = false;
		pumpUntil(() -> inFlight = inFlight || arrived.pop(false) != null);
		if (!inFlight) {
			Assert.fail("the request never reached the server");
			loader.close();
			return;
		}

		// The worker thread is blocked reading. Closing ends that read, and
		// what the thread reports next it reported through the loader's
		// worker field, which close() had just cleared: an access violation
		// on native.
		loader.close();
		var settle = haxe.Timer.stamp() + 0.5;
		pumpUntil(() -> haxe.Timer.stamp() >= settle);

		Assert.same([], events);
		// And the server hears of it now, not when its own wait runs out. The
		// client used to close its socket from the closing thread: on eval
		// that killed the worker with an error nothing could catch, and the
		// reset it caused killed the server's reader too; on Linux a close
		// does not wake the read, so the server waited out the idle timeout.
		Assert.isTrue(finished.wait(2.0), "the server never saw the client go");
		Assert.equals("the client went", ended);

		// And the loader is free for the next load.
		var fixture = serveRequests(_ -> response(200, "OK", ["Content-Length: 2"], "ok"), 1);
		loader.addEventListener(Event.COMPLETE, _ -> events.push("data: " + loader.data));
		var next = new URLRequest('http://127.0.0.1:${fixture.port}/next');
		next.idleTimeout = 2000;
		loader.load(next);
		pumpUntil(() -> events.length >= 2);
		fixture.waitDone();
		Assert.same(["complete", "data: ok"], events);
	}
	#end

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
			progress: [],
			responses: []
		};

		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, (event:HTTPStatusEvent) -> result.statuses.push(event.status));
		loader.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, (event:HTTPStatusEvent) -> result.responses.push(event));
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
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
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

#if target.threaded
/** Answers every HTTP/3 request at once, noting the thread each came on. */
private class ThreadRecordingBackend implements HTTPBackend {
	private final __lock:Mutex = new Mutex();
	private final __threads:Array<Thread> = [];
	private var __onRuntime:Int = 0;

	public function new() {}

	public function supports(version:HTTPVersion):Bool {
		return version == HTTPVersion.HTTP_3;
	}

	public function load(context:HTTPRequestContext):Void {
		var thread:Thread = Thread.current();
		var runtime:Null<CrossByte> = CrossByte.__currentOrNull();
		__lock.acquire();
		__threads.push(thread);
		if (runtime != null) {
			__onRuntime++;
		}
		__lock.release();

		context.onStatus(200);
		context.onHeaders(new Map());
		context.onComplete(Bytes.ofString("ok"));
	}

	public function onRuntime():Int {
		__lock.acquire();
		var count:Int = __onRuntime;
		__lock.release();
		return count;
	}

	public function distinctThreads():Int {
		__lock.acquire();
		var distinct:Array<Thread> = [];
		for (thread in __threads) {
			var seen:Bool = false;
			for (other in distinct) {
				if (other == thread) {
					seen = true;
					break;
				}
			}
			if (!seen) {
				distinct.push(thread);
			}
		}
		__lock.release();
		return distinct.length;
	}
}
#end

typedef URLLoaderHttpResult = {
	var complete:Bool;
	var error:String;
	var data:String;
	var statuses:Array<Int>;
	var progress:Array<{loaded:UInt, total:UInt}>;
	var responses:Array<HTTPStatusEvent>;
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
