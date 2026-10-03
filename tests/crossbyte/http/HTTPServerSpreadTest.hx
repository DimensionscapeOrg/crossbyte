package crossbyte.http;

import crossbyte.core.CrossByte;
import crossbyte.net.Arrival;
import crossbyte.net.RateLimiter;
import crossbyte.net.SpreadSupport;
import utest.Assert;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Thread;
#end

using StringTools;

/**
	An `HTTPServer` spread over several runtimes: every request answered on
	the runtime its connection was handed to, over HTTP/1.1 and HTTP/2, with
	`maxConnections`, the rate limiter, the metrics and `drain()` holding
	for the server as a whole.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.ServerSocket)
@:access(crossbyte.http.HTTPServer)
class HTTPServerSpreadTest extends utest.Test {
	#if target.threaded
	private static inline var WAIT:Float = 10.0;

	/** A configuration whose one middleware answers `/who` and notes where it ran. **/
	private static function __config(seen:Deque<Arrival>):HTTPServerConfig {
		var config = new HTTPServerConfig("127.0.0.1", 0);
		config.rateLimiter = new RateLimiter(1000000, 1.0);
		config.middleware.push(function(handler:HTTPRequestHandler, ?next:Dynamic->Void):Void {
			seen.add(new Arrival(CrossByte.__currentOrNull(), Thread.current(), null));
			handler.respond(200, "text/plain", "hello " + handler.requestPath);
		});
		return config;
	}

	@:timeout(30000)
	public function testRequestsAreAnsweredOnTheirConnectionsRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.runtimes = [first, second];
			return new HTTPServer(config);
		});

		var expected:Array<CrossByte> = [first, second, first, second];
		var clients:Array<sys.net.Socket> = [];
		for (i in 0...4) {
			var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
			clients.push(client);
			// Three requests on one kept-alive connection: each on its runtime.
			for (n in 0...3) {
				var answer = HttpWire.get(client, '/c$i/$n');
				Assert.equals(200, answer.status, 'request $n on connection $i was not answered');
				Assert.equals('hello /c$i/$n', answer.body);
				var where:Null<Arrival> = SpreadSupport.pop(seen, WAIT);
				Assert.isTrue(where != null && where.runtime == expected[i] && where.thread == expected[i].__ownerThread,
					'request $n on connection $i ran off its connection\'s runtime');
			}
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.activeConnections == 4, WAIT), 'activeConnections is ${server.activeConnections}, not 4');

		SpreadSupport.closeAll(clients);
		Assert.isTrue(SpreadSupport.waitFor(() -> server.activeConnections == 0, WAIT), 'activeConnections is ${server.activeConnections} once every client left');
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/** HTTP/2 over cleartext, by prior knowledge: each connection's streams on its runtime. **/
	@:timeout(30000)
	public function testHttp2ConnectionsAreServedOnTheirRuntimes():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.http2Enabled = true;
			config.runtimes = [first, second];
			return new HTTPServer(config);
		});

		var expected:Array<CrossByte> = [first, second];
		var clients:Array<sys.net.Socket> = [];
		for (i in 0...2) {
			var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
			clients.push(client);
			var h2 = new H2Wire(client);
			for (n in 0...3) {
				var body:Null<String> = h2.get('/h$i/$n');
				Assert.equals('hello /h$i/$n', body, 'stream $n on HTTP/2 connection $i was not answered');
				var where:Null<Arrival> = SpreadSupport.pop(seen, WAIT);
				Assert.isTrue(where != null && where.runtime == expected[i] && where.thread == expected[i].__ownerThread,
					'stream $n on HTTP/2 connection $i ran off its connection\'s runtime');
			}
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.activeConnections == 2, WAIT));

		SpreadSupport.closeAll(clients);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		`maxConnections` is every runtime's connections together: past it a
		connection is refused on whichever runtime it landed on.
	**/
	@:timeout(30000)
	public function testMaxConnectionsCountsEveryRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.maxConnections = 3;
			config.runtimes = [first, second];
			return new HTTPServer(config);
		});

		var clients:Array<sys.net.Socket> = [];
		var statuses:Array<Int> = [];
		for (i in 0...5) {
			var client = SpreadSupport.connect(server.localPort);
			clients.push(client);
			statuses.push(HttpWire.get(client, '/n$i').status);
		}

		// A refusal is a 503, or, when the server's close lands on the
		// request it never read, a reset that loses the 503 on its way.
		Assert.same([200, 200, 200], statuses.slice(0, 3), "the connections within the limit were not all served: " + statuses);
		for (i in 3...5) {
			Assert.isTrue(statuses[i] == 503 || statuses[i] == 0, 'connection $i past the limit across the runtimes was served: $statuses');
		}
		Assert.equals(3, server.activeConnections);

		// One goes, and there is room for one more, on either runtime.
		clients[0].close();
		Assert.isTrue(SpreadSupport.waitFor(() -> server.activeConnections == 2, WAIT));
		var again = SpreadSupport.connect(server.localPort);
		clients.push(again);
		Assert.equals(200, HttpWire.get(again, "/again").status, "a place freed on one runtime was not taken");

		SpreadSupport.closeAll(clients);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		The rate limiter keeps one budget per client across every runtime:
		a client whose connections land on two runtimes gets the budget
		once, not once per runtime.
	**/
	@:timeout(30000)
	public function testTheRateLimiterKeepsOneBudgetAcrossRuntimes():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();
		var limiter:RateLimiter = new RateLimiter(6, 3600.0);

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.rateLimiter = limiter;
			config.runtimes = [first, second];
			return new HTTPServer(config);
		});
		Assert.isTrue(Std.isOfType(server.__config.rateLimiter, crossbyte._internal.http.SharedRateLimiter), "the limiter was not given a lock");
		Assert.isTrue((cast server.__config.rateLimiter : crossbyte._internal.http.SharedRateLimiter).inner == limiter);

		// A connection each, so they alternate between the two runtimes; a
		// refusal ends its connection.
		var ok:Int = 0;
		var limited:Int = 0;
		var clients:Array<sys.net.Socket> = [];
		for (n in 0...12) {
			var client = SpreadSupport.connect(server.localPort);
			clients.push(client);
			var status:Int = HttpWire.get(client, '/r$n').status;
			if (status == 200) {
				ok++;
			} else if (status == 429) {
				limited++;
			}
		}
		Assert.equals(6, ok, "the budget was spent more than once across the runtimes");
		Assert.equals(6, limited);

		SpreadSupport.closeAll(clients);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		`drain()` closes what is idle on every runtime, finishes on the
		server's runtime once each has drained, and exits the runtimes
		`runtimeCount` made.
	**/
	@:timeout(30000)
	public function testDrainCoversEveryRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();
		var drained:Deque<String> = new Deque();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.runtimeCount = 2;
			return new HTTPServer(config);
		});
		var made:Array<CrossByte> = server.runtimes;
		Assert.equals(2, made.length);

		var clients:Array<sys.net.Socket> = [];
		for (i in 0...4) {
			var client = SpreadSupport.connect(server.localPort);
			clients.push(client);
			Assert.equals(200, HttpWire.get(client, '/d$i').status);
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.activeConnections == 4, WAIT));

		// From this thread: handed to the server's runtime.
		server.drain(5.0, () -> drained.add(SpreadSupport.where(acceptor)));

		Assert.equals("own", SpreadSupport.pop(drained, WAIT), "drain() did not finish on the server's runtime");
		for (i in 0...clients.length) {
			Assert.isTrue(SpreadSupport.ended(clients[i]), 'connection $i was left open by drain()');
		}
		Assert.equals(0, server.activeConnections);
		Assert.isFalse(server.listening);
		Assert.isTrue(SpreadSupport.waitFor(() -> made[0].__didExit && made[1].__didExit, WAIT), "the runtimes made for the server outlived its drain");

		SpreadSupport.closeAll(clients);
		SpreadSupport.stop([acceptor]);
	}

	/**
		Many clients at once, HTTP/1.1 and HTTP/2 together over keep-alive
		connections, against a server on four runtimes: every request gets
		its own answer and nothing else, every runtime serves some, and the
		counts come back to nothing once the clients have gone.
	**/
	@:timeout(90000)
	public function testConcurrentClientsAreEachAnsweredCorrectly():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var workers:Array<CrossByte> = [for (_ in 0...4) SpreadSupport.runtime()];
		var seen:Deque<Arrival> = new Deque();
		var registry = new crossbyte.metrics.Metrics();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.http2Enabled = true;
			config.keepAliveMaxRequests = 0;
			config.metrics = registry;
			config.runtimes = workers;
			return new HTTPServer(config);
		});

		var plainClients:Int = 8;
		var http2Clients:Int = 4;
		var requests:Int = 40;
		var failures:Deque<String> = new Deque();
		var finished:Deque<Bool> = new Deque();
		for (c in 0...plainClients + http2Clients) {
			Thread.create(() -> {
				try {
					var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
					var h2:Null<H2Wire> = c >= plainClients ? new H2Wire(client) : null;
					for (n in 0...requests) {
						var path:String = '/k$c/$n';
						var body:Null<String> = h2 != null ? h2.get(path) : HttpWire.get(client, path).body;
						if (body != "hello " + path) {
							failures.add('client $c request $n got "$body"');
						}
					}
					client.close();
				} catch (error:Dynamic) {
					failures.add('client $c threw ' + Std.string(error));
				}
				finished.add(true);
			});
		}
		for (_ in 0...plainClients + http2Clients) {
			SpreadSupport.pop(finished, 60.0);
		}

		var problems:Array<String> = [];
		var problem:Null<String> = failures.pop(false);
		while (problem != null && problems.length < 10) {
			problems.push(problem);
			problem = failures.pop(false);
		}
		Assert.same([], problems, "a concurrent client was answered wrongly: " + problems.join("; "));

		var served:Array<Int> = [for (_ in workers) 0];
		var arrival:Null<Arrival> = seen.pop(false);
		var total:Int = 0;
		while (arrival != null) {
			var index:Int = workers.indexOf(arrival.runtime);
			if (index >= 0 && arrival.thread == workers[index].__ownerThread) {
				served[index]++;
			}
			total++;
			arrival = seen.pop(false);
		}
		var expected:Int = (plainClients + http2Clients) * requests;
		Assert.equals(expected, total, "requests were answered other than once each: " + served);
		for (i in 0...served.length) {
			Assert.isTrue(served[i] > 0, 'runtime $i served none of the requests: $served');
		}
		Assert.equals(expected, served[0] + served[1] + served[2] + served[3], "a request ran off its connection's runtime");
		Assert.isTrue(registry.toPrometheus().indexOf('http_requests_total{status="2xx"} $expected') >= 0, "the requests counted were not every runtime's");
		Assert.isTrue(SpreadSupport.waitFor(() -> server.activeConnections == 0, WAIT), 'activeConnections is ${server.activeConnections} once every client left');

		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop(workers.concat([acceptor]));
	}

	/**
		`drain()` with a request in flight on each runtime: each is answered
		in full, on its runtime, before its connection goes, and the drain
		finishes once both have.
	**/
	@:timeout(30000)
	public function testDrainLetsEachRuntimesRequestsFinish():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var started:Deque<Arrival> = new Deque();
		var drained:Deque<String> = new Deque();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = new HTTPServerConfig("127.0.0.1", 0);
			config.runtimes = [first, second];
			config.middleware.push(function(handler:HTTPRequestHandler, ?next:Dynamic->Void):Void {
				started.add(new Arrival(CrossByte.__currentOrNull(), Thread.current(), null));
				// Answered a little later, from a timer on this runtime.
				crossbyte.Timer.setTimeout(0.5, () -> handler.respond(200, "text/plain", "slow " + handler.requestPath));
			});
			return new HTTPServer(config);
		});

		var clients:Array<sys.net.Socket> = [for (_ in 0...2) SpreadSupport.connect(server.localPort)];
		for (i in 0...2) {
			clients[i].output.writeString('GET /slow$i HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
			clients[i].output.flush();
		}
		var where:Array<CrossByte> = [];
		for (_ in 0...2) {
			var arrival = SpreadSupport.pop(started, WAIT);
			if (arrival != null) {
				where.push(arrival.runtime);
			}
		}
		Assert.isTrue(where.length == 2 && where.indexOf(first) >= 0 && where.indexOf(second) >= 0, "the requests in flight were not on both runtimes");

		SpreadSupport.on(acceptor, () -> {
			server.drain(5.0, () -> drained.add(SpreadSupport.where(acceptor)));
			return null;
		});

		for (i in 0...2) {
			var answer = HttpWire.getReply(clients[i]);
			Assert.equals(200, answer.status, 'the request in flight on connection $i was not answered through the drain');
			Assert.equals('slow /slow$i', answer.body);
			Assert.isTrue(SpreadSupport.ended(clients[i]), 'connection $i stayed open after its answer in the drain');
		}
		Assert.equals("own", SpreadSupport.pop(drained, WAIT), "drain() did not finish on the server's runtime");
		Assert.equals(0, server.activeConnections);

		SpreadSupport.closeAll(clients);
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		A server on one runtime, drained from another thread: the drain is
		handed to the server's runtime, as `ServerWebSocket.drain()` hands
		its own over, and finishes there. It ran on the calling thread,
		closing the runtime's connections and calling back from there.
	**/
	@:timeout(30000)
	public function testDrainFromAnotherThreadRunsOnTheServersRuntime():Void {
		var runtime:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();
		var drained:Deque<String> = new Deque();

		// With nothing to wait for, a drain finishes where it runs.
		var server:HTTPServer = SpreadSupport.on(runtime, () -> new HTTPServer(__config(seen)));
		server.drain(5.0, () -> drained.add(SpreadSupport.where(runtime)));
		Assert.equals("own", SpreadSupport.pop(drained, WAIT), "a drain begun on another thread finished off the server's runtime");
		Assert.isFalse(server.listening);

		SpreadSupport.stop([runtime]);
	}

	/** The server's metrics count every runtime's requests and connections. **/
	@:timeout(30000)
	public function testMetricsCountEveryRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();
		var registry = new crossbyte.metrics.Metrics();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.metrics = registry;
			config.runtimes = [first, second];
			return new HTTPServer(config);
		});

		var clients:Array<sys.net.Socket> = [for (_ in 0...2) SpreadSupport.connect(server.localPort)];
		for (n in 0...3) {
			for (client in clients) {
				Assert.equals(200, HttpWire.get(client, '/m$n').status);
			}
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> registry.toPrometheus().indexOf('http_requests_total{status="2xx"} 6') >= 0, WAIT),
			"the requests of every runtime were not counted: " + registry.toPrometheus());
		Assert.isTrue(registry.toPrometheus().indexOf("http_active_connections 2") >= 0, "the connection gauge did not count every runtime's");

		SpreadSupport.closeAll(clients);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	#if (cpp || java || jvm)
	/** HTTPS: the TLS handshake and the request both on the connection's runtime. **/
	@:timeout(30000)
	public function testHttpsIsServedOnTheRuntimes():Void {
		var fixture = crossbyte.net.TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var seen:Deque<Arrival> = new Deque();

		var server:HTTPServer = SpreadSupport.on(acceptor, () -> {
			var config = __config(seen);
			config.tlsCertificatePath = fixture.certificatePath;
			config.tlsKeyPath = fixture.keyPath;
			config.runtimes = [first, second];
			return new HTTPServer(config);
		});

		var expected:Array<CrossByte> = [first, second];
		for (i in 0...2) {
			var answer:Null<String> = SpreadSupport.tlsExchange(server.localPort, fixture.certificate,
				'GET /s$i HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n');
			Assert.isTrue(answer != null && answer.startsWith("HTTP/1.1 200"), 'HTTPS request $i was not answered: $answer');
			var where:Null<Arrival> = SpreadSupport.pop(seen, WAIT);
			Assert.isTrue(where != null && where.runtime == expected[i] && where.thread == expected[i].__ownerThread,
				'HTTPS request $i ran off its connection\'s runtime');
		}

		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}
	#end
	#end
}

#if target.threaded
/** HTTP/1.1 by hand over a blocking socket. **/
class HttpWire {
	/** One GET on a kept-alive connection: its status and body, status 0 if none came. **/
	public static function get(client:sys.net.Socket, path:String):{status:Int, body:String} {
		try {
			client.output.writeString('GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
			client.output.flush();
		} catch (_:Dynamic) {
			return {status: 0, body: ""};
		}
		return getReply(client);
	}

	/** The next response on `client`: its status and body, status 0 if none came. **/
	public static function getReply(client:sys.net.Socket):{status:Int, body:String} {
		var head:String = "";
		var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);
		try {
			while (!head.endsWith("\r\n\r\n") && head.length < 16384) {
				client.input.readBytes(one, 0, 1);
				head += String.fromCharCode(one.get(0));
			}
		} catch (_:Dynamic) {}
		var status:Int = 0;
		if (head.startsWith("HTTP/1.1 ")) {
			var parsed:Null<Int> = Std.parseInt(head.substr(9, 3));
			status = parsed == null ? 0 : parsed;
		}
		var length:Int = 0;
		for (line in head.split("\r\n")) {
			if (line.toLowerCase().startsWith("content-length:")) {
				var parsed:Null<Int> = Std.parseInt(StringTools.trim(line.substr(15)));
				length = parsed == null ? 0 : parsed;
			}
		}
		var body:String = length > 0 ? SpreadSupport.read(client, length) : "";
		return {status: status, body: body};
	}
}

/**
	HTTP/2 by hand: prior knowledge over cleartext, one request at a time,
	headers by the static table and a literal authority.
**/
class H2Wire {
	private var __client:sys.net.Socket;
	private var __stream:Int = 1;

	public function new(client:sys.net.Socket) {
		__client = client;
		client.output.writeString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
		__frame(4, 0, 0, haxe.io.Bytes.alloc(0));
		client.output.flush();
	}

	/** One GET: the response's body, or null. **/
	public function get(path:String):Null<String> {
		var block:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		block.addByte(0x82); // :method GET
		block.addByte(0x86); // :scheme http
		block.addByte(0x04); // :path, literal without indexing, name 4
		block.addByte(path.length);
		block.addString(path);
		block.addByte(0x01); // :authority, literal without indexing, name 1
		block.addByte(9);
		block.addString("127.0.0.1");
		var stream:Int = __stream;
		__stream += 2;
		// END_STREAM | END_HEADERS
		__frame(1, 0x05, stream, block.getBytes());
		__client.output.flush();

		var body:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		try {
			while (true) {
				var head:haxe.io.Bytes = haxe.io.Bytes.alloc(9);
				__client.input.readFullBytes(head, 0, 9);
				var length:Int = (head.get(0) << 16) | (head.get(1) << 8) | head.get(2);
				var type:Int = head.get(3);
				var flags:Int = head.get(4);
				var id:Int = ((head.get(5) & 0x7F) << 24) | (head.get(6) << 16) | (head.get(7) << 8) | head.get(8);
				var payload:haxe.io.Bytes = haxe.io.Bytes.alloc(length);
				if (length > 0) {
					__client.input.readFullBytes(payload, 0, length);
				}
				if (type == 4 && (flags & 1) == 0) {
					// The server's SETTINGS, acknowledged.
					__frame(4, 1, 0, haxe.io.Bytes.alloc(0));
					__client.output.flush();
				} else if (type == 0 && id == stream) {
					body.add(payload);
					if (length > 0) {
						// The connection's window back, so it never runs dry.
						var increment:haxe.io.Bytes = haxe.io.Bytes.alloc(4);
						increment.set(0, (length >> 24) & 0x7F);
						increment.set(1, (length >> 16) & 0xFF);
						increment.set(2, (length >> 8) & 0xFF);
						increment.set(3, length & 0xFF);
						__frame(8, 0, 0, increment);
						__client.output.flush();
					}
					if ((flags & 1) != 0) {
						return body.getBytes().toString();
					}
				} else if (type == 1 && id == stream && (flags & 1) != 0) {
					// Headers ending the stream: no body.
					return "";
				} else if (type == 7 || (type == 3 && id == stream)) {
					return null;
				}
			}
		} catch (_:Dynamic) {}
		return null;
	}

	private function __frame(type:Int, flags:Int, stream:Int, payload:haxe.io.Bytes):Void {
		var frame:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		frame.addByte((payload.length >> 16) & 0xFF);
		frame.addByte((payload.length >> 8) & 0xFF);
		frame.addByte(payload.length & 0xFF);
		frame.addByte(type);
		frame.addByte(flags);
		frame.addByte((stream >> 24) & 0x7F);
		frame.addByte((stream >> 16) & 0xFF);
		frame.addByte((stream >> 8) & 0xFF);
		frame.addByte(stream & 0xFF);
		frame.add(payload);
		__client.output.write(frame.getBytes());
	}
}
#end
