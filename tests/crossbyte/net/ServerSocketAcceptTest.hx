package crossbyte.net;

import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	What a listener does with connections it cannot take, and with the
	listeners it tells about them.

	A connection the system would not hand over, the process out of
	descriptors, was swallowed natively, leaving a server that looked idle,
	and closed the server on the jvm. A TLS handshake that failed left no
	trace. And removing any one `connect` listener stopped the server
	accepting, though others were still listening.
**/
class ServerSocketAcceptTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(15000)
	public function testRemovingOneConnectListenerLeavesTheOthersListening(async:Async):Void {
		var server = new ServerSocket();
		var first:Int = 0;
		var second:Int = 0;
		var accepted:Array<Socket> = [];
		var onFirst = function(e:ServerSocketConnectEvent) {
			first++;
			accepted.push(e.socket);
		};
		server.addEventListener(ServerSocketConnectEvent.CONNECT, onFirst);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			second++;
			accepted.push(e.socket);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		// One part of the application stops listening; the other has not.
		server.removeEventListener(ServerSocketConnectEvent.CONNECT, onFirst);

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> second > 0, 5.0, function(_) {
				Assert.equals(1, second, "the listener that stayed was never told of the connection");
				Assert.equals(0, first, "the listener that was removed was told of it");
				try client.close() catch (_:Dynamic) {}
				for (socket in accepted) {
					try socket.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	#if (cpp || java || jvm || eval)
	/**
		The system refusing twice to hand over a waiting connection, as it does
		when the process is out of descriptors, then relenting.
	**/
	@:timeout(15000)
	public function testAnAcceptThatFailsIsReportedOnceAndTheServerCarriesOn(async:Async):Void {
		var server = new RefusingServerSocket(2);
		var errors:Array<String> = [];
		var accepted:Array<Socket> = [];
		var closed:Bool = false;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted.push(e.socket));
		server.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) errors.push(e.text));
		server.addEventListener(crossbyte.events.Event.CLOSE, function(_) closed = true);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> accepted.length > 0 || closed, 5.0, function(_) {
				Assert.isFalse(closed, "a failed accept closed the server");
				Assert.isTrue(server.listening, "a failed accept stopped the server listening");
				Assert.equals(2, server.acceptFailures, "the failed accepts were not counted");
				Assert.equals(1, errors.length, "a run of failed accepts was not reported exactly once: " + errors);
				Assert.isTrue(errors.length > 0 && errors[0].indexOf("Too many open files") >= 0, "the report did not carry the reason: " + errors[0]);
				Assert.equals(1, accepted.length, "the waiting connection was never taken once the system relented");
				try client.close() catch (_:Dynamic) {}
				for (socket in accepted) {
					try socket.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	#if (cpp || java || jvm || eval)
	/**
		A server whose `connect` listener arrives after `listen()`, the order
		NetHost uses, and then closes. It held the accept tick twice, since
		each path that wanted it ran added it again, and close() took one
		away: the other called `accept()` on the closed listener every frame
		for good. Once a new listener took over its descriptor number that was
		the new server's socket, its connections taken, or on eval, where a
		socket cannot be made non-blocking, the runtime stopped for good,
		waiting on a connection nobody made. That was the interpreter suite
		hanging on Linux.
	**/
	@:timeout(15000)
	public function testAClosedServerStopsAccepting(async:Async):Void {
		var runtime = crossbyte.core.CrossByte.current();
		var before:Int = __tickListeners(runtime);
		var plain = new ClosingCountServerSocket();
		var web = new ClosingCountServerWebSocket();
		var extra = function(_:ServerSocketConnectEvent) {};
		var another = function(_:ServerSocketConnectEvent) {};

		for (server in [(plain : ServerSocket), (web : ServerSocket)]) {
			server.bind(0, "127.0.0.1");
			server.listen();
			server.addEventListener(ServerSocketConnectEvent.CONNECT, extra);
			server.addEventListener(ServerSocketConnectEvent.CONNECT, another);
			server.removeEventListener(ServerSocketConnectEvent.CONNECT, extra);
			server.close();
		}

		// Some frames, for a tick left behind to show itself in.
		NetPump.wait(0.3, function() {
			Assert.equals(0, plain.ticksAfterClose, "a closed server's accept tick still ran");
			Assert.equals(0, web.acceptsAfterClose, "a closed WebSocket server still called accept()");
			Assert.equals(before, __tickListeners(runtime), "a closed server left its tick on the runtime");
			async.done();
		});
	}

	@:access(crossbyte.events.EventDispatcher)
	private static function __tickListeners(runtime:crossbyte.core.CrossByte):Int {
		var list:Array<Dynamic> = runtime.__eventMap == null ? null : runtime.__eventMap.get(crossbyte.events.TickEvent.TICK);
		return list == null ? 0 : list.length;
	}
	#end

	#if (cpp || java || jvm || nodejs)
	/**
		A client that is not speaking TLS at all, and, natively, where the
		server keeps the deadline, one that says nothing.
	**/
	@:timeout(20000)
	public function testFailedHandshakesAreCounted(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			async.done();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.handshakeTimeout = 0.3;
		var accepted:Int = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) accepted++);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var talker = new WirePeer(server.localPort);
			talker.send(Bytes.ofString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"));
			#if !nodejs
			var silent = new WirePeer(server.localPort);
			var expected:Int = 2;
			#else
			var expected:Int = 1;
			#end

			NetPump.until(() -> server.handshakeFailures >= expected, 10.0, function(_) {
				Assert.equals(expected, server.handshakeFailures, "a failed handshake was not counted");
				Assert.equals(0, accepted, "a connection whose handshake failed was reported as connected");
				talker.close();
				#if !nodejs
				silent.close();
				#end
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A `handshakeTimeout` of 0 sets no deadline, as every other timeout
		does and as `ServerWebSocket`'s does. It failed every handshake at
		the first accept tick natively, and at 1 ms on Node.
	**/
	@:timeout(20000)
	public function testAHandshakeTimeoutOfZeroWaits(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			async.done();
			return;
		}

		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.handshakeTimeout = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// Connects, and says nothing of TLS for a while.
			var slow = new WirePeer(server.localPort);

			NetPump.wait(0.8, function() {
				Assert.isFalse(slow.ended, "a handshake with no deadline was dropped");
				Assert.equals(0, server.handshakeFailures, "a handshake with no deadline was counted as failed");
				slow.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end
}

#if (cpp || java || jvm || eval)
/** Counts the accept ticks a server still runs once it is closed. **/
private class ClosingCountServerSocket extends ServerSocket {
	public var ticksAfterClose:Int = 0;

	public function new() {
		super();
	}

	override private function this_onTick(e:crossbyte.events.TickEvent):Void {
		if (__closed) {
			ticksAfterClose++;
		}
		super.this_onTick(e);
	}
}

/** Counts the accepts a WebSocket server still attempts once it is closed. **/
private class ClosingCountServerWebSocket extends ServerWebSocket {
	public var acceptsAfterClose:Int = 0;

	public function new() {
		super();
	}

	override private function __acceptPending():crossbyte._internal.websocket.FlexSocket {
		if (__closed) {
			acceptsAfterClose++;
		}
		return super.__acceptPending();
	}
}

/**
	A server whose system refuses the first `refusals` connections it is
	asked for, the way one out of descriptors does, hxcpp raises that as a
	bare string, the jvm as an I/O error, then hands them over.
**/
private class RefusingServerSocket extends ServerSocket {
	private var __refusals:Int;

	public function new(refusals:Int) {
		super();
		__refusals = refusals;
	}

	override private function __takeConnection():sys.net.Socket {
		if (__refusals > 0) {
			__refusals--;
			#if cpp
			throw "Too many open files";
			#else
			throw haxe.io.Error.Custom("Too many open files");
			#end
		}
		return super.__takeConnection();
	}
}
#end
