package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.net.RateLimiter;
import crossbyte.net.SpreadSupport;
import crossbyte.url.URLRequestHeader;
import utest.Assert;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Thread;
#end

using StringTools;

/**
	A request answered from a thread other than the runtime serving its
	connection, as a server that hands requests to a worker pool answers
	them: `respond`, `beginResponse` and its stream, and `abort` called on the
	worker, without a round trip of its own, over HTTP/1.1 and HTTP/2. Also
	what such a server needs to say for one response: `Connection: close`,
	and `Cache-Control: no-transform` to leave a body as it is.
**/
@:access(crossbyte.core.CrossByte)
class HTTPAnswerFromAnotherThreadTest extends utest.Test {
	#if target.threaded
	private static inline var WAIT:Float = 10.0;

	/**
		A server on a runtime of its own whose middleware hands each request
		to one worker thread, which answers it with `answer`.
	**/
	private static function __serve(answer:HTTPRequestHandler->Void, ?configure:HTTPServerConfig->Void):Serving {
		var runtime:CrossByte = SpreadSupport.runtime();
		// One request per item; an empty one stops the worker (the jvm's Deque holds no null).
		var work:Deque<Array<HTTPRequestHandler>> = new Deque();
		var stopped:Lock = new Lock();
		Thread.create(() -> {
			while (true) {
				var item:Array<HTTPRequestHandler> = work.pop(true);
				if (item.length == 0) {
					break;
				}
				try {
					answer(item[0]);
				} catch (error:Dynamic) {
					trace("worker: " + error);
				}
			}
			stopped.release();
		});
		var server:HTTPServer = SpreadSupport.on(runtime, () -> {
			var config = new HTTPServerConfig("127.0.0.1", 0);
			config.rateLimiter = new RateLimiter(1000000, 1.0);
			if (configure != null) {
				configure(config);
			}
			config.middleware.push(function(handler:HTTPRequestHandler, ?next:Dynamic->Void):Void {
				work.add([handler]);
			});
			return new HTTPServer(config);
		});
		return {
			server: server,
			runtime: runtime,
			stop: () -> {
				work.add([]);
				stopped.wait(WAIT);
				SpreadSupport.on(runtime, () -> server.close());
				SpreadSupport.stop([runtime]);
			}
		};
	}

	/**
		Answered whole from the worker: each request on a kept-alive
		connection gets its own body, framed by its length rather than
		chunked, and the connection carries the next. What the worker reads
		of the request (its headers, its version) is the request's.
	**/
	@:timeout(30000)
	public function testAWorkerAnswersWithRespond():Void {
		var seen:Deque<String> = new Deque();
		var serving = __serve(handler -> {
			var headers = handler.getAllHeaders();
			seen.add(handler.httpVersion + " " + headers.get("x-probe"));
			handler.respond(200, "text/plain", "answered " + handler.requestPath);
		});

		var client:sys.net.Socket = SpreadSupport.connect(serving.server.localPort);
		for (n in 0...3) {
			client.output.writeString('GET /r$n HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Probe: p$n\r\n\r\n');
			client.output.flush();
			var reply = __reply(client);
			Assert.equals(200, reply.status, 'request $n was not answered');
			Assert.equals('answered /r$n', reply.body);
			Assert.equals(Std.string('answered /r$n'.length), reply.headers.get("content-length"), "a whole body went out without its length");
			Assert.isNull(reply.headers.get("transfer-encoding"));
			Assert.equals('HTTP/1.1 p$n', seen.pop(false), "the worker read another request's fields");
		}

		client.close();
		serving.stop();
	}

	/**
		Written as it goes from the worker: the head, every write and the end
		arrive in order, as a chunked body the client reads whole, and the
		connection carries the next request.
	**/
	@:timeout(30000)
	public function testAWorkerStreamsAResponse():Void {
		var serving = __serve(handler -> {
			var stream = handler.beginResponse(200, "text/plain");
			for (i in 0...5) {
				stream.writeText('piece $i\n');
			}
			stream.end();
		});

		var client:sys.net.Socket = SpreadSupport.connect(serving.server.localPort);
		for (n in 0...2) {
			client.output.writeString('GET /s$n HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
			client.output.flush();
			var reply = __reply(client);
			Assert.equals(200, reply.status, 'streamed request $n was not answered');
			Assert.equals("chunked", reply.headers.get("transfer-encoding"));
			Assert.equals("piece 0\npiece 1\npiece 2\npiece 3\npiece 4\n", reply.body);
		}

		client.close();
		serving.stop();
	}

	/**
		A call made while its request is served, which reaches the runtime
		only after that request was answered, does nothing: it does not answer
		the connection's next request, pipelined behind it and being served
		by then. Two answers to the first request are handed over while the
		runtime is busy; the first answers it, the second is dropped, and the
		next request gets its own answer.
	**/
	@:timeout(30000)
	public function testAnAnswerArrivingAfterItsRequestEndedIsDropped():Void {
		var runtime:CrossByte = SpreadSupport.runtime();
		var handed:Deque<String> = new Deque();
		var held:Array<HTTPRequestHandler> = [];
		var server:HTTPServer = SpreadSupport.on(runtime, () -> {
			var config = new HTTPServerConfig("127.0.0.1", 0);
			config.middleware.push(function(handler:HTTPRequestHandler, ?next:Dynamic->Void):Void {
				// Neither answered here: both are left to this test's thread.
				held[0] = handler;
				handed.add(handler.requestPath);
			});
			return new HTTPServer(config);
		});

		var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
		// Pipelined: the second is served as soon as the first is answered.
		client.output.writeString("GET /first HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nGET /second HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
		client.output.flush();
		Assert.equals("/first", handed.pop(true));
		var handler:HTTPRequestHandler = held[0];

		// Both made while the first is being served, and run after the
		// runtime is free again, in order: the first answers it, and by the
		// time the second runs the pipelined request is being served.
		var stall:Lock = new Lock();
		runtime.post(() -> stall.wait(WAIT));
		handler.respond(200, "text/plain", "first");
		handler.respond(200, "text/plain", "a second answer to the first");
		stall.release();

		Assert.equals("first", __reply(client).body);
		Assert.equals("/second", handed.pop(true));
		crossbyte.sys.System.sleep(0.1);
		handler.respond(200, "text/plain", "second");
		Assert.equals("second", __reply(client).body, "an answer handed over for the first request answered the second");

		client.close();
		SpreadSupport.on(runtime, () -> server.close());
		SpreadSupport.stop([runtime]);
	}

	/**
		A producer on the worker is told when the client falls behind and
		when it has room again: writes answer false once a client reading
		nothing has the watermark waiting, `onDrain` comes on the runtime once
		it reads, and the body arrives whole.
	**/
	@:timeout(60000)
	public function testAWorkerIsToldOfRoomByOnDrain():Void {
		var refused:Lock = new Lock();
		var drained:Lock = new Lock();
		var drainThread:Deque<Bool> = new Deque();
		var written:Int = 0;
		var piece:ByteArray = new ByteArray();
		for (i in 0...65536) {
			piece.writeByte(65 + (i % 26));
		}
		var serving:Null<Serving> = null;
		serving = __serve(handler -> {
			var stream = handler.beginResponse(200, "application/octet-stream");
			stream.onDrain = () -> {
				drainThread.add(serving.runtime.__isOwnThread());
				drained.release();
			};
			var sawRefusal:Bool = false;
			// Bounded: a client reading nothing stops the producer well before.
			for (i in 0...512) {
				var room = stream.write(piece);
				written += piece.length;
				if (!room) {
					sawRefusal = true;
					break;
				}
			}
			refused.release();
			if (sawRefusal && drained.wait(WAIT)) {
				stream.write(piece);
				written += piece.length;
			}
			stream.end();
		}, config -> config.maxOutputBufferSize = 64 * 1024 * 1024);

		var client:sys.net.Socket = SpreadSupport.connect(serving.server.localPort);
		client.output.writeString("GET /big HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
		client.output.flush();
		Assert.isTrue(refused.wait(WAIT), "the worker never stopped writing");
		var reply = __reply(client);
		Assert.equals(200, reply.status);
		Assert.isTrue(written < 512 * 65536, "a client reading nothing never made a write answer false");
		Assert.equals(written, reply.body.length, "the body did not arrive whole");
		Assert.isTrue(drainThread.pop(false) == true, "onDrain was not called on the connection's runtime");

		client.close();
		serving.stop();
	}

	/** `abort` from the worker: the connection closes with no response. **/
	@:timeout(30000)
	public function testAWorkerAborts():Void {
		var serving = __serve(handler -> handler.abort());
		var client:sys.net.Socket = SpreadSupport.connect(serving.server.localPort);
		client.output.writeString("GET /a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
		client.output.flush();
		Assert.isTrue(SpreadSupport.ended(client), "an aborted request's connection stayed open");
		client.close();
		serving.stop();
	}

	/**
		`Connection: close` on a response closes the connection after it, as
		in Go's and Node's servers, and the head says so once.
	**/
	@:timeout(30000)
	public function testConnectionCloseOnAResponseClosesTheConnection():Void {
		var serving = __serve(handler -> handler.respond(200, "text/plain", "bye", [new URLRequestHeader("Connection", "close")]));
		var client:sys.net.Socket = SpreadSupport.connect(serving.server.localPort);
		client.output.writeString("GET /c HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
		client.output.flush();
		var reply = __reply(client);
		Assert.equals("bye", reply.body);
		Assert.equals(1, reply.connectionLines, "the head carried " + reply.connectionLines + " Connection headers");
		Assert.equals("close", reply.headers.get("connection"));
		Assert.isTrue(SpreadSupport.ended(client), "the connection stayed open after a response that said close");
		client.close();
		serving.stop();
	}

	/** `Cache-Control: no-transform` leaves a body as given, for a client that takes gzip. **/
	@:timeout(30000)
	public function testNoTransformLeavesABodyUncompressed():Void {
		var text:String = [for (_ in 0...200) "compressible "].join("");
		var serving = __serve(handler -> {
			var headers = handler.requestPath == "/kept" ? [new URLRequestHeader("Cache-Control", "no-transform")] : null;
			handler.respond(200, "text/plain", text, headers);
		}, config -> config.compression.enabled = true);
		var client:sys.net.Socket = SpreadSupport.connect(serving.server.localPort);
		client.output.writeString("GET /squeezed HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: gzip\r\n\r\n");
		client.output.flush();
		var squeezed = __reply(client);
		Assert.equals("gzip", squeezed.headers.get("content-encoding"), "the control was not compressed, so this proves nothing");
		client.output.writeString("GET /kept HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: gzip\r\n\r\n");
		client.output.flush();
		var kept = __reply(client);
		Assert.isNull(kept.headers.get("content-encoding"), "a no-transform response was compressed");
		Assert.equals(text, kept.body);
		client.close();
		serving.stop();
	}

	/** Over HTTP/2: answered from the worker, on each stream. **/
	@:timeout(30000)
	public function testAWorkerAnswersOverHttp2():Void {
		var serving = __serve(handler -> handler.respond(200, "text/plain", handler.httpVersion + " " + handler.requestPath),
			config -> config.http2Enabled = true);
		var client:sys.net.Socket = SpreadSupport.connect(serving.server.localPort);
		var h2 = new HttpWireH2(client);
		for (n in 0...3) {
			Assert.equals('HTTP/2 /h$n', h2.get('/h$n'), 'stream $n was not answered from the worker');
		}
		client.close();
		serving.stop();
	}

	/**
		The next response on `client`: status, headers by lower-case name, the
		body (by length, by chunks, or to the close), and how many
		`Connection` lines the head had.
	**/
	private static function __reply(client:sys.net.Socket):{status:Int, headers:Map<String, String>, body:String, connectionLines:Int} {
		var head:String = "";
		var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);
		try {
			while (!head.endsWith("\r\n\r\n") && head.length < 16384) {
				client.input.readBytes(one, 0, 1);
				head += String.fromCharCode(one.get(0));
			}
		} catch (_:Dynamic) {}
		var status:Int = head.startsWith("HTTP/1.1 ") ? Std.parseInt(head.substr(9, 3)) : 0;
		var headers:Map<String, String> = new Map();
		var connectionLines:Int = 0;
		for (line in head.split("\r\n")) {
			var colon:Int = line.indexOf(":");
			if (colon > 0) {
				var name:String = line.substr(0, colon).toLowerCase();
				if (name == "connection") {
					connectionLines++;
				}
				headers.set(name, StringTools.trim(line.substr(colon + 1)));
			}
		}
		var body:StringBuf = new StringBuf();
		if (headers.get("transfer-encoding") == "chunked") {
			while (true) {
				var size:Int = crossbyte.utils.IntParse.hex(__line(client));
				if (size <= 0) {
					__line(client);
					break;
				}
				body.add(SpreadSupport.read(client, size));
				__line(client);
			}
		} else if (headers.exists("content-length")) {
			var length:Int = Std.parseInt(headers.get("content-length"));
			if (length > 0) {
				body.add(SpreadSupport.read(client, length));
			}
		}
		return {status: status, headers: headers, body: body.toString(), connectionLines: connectionLines};
	}

	private static function __line(client:sys.net.Socket):String {
		var line:String = "";
		var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);
		try {
			while (!line.endsWith("\r\n")) {
				client.input.readBytes(one, 0, 1);
				line += String.fromCharCode(one.get(0));
			}
		} catch (_:Dynamic) {}
		return line.substr(0, line.length - 2);
	}
	#end
}

#if target.threaded
private typedef Serving = {server:HTTPServer, runtime:CrossByte, stop:Void->Void};

/** HTTP/2 by prior knowledge, as `H2Wire` in HTTPServerSpreadTest. **/
private typedef HttpWireH2 = crossbyte.http.HTTPServerSpreadTest.H2Wire;
#end
