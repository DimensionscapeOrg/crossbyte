package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import utest.Assert;
#if target.threaded
import sys.thread.Deque;
#end

using StringTools;

/**
	A `ServerWebSocket` spread over several runtimes: each session's TLS,
	upgrade, messages and close on the runtime it was handed to; the limits,
	counts and drain of the server across all of them.

	The clients are written by hand -- an upgrade request and masked frames
	over a blocking socket -- so these run where no WebSocket client can:
	the interpreter, hl and neko have no secure random source for a client's
	key.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.net.ServerSocket)
@:access(crossbyte.net.ServerWebSocket)
@:access(crossbyte.net.Socket)
class ServerWebSocketSpreadTest extends utest.Test {
	#if target.threaded
	private static inline var WAIT:Float = 10.0;

	@:timeout(30000)
	public function testSessionsLiveOnTheRuntimesInTurn():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var opened:Deque<Arrival> = new Deque();
		var seen:Deque<String> = new Deque();
		var asked:Deque<Arrival> = new Deque();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.runtimes = [first, second];
			server.upgrade = function(request:WebSocketRequest):Bool {
				asked.add(new Arrival(CrossByte.__currentOrNull(), sys.thread.Thread.current(), null));
				return true;
			};
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
				var session:WebSocket = cast e.socket;
				var runtime:CrossByte = CrossByte.__currentOrNull();
				session.addEventListener(WebSocketMessageEvent.MESSAGE, function(message:WebSocketMessageEvent) {
					seen.add("message:" + SpreadSupport.where(runtime));
					session.sendText(message.data.readUTFBytes(message.data.length).toUpperCase());
				});
				session.addEventListener(Event.CLOSE, _ -> seen.add("close:" + SpreadSupport.where(runtime)));
				opened.add(Arrival.of(session));
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var clients:Array<sys.net.Socket> = [];
		var landed:Array<Arrival> = [];
		for (i in 0...4) {
			var client:Null<sys.net.Socket> = WebSocketWire.open(server.localPort);
			Assert.notNull(client, 'session $i was not upgraded');
			if (client == null) {
				continue;
			}
			clients.push(client);
			var arrival = SpreadSupport.pop(opened, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}

		Assert.equals(4, landed.length, "sessions were not announced");
		var expected:Array<CrossByte> = [first, second, first, second];
		for (i in 0...landed.length) {
			Assert.isTrue(landed[i].runtime == expected[i], 'session $i opened on the wrong runtime');
			Assert.isTrue(landed[i].thread == expected[i].__ownerThread, 'session $i was announced off its runtime\'s thread');
		}
		for (i in 0...4) {
			var hook:Null<Arrival> = SpreadSupport.pop(asked, WAIT);
			Assert.isTrue(hook != null && hook.runtime == expected[i] && hook.thread == expected[i].__ownerThread,
				'the upgrade hook for session $i was not asked on its runtime');
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.clientCount == 4, WAIT), 'clientCount is ${server.clientCount}, not 4');

		for (i in 0...clients.length) {
			WebSocketWire.sendText(clients[i], "hello" + i);
			Assert.equals("HELLO" + i, WebSocketWire.readText(clients[i]), 'session $i did not echo');
			Assert.equals("message:own", SpreadSupport.pop(seen, WAIT), 'session $i read its message off its runtime');
		}

		// Ended by the client: its close is told on its runtime too.
		WebSocketWire.sendClose(clients[0], 1000);
		Assert.equals("close:own", SpreadSupport.pop(seen, WAIT), "a session's close was told off its runtime");
		Assert.isTrue(SpreadSupport.waitFor(() -> server.clientCount == 3, WAIT), 'clientCount is ${server.clientCount} once one closed, not 3');

		SpreadSupport.closeAll(clients);
		Assert.isTrue(SpreadSupport.waitFor(() -> server.clientCount == 0, WAIT), 'clientCount is ${server.clientCount} once every client left');
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		Many clients at once, each with a session and a run of messages,
		against a server on four runtimes: every message is echoed to its own
		session, every runtime holds some, and the count of sessions comes
		back to nothing.
	**/
	@:timeout(90000)
	public function testConcurrentSessionsAreEachEchoedCorrectly():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var workers:Array<CrossByte> = [for (_ in 0...4) SpreadSupport.runtime()];
		var opened:Deque<Arrival> = new Deque();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.runtimes = workers;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
				var session:WebSocket = cast e.socket;
				session.addEventListener(WebSocketMessageEvent.MESSAGE, function(message:WebSocketMessageEvent) {
					session.sendText("echo:" + message.data.readUTFBytes(message.data.length));
				});
				opened.add(Arrival.of(session));
			});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var sessions:Int = 12;
		var messages:Int = 30;
		var failures:Deque<String> = new Deque();
		var finished:Deque<Bool> = new Deque();
		for (c in 0...sessions) {
			sys.thread.Thread.create(() -> {
				try {
					var client:Null<sys.net.Socket> = WebSocketWire.open(server.localPort);
					if (client == null) {
						failures.add('client $c was not upgraded');
					} else {
						for (n in 0...messages) {
							var text:String = 'c$c-m$n';
							WebSocketWire.sendText(client, text);
							var reply:Null<String> = WebSocketWire.readText(client);
							if (reply != "echo:" + text) {
								failures.add('client $c message $n came back as "$reply"');
							}
						}
						WebSocketWire.sendClose(client, 1000);
						client.close();
					}
				} catch (error:Dynamic) {
					failures.add('client $c threw ' + Std.string(error));
				}
				finished.add(true);
			});
		}
		for (_ in 0...sessions) {
			SpreadSupport.pop(finished, 60.0);
		}

		var problems:Array<String> = [];
		var problem:Null<String> = failures.pop(false);
		while (problem != null && problems.length < 10) {
			problems.push(problem);
			problem = failures.pop(false);
		}
		Assert.same([], problems, "a concurrent session was answered wrongly: " + problems.join("; "));

		var held:Array<Int> = [for (_ in workers) 0];
		var arrival:Null<Arrival> = opened.pop(false);
		while (arrival != null) {
			var index:Int = workers.indexOf(arrival.runtime);
			if (index >= 0 && arrival.thread == workers[index].__ownerThread) {
				held[index]++;
			}
			arrival = opened.pop(false);
		}
		Assert.equals(sessions, held[0] + held[1] + held[2] + held[3], "a session opened off the runtime it was handed to");
		for (i in 0...held.length) {
			Assert.isTrue(held[i] > 0, 'runtime $i held none of the sessions: $held');
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.clientCount == 0, WAIT), 'clientCount is ${server.clientCount} once every client left');

		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop(workers.concat([acceptor]));
	}

	/**
		On Linux, `reusePort`: each runtime listens for itself, and each
		session opens on the runtime whose listener the kernel chose.
	**/
	@:timeout(60000)
	public function testReusePortOpensSessionsOnEachRuntime():Void {
		if (!SpreadSupport.reusePortExpected()) {
			Assert.pass();
			return;
		}

		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var opened:Deque<Arrival> = new Deque();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.reusePort = true;
			server.runtimes = [first, second];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> opened.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var clients:Array<sys.net.Socket> = [];
		for (_ in 0...20) {
			var client = WebSocketWire.open(server.localPort);
			if (client != null) {
				clients.push(client);
			}
		}
		Assert.equals(20, clients.length, "sessions were not all upgraded");

		var held:Array<Int> = [0, 0];
		for (_ in 0...20) {
			var arrival = SpreadSupport.pop(opened, WAIT);
			if (arrival != null) {
				var index:Int = [first, second].indexOf(arrival.runtime);
				if (index >= 0 && arrival.thread == arrival.runtime.__ownerThread) {
					held[index]++;
				}
			}
		}
		Assert.equals(20, held[0] + held[1], "a session opened off the runtime that accepted it");
		Assert.isTrue(held[0] > 0 && held[1] > 0, 'the kernel gave one runtime every session: $held');
		Assert.isTrue(SpreadSupport.waitFor(() -> server.clientCount == 20, WAIT));

		SpreadSupport.closeAll(clients);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		`maxPendingHandshakes` counts the sessions still upgrading on every
		runtime together, and `handshakeFailures` those that ran out of time
		on any of them.
	**/
	@:timeout(30000)
	public function testUpgradeLimitHoldsAcrossRuntimes():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.runtimes = [first, second];
			server.maxPendingHandshakes = 2;
			server.handshakeTimeout = 1.0;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var silent:Array<sys.net.Socket> = [for (_ in 0...4) SpreadSupport.connect(server.localPort)];
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 2, WAIT), "the upgrades in flight did not reach the limit");
		crossbyte.sys.System.sleep(0.3);
		Assert.equals(2, server.pendingHandshakeCount(), "more sessions were taken than the limit allows across the runtimes");

		Assert.isTrue(SpreadSupport.waitFor(() -> server.handshakeFailures == 4, WAIT), 'upgrades that ran out of time were counted ${server.handshakeFailures} times, not 4');
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 0, WAIT));
		Assert.equals(0, server.clientCount);

		SpreadSupport.closeAll(silent);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/**
		`drain()` sends every session on every runtime its close frame, and
		finishes on the server's runtime once all have gone; the runtimes
		`runtimeCount` made exit with it.
	**/
	@:timeout(30000)
	public function testDrainEndsTheSessionsOnEveryRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var opened:Deque<Arrival> = new Deque();
		var drained:Deque<String> = new Deque();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.runtimeCount = 2;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> opened.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});
		var made:Array<CrossByte> = server.runtimes;

		var clients:Array<sys.net.Socket> = [];
		for (_ in 0...4) {
			var client = WebSocketWire.open(server.localPort);
			if (client != null) {
				clients.push(client);
			}
			SpreadSupport.pop(opened, WAIT);
		}
		Assert.equals(4, clients.length);
		Assert.isTrue(SpreadSupport.waitFor(() -> server.clientCount == 4, WAIT));

		SpreadSupport.on(acceptor, () -> {
			server.drain(5.0, () -> drained.add(SpreadSupport.where(acceptor)), 1001);
			return null;
		});

		// Each client is told why, and answers, as a browser does.
		for (i in 0...clients.length) {
			Assert.equals(1001, WebSocketWire.readClose(clients[i]), 'session $i was not sent 1001');
			WebSocketWire.sendClose(clients[i], 1001);
		}

		Assert.equals("own", SpreadSupport.pop(drained, WAIT), "drain() did not finish on the server's runtime");
		Assert.equals(0, server.clientCount, "sessions were left after drain()");
		Assert.isFalse(server.listening);
		Assert.isTrue(SpreadSupport.waitFor(() -> made[0].__didExit && made[1].__didExit, WAIT), "the runtimes made for the server outlived its drain");

		SpreadSupport.closeAll(clients);
		SpreadSupport.stop([acceptor]);
	}

	/**
		Mid-upgrade on the runtimes when the server stops: each is dropped
		where it is, and not counted as a failure.
	**/
	@:timeout(30000)
	public function testStopAcceptingDropsUpgradesOnEveryRuntime():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.runtimes = [first, second];
			server.handshakeTimeout = 30.0;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var silent:Array<sys.net.Socket> = [for (_ in 0...4) SpreadSupport.connect(server.localPort)];
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 4, WAIT));
		var perRuntime:Array<Int> = [for (replica in server.__spread.replicas) replica.__localPendingCount()];
		Assert.same([2, 2], perRuntime, "the sessions upgrading were not shared between the runtimes");

		SpreadSupport.on(acceptor, () -> server.stopAccepting());
		for (client in silent) {
			Assert.isTrue(SpreadSupport.ended(client), "a session upgrading on a runtime outlived stopAccepting()");
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> server.pendingHandshakeCount() == 0, WAIT));
		Assert.equals(0, server.handshakeFailures, "sessions let go of were counted as failures");

		SpreadSupport.closeAll(silent);
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	/** The metrics a server publishes count every runtime's sessions. **/
	@:timeout(30000)
	public function testMetricsCountEveryRuntimesSessions():Void {
		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var registry = new crossbyte.metrics.Metrics();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket();
			server.runtimes = [first, second];
			server.publishMetrics(registry, "ws");
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var clients:Array<sys.net.Socket> = [];
		for (_ in 0...3) {
			var client = WebSocketWire.open(server.localPort);
			if (client != null) {
				clients.push(client);
			}
		}
		Assert.isTrue(SpreadSupport.waitFor(() -> registry.toPrometheus().indexOf("ws_sessions 3") >= 0, WAIT), "the sessions gauge did not count every runtime's: " + registry.toPrometheus());
		Assert.isTrue(SpreadSupport.waitFor(() -> registry.toPrometheus().indexOf("ws_sessions_accepted_total 3") >= 0, WAIT), "accepted sessions were not counted on every runtime");

		SpreadSupport.closeAll(clients);
		Assert.isTrue(SpreadSupport.waitFor(() -> registry.toPrometheus().indexOf("ws_sessions_closed_total 3") >= 0, WAIT), "closed sessions were not counted on every runtime");
		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}

	#if (cpp || java || jvm)
	/** A wss session's TLS handshake and upgrade both run on its runtime. **/
	@:timeout(30000)
	public function testSecureSessionsUpgradeOnTheRuntimes():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.pass();
			return;
		}

		var acceptor:CrossByte = SpreadSupport.runtime();
		var first:CrossByte = SpreadSupport.runtime();
		var second:CrossByte = SpreadSupport.runtime();
		var opened:Deque<Arrival> = new Deque();

		var server:ServerWebSocket = SpreadSupport.on(acceptor, () -> {
			var server = new ServerWebSocket(true);
			server.cert = {certificate: fixture.certificate, key: fixture.key};
			server.runtimes = [first, second];
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> opened.add(Arrival.of(e.socket)));
			server.bind(0, "127.0.0.1");
			server.listen();
			return server;
		});

		var answers:Array<String> = [];
		for (_ in 0...2) {
			var answer:Null<String> = SpreadSupport.tlsExchange(server.localPort, fixture.certificate, WebSocketWire.UPGRADE);
			answers.push(answer == null ? "nothing" : answer.substr(0, 12));
		}
		Assert.same(["HTTP/1.1 101", "HTTP/1.1 101"], answers, "a wss upgrade was not answered");

		var landed:Array<Arrival> = [];
		for (_ in 0...2) {
			var arrival = SpreadSupport.pop(opened, WAIT);
			if (arrival != null) {
				landed.push(arrival);
			}
		}
		Assert.equals(2, landed.length);
		var expected:Array<CrossByte> = [first, second];
		for (i in 0...landed.length) {
			Assert.isTrue(landed[i].runtime == expected[i] && landed[i].thread == expected[i].__ownerThread, 'wss session $i did not open on its runtime');
			Assert.isTrue(landed[i].socket.secure, 'wss session $i says it is not secure');
		}

		SpreadSupport.on(acceptor, () -> server.close());
		SpreadSupport.stop([acceptor, first, second]);
	}
	#end
	#end
}

#if target.threaded
/** A WebSocket client by hand, over a blocking socket. **/
class WebSocketWire {
	public static inline var UPGRADE:String = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

	/** Connects and upgrades; null when the server did not answer `101`. **/
	public static function open(port:Int):Null<sys.net.Socket> {
		var client:sys.net.Socket = SpreadSupport.connect(port);
		client.output.writeString(UPGRADE);
		client.output.flush();
		var head:String = "";
		var one:haxe.io.Bytes = haxe.io.Bytes.alloc(1);
		try {
			while (!head.endsWith("\r\n\r\n") && head.length < 4096) {
				client.input.readBytes(one, 0, 1);
				head += String.fromCharCode(one.get(0));
			}
		} catch (_:Dynamic) {}
		if (!head.startsWith("HTTP/1.1 101")) {
			try {
				client.close();
			} catch (_:Dynamic) {}
			return null;
		}
		return client;
	}

	public static function sendText(client:sys.net.Socket, text:String):Void {
		__send(client, 0x81, haxe.io.Bytes.ofString(text));
	}

	public static function sendClose(client:sys.net.Socket, code:Int):Void {
		var payload:haxe.io.Bytes = haxe.io.Bytes.alloc(2);
		payload.set(0, code >> 8);
		payload.set(1, code & 0xFF);
		try {
			__send(client, 0x88, payload);
		} catch (_:Dynamic) {}
	}

	/** The next text frame's payload, or null. **/
	public static function readText(client:sys.net.Socket):Null<String> {
		var frame = __read(client);
		return frame == null || frame.opcode != 1 ? null : frame.payload.toString();
	}

	/** The code of the next frame if it is a close, or -1. **/
	public static function readClose(client:sys.net.Socket):Int {
		var frame = __read(client);
		while (frame != null && frame.opcode != 8) {
			frame = __read(client);
		}
		if (frame == null || frame.payload.length < 2) {
			return -1;
		}
		return (frame.payload.get(0) << 8) | frame.payload.get(1);
	}

	private static function __send(client:sys.net.Socket, first:Int, payload:haxe.io.Bytes):Void {
		var frame:haxe.io.BytesBuffer = new haxe.io.BytesBuffer();
		frame.addByte(first);
		frame.addByte(0x80 | payload.length);
		var mask:Array<Int> = [0x12, 0x34, 0x56, 0x78];
		for (b in mask) {
			frame.addByte(b);
		}
		for (i in 0...payload.length) {
			frame.addByte(payload.get(i) ^ mask[i % 4]);
		}
		client.output.write(frame.getBytes());
		client.output.flush();
	}

	private static function __read(client:sys.net.Socket):Null<{opcode:Int, payload:haxe.io.Bytes}> {
		try {
			var head:haxe.io.Bytes = haxe.io.Bytes.alloc(2);
			client.input.readFullBytes(head, 0, 2);
			var length:Int = head.get(1) & 0x7F;
			if (length == 126) {
				var extended:haxe.io.Bytes = haxe.io.Bytes.alloc(2);
				client.input.readFullBytes(extended, 0, 2);
				length = (extended.get(0) << 8) | extended.get(1);
			}
			var payload:haxe.io.Bytes = haxe.io.Bytes.alloc(length);
			if (length > 0) {
				client.input.readFullBytes(payload, 0, length);
			}
			return {opcode: head.get(0) & 0x0F, payload: payload};
		} catch (_:Dynamic) {
			return null;
		}
	}
}
#end
