package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Lock;
#end

/**
	A POLL loop's connections are taken, dialled and secured as the system
	reports them, not at the next tick.

	The loop spends each frame blocked in poll, which only a socket in the
	poll set can end. Listeners were never in it -- accepts ran from the
	tick -- a connect in flight was watched from the tick, and a TLS server's
	handshakes were stepped from the tick. So each waited for the next frame:
	41 to 57 ms from connect to accept at the default twelve ticks a second,
	and a handshake paid that for every round trip, 132 ms to secureConnect
	on the jvm. These run a child runtime's real loop at two ticks a second,
	where the old wait was a quarter of a second on average, and act at
	arbitrary points in its frame.
**/
@:access(crossbyte.core.CrossByte)
class SocketReadinessTest extends utest.Test {
	#if (target.threaded && (cpp || java || jvm || eval))
	@:timeout(30000)
	public function testAPollLoopAcceptsAsConnectionsArrive():Void {
		var started:Lock = new Lock();
		var accepted:Deque<Stamp> = new Deque();
		var port:Int = 0;
		var server:ServerSocket = null;
		var sessions:Array<Socket> = [];

		var child:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.tps = 2;
			configured.addEventListener(Event.INIT, _ -> {
				server = new ServerSocket();
				server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
					accepted.add({at: haxe.Timer.stamp()});
					sessions.push(e.socket);
				});
				server.bind(0, "127.0.0.1");
				server.listen();
				port = server.localPort;
				started.release();
			});
		});

		var waits:Array<Float> = [];
		var clients:Array<sys.net.Socket> = [];
		if (started.wait(5.0)) {
			for (i in 0...6) {
				Sys.sleep(0.05 + i * 0.037);
				var client:sys.net.Socket = new sys.net.Socket();
				var start:Float = haxe.Timer.stamp();
				client.connect(new sys.net.Host("127.0.0.1"), port);
				clients.push(client);
				var at:Null<Float> = __popWithin(accepted, 5.0);
				waits.push(at == null ? 5.0 : at - start);
			}
		}

		__stop(child, () -> {
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			if (server != null) {
				try server.close() catch (_:Dynamic) {}
			}
		});
		for (client in clients) {
			try client.close() catch (_:Dynamic) {}
		}

		Assert.equals(6, waits.length, "the child runtime never started");
		var median:Float = __median(waits);
		Assert.isTrue(median < 0.1, 'connect to accept took a median ${__ms(median)} ms on a loop at 2 ticks a second: ${waits.map(__ms)}');
	}

	@:timeout(30000)
	public function testAPollLoopAnnouncesAConnectAsItFinishes():Void {
		var listener:sys.net.Socket = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(16);
		var port:Int = listener.host().port;

		var started:Lock = new Lock();
		var connected:Deque<Stamp> = new Deque();
		var dialled:Array<Socket> = [];

		var child:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.tps = 2;
			configured.addEventListener(Event.INIT, _ -> started.release());
		});

		var waits:Array<Float> = [];
		if (started.wait(5.0)) {
			for (i in 0...6) {
				Sys.sleep(0.05 + i * 0.037);
				// Dialled from the runtime's own thread, as a handler would.
				child.post(() -> {
					var socket:Socket = new Socket();
					dialled.push(socket);
					var start:Float = haxe.Timer.stamp();
					socket.addEventListener(Event.CONNECT, _ -> connected.add({at: haxe.Timer.stamp() - start}));
					socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> connected.add({at: 5.0}));
					socket.connect("127.0.0.1", port);
				});
				var waited:Null<Float> = __popWithin(connected, 5.0);
				waits.push(waited == null ? 5.0 : waited);
			}
		}

		__stop(child, () -> {
			for (socket in dialled) {
				try socket.close() catch (_:Dynamic) {}
			}
		});
		try listener.close() catch (_:Dynamic) {}

		Assert.equals(6, waits.length, "the child runtime never started");
		var median:Float = __median(waits);
		Assert.isTrue(median < 0.1, 'connect() to CONNECT took a median ${__ms(median)} ms on a loop at 2 ticks a second: ${waits.map(__ms)}');
	}
	#end

	#if (target.threaded && (cpp || java || jvm))
	@:timeout(30000)
	public function testAPollLoopHandshakesAsFlightsArrive():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			return;
		}

		var started:Lock = new Lock();
		var secured:Deque<Stamp> = new Deque();
		var port:Int = 0;
		var server:ServerSocket = null;
		var sessions:Array<Socket> = [];

		var child:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.tps = 2;
			configured.addEventListener(Event.INIT, _ -> {
				server = new ServerSocket(true);
				server.setCertificate(fixture.certificate, fixture.key);
				server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
					secured.add({at: haxe.Timer.stamp()});
					sessions.push(e.socket);
				});
				server.bind(0, "127.0.0.1");
				server.listen();
				port = server.localPort;
				started.release();
			});
		});

		var waits:Array<Float> = [];
		var failures:Array<String> = [];
		if (started.wait(5.0)) {
			// Once unmeasured first: the client's own TLS machinery starts up
			// on its first handshake, which is no part of what is measured.
			try {
				__handshake(port, fixture);
			} catch (e:Dynamic) {
				failures.push(Std.string(e));
			}
			__popWithin(secured, 5.0);

			for (i in 0...4) {
				Sys.sleep(0.05 + i * 0.037);
				var start:Float = haxe.Timer.stamp();
				try {
					__handshake(port, fixture);
				} catch (e:Dynamic) {
					failures.push(Std.string(e));
				}
				var at:Null<Float> = __popWithin(secured, 5.0);
				waits.push(at == null ? 5.0 : at - start);
			}
		}

		__stop(child, () -> {
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			if (server != null) {
				try server.close() catch (_:Dynamic) {}
			}
		});

		Assert.equals(4, waits.length, "the child runtime never started");
		Assert.same([], failures, "a client handshake failed");
		var median:Float = __median(waits);
		Assert.isTrue(median < 0.2, 'a TLS handshake took a median ${__ms(median)} ms against a loop at 2 ticks a second: ${waits.map(__ms)}');
	}

	/** A blocking client handshake from this thread, which is not the server's. **/
	private static function __handshake(port:Int, fixture:crossbyte.net.TLSTestFixture.TLSFixtureData):Void {
		#if cpp
		var client:sys.ssl.Socket = new sys.ssl.Socket();
		client.verifyCert = false;
		client.connect(new sys.net.Host("127.0.0.1"), port);
		client.close();
		#else
		JvmTlsPeer.handshake("127.0.0.1", port, fixture.certificate);
		#end
	}

	/**
		A WebSocket session opened from the runtime's own thread, plain and
		over TLS: the client's connect and both ends' handshakes were stepped
		from the tick alone, so opening a wss session waited a frame for the
		connect and another for each round trip.
	**/
	@:timeout(30000)
	public function testAPollLoopOpensWebSocketSessionsAsTheyProgress():Void {
		var fixture = TLSTestFixture.trusted();
		var plain:Array<Float> = __openSessions(null);
		Assert.equals(4, plain.length, "the child runtime never started");
		Assert.isTrue(__median(plain) < 0.1, 'a ws session took a median ${__ms(__median(plain))} ms to open on a loop at 2 ticks a second: ${plain.map(__ms)}');

		if (fixture == null) {
			// No certificate toolchain on this machine.
			return;
		}
		var secure:Array<Float> = __openSessions(fixture);
		Assert.equals(4, secure.length, "the child runtime never started");
		Assert.isTrue(__median(secure) < 0.2, 'a wss session took a median ${__ms(__median(secure))} ms to open on a loop at 2 ticks a second: ${secure.map(__ms)}');
	}

	/** How long each of four sessions took from connect() to open. **/
	private static function __openSessions(fixture:Null<crossbyte.net.TLSTestFixture.TLSFixtureData>):Array<Float> {
		var started:Lock = new Lock();
		var opened:Deque<Stamp> = new Deque();
		var server:ServerWebSocket = null;
		var sessions:Array<Socket> = [];

		var child:CrossByte = CrossByte.make(POLL, HEAP, configured -> {
			configured.tps = 2;
			configured.addEventListener(Event.INIT, _ -> {
				server = new ServerWebSocket(fixture != null);
				if (fixture != null) {
					server.cert = {certificate: fixture.certificate, key: fixture.key};
				}
				server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(e.socket));
				server.bind(0, "127.0.0.1");
				server.listen();
				started.release();
			});
		});

		var waits:Array<Float> = [];
		if (started.wait(5.0)) {
			for (i in 0...4) {
				Sys.sleep(0.05 + i * 0.037);
				child.post(() -> {
					var client:WebSocket = new WebSocket();
					sessions.push(client);
					if (fixture != null) {
						client.secure = true;
						client.certAuthority = fixture.certificate;
					}
					var start:Float = haxe.Timer.stamp();
					client.addEventListener(Event.CONNECT, _ -> opened.add({at: haxe.Timer.stamp() - start}));
					client.addEventListener(IOErrorEvent.IO_ERROR, _ -> opened.add({at: 5.0}));
					client.connect("127.0.0.1", server.localPort);
				});
				var waited:Null<Float> = __popWithin(opened, 5.0);
				waits.push(waited == null ? 5.0 : waited);
			}
		}

		__stop(child, () -> {
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			if (server != null) {
				try server.close() catch (_:Dynamic) {}
			}
		});
		return waits;
	}
	#end

	#if target.threaded
	/**
		The next stamp, waiting up to `timeout` seconds for one. Stamps are
		boxed: a `Deque<Float>` answers an empty pop with 0 on the jvm rather
		than null, which read as a connection accepted at time zero.
	**/
	private static function __popWithin(queue:Deque<Stamp>, timeout:Float):Null<Float> {
		var deadline:Float = haxe.Timer.stamp() + timeout;
		while (haxe.Timer.stamp() < deadline) {
			var stamp:Null<Stamp> = queue.pop(false);
			if (stamp != null) {
				return stamp.at;
			}
			Sys.sleep(0.001);
		}
		return null;
	}

	/** Runs `cleanup` on the child's thread, then stops it. **/
	private static function __stop(child:CrossByte, cleanup:Void->Void):Void {
		var cleaned:Lock = new Lock();
		if (child.post(() -> {
			cleanup();
			cleaned.release();
		})) {
			cleaned.wait(5.0);
		}
		child.exit();
	}

	private static function __median(values:Array<Float>):Float {
		if (values.length == 0) {
			return 5.0;
		}
		var sorted:Array<Float> = values.copy();
		sorted.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		return sorted[sorted.length >> 1];
	}

	private static function __ms(seconds:Float):Float {
		return Math.round(seconds * 10000) / 10;
	}
	#end
}

#if target.threaded
/** A time, boxed so an empty queue answers null on every target. **/
private typedef Stamp = {
	var at:Float;
}
#end
