package crossbyte.net;

import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	What a listener does with connections it cannot take, and with the
	listeners it tells about them.

	A connection the system would not hand over -- the process out of
	descriptors -- was swallowed natively, leaving a server that looked idle,
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

	#if (cpp || java || jvm || nodejs)
	/**
		A client that is not speaking TLS at all, and -- natively, where the
		server keeps the deadline -- one that says nothing.
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
	#end
}

#if (cpp || java || jvm || eval)
/**
	A server whose system refuses the first `refusals` connections it is
	asked for, the way one out of descriptors does -- hxcpp raises that as a
	bare string, the jvm as an I/O error -- then hands them over.
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
