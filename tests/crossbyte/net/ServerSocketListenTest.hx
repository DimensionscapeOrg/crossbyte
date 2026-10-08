package crossbyte.net;

import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	What `listen()` promises, and what a Node listener reports.

	`listen()` on a socket never bound is refused natively rather than left
	to the system, where Windows refuses it and Linux and macOS listen on a
	port of their own choosing that `localPort` would not report. On Node a
	port already in use, or a connection Node cannot accept once listening,
	is reported, not a `close` with nothing saying why; a TLS listener gives
	a client that never sends its handshake `handshakeTimeout`, not Node's
	own two minutes; and a handshake that finishes after `close()` is not
	adopted, with no runtime, and announced to a server that has stopped.
**/
class ServerSocketListenTest extends utest.Test {
	public function testListenWithoutBindIsAnIOError():Void {
		var server = new ServerSocket();
		try {
			server.listen();
			Assert.fail("a server never bound listened, on port " + server.localPort);
		} catch (e:IOError) {
			Assert.pass();
		} catch (e:Dynamic) {
			Assert.fail("listen() without bind() threw something other than an IOError: " + Std.string(e));
		}
		Assert.isFalse(server.listening);
		try server.close() catch (_:Dynamic) {}
	}

	public function testANegativeBacklogIsARangeError():Void {
		var server = new ServerSocket();
		server.bind(0, "127.0.0.1");
		Assert.raises(() -> server.listen(-1), RangeError);
		Assert.isFalse(server.listening);
		try server.close() catch (_:Dynamic) {}
	}

	#if nodejs
	@:timeout(15000)
	public function testAPortInUseIsAnIOErrorThenClose(async:Async):Void {
		var first = new ServerSocket();
		first.bind(0, "127.0.0.1");
		first.listen();

		NetPump.until(() -> first.localPort != 0, 5.0, function(_) {
			var second = new ServerSocket();
			var told:Array<String> = [];
			second.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) told.push("ioError: " + e.text));
			second.addEventListener(Event.CLOSE, function(_) told.push("close"));
			second.bind(first.localPort, "127.0.0.1");
			second.listen();

			NetPump.until(() -> told.indexOf("close") >= 0, 5.0, function(_) {
				Assert.equals(2, told.length, "the failed listen was not told as an ioError then close: " + told);
				Assert.isTrue(told.length > 0 && StringTools.startsWith(told[0], "ioError") && told[0].indexOf("EADDRINUSE") >= 0,
					"the ioError did not say the port was in use: " + told);
				Assert.equals("close", told[told.length - 1]);
				Assert.isFalse(second.listening, "a server that could not listen says it is listening");
				try first.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testAConnectionNodeCouldNotTakeLeavesTheServerListening(async:Async):Void {
		var server = new ServerSocket();
		var told:Array<String> = [];
		server.addEventListener(IOErrorEvent.IO_ERROR, function(_) told.push("ioError"));
		server.addEventListener(Event.CLOSE, function(_) told.push("close"));
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) told.push("connect"));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// How Node reports a process out of descriptors: an error event on
			// a server that is listening.
			for (_ in 0...3) {
				@:privateAccess server.__serverSocket.emit("error", new js.lib.Error("accept EMFILE"));
			}

			var peer = new WirePeer(server.localPort);
			NetPump.until(() -> told.indexOf("connect") >= 0, 5.0, function(_) {
				Assert.same(["ioError", "connect"], told, "a connection Node could not take did not leave the server serving");
				Assert.equals(3, server.acceptFailures);
				Assert.isTrue(server.listening);
				peer.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testAHandshakeNeverSentIsDroppedAtTheHandshakeTimeout(async:Async):Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			async.done();
			return;
		}

		var server = new ServerSocket(true);
		server.handshakeTimeout = 0.3;
		server.setCertificate(fixture.certificate, fixture.key);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// Connects, and never says a word of TLS.
			var silent = new WirePeer(server.localPort);
			var started:Float = haxe.Timer.stamp();

			NetPump.until(() -> silent.ended, 5.0, function(_) {
				Assert.isTrue(silent.ended, "a client that never sent its handshake was still held after 5 s");
				Assert.isTrue(haxe.Timer.stamp() - started < 3.0, "the silent client was held past the handshake timeout");
				Assert.equals(1, server.handshakeFailures, "the dropped handshake was not counted");
				silent.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	@:timeout(15000)
	public function testAHandshakeFinishingAfterCloseIsLetGoOf(async:Async):Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			async.done();
			return;
		}

		var server = new ServerSocket(true);
		var connects:Int = 0;
		server.setCertificate(fixture.certificate, fixture.key);
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) connects++);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// Closed while the handshake is under way: asked whether to admit
			// the connection, the server closes, and the handshake goes on.
			server.admit = function(_, _) {
				server.close();
				return true;
			};

			var ended:Bool = false;
			var client:Dynamic = js.node.Tls.connect(cast {port: server.localPort, host: "127.0.0.1", rejectUnauthorized: false});
			client.on("close", function(_) ended = true);
			client.on("error", function(_) ended = true);

			NetPump.until(() -> ended, 5.0, function(_) {
				Assert.isTrue(ended, "a connection whose handshake finished after close() was kept open");
				Assert.equals(0, connects, "a connection was announced to a closed server");
				try client.destroy() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end
}
