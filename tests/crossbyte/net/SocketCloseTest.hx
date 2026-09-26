package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	How a connection's end is seen: once, whatever ends it, and the same way
	on every target.

	Natively a peer that connected and hung up within a tick, a load
	balancer's health check, was announced closed twice, so a count of live
	connections drifted down by one for each. On Node a peer that left left
	its socket connected and flushed from every tick forever, and a peer that
	half-closed to end its request was cut off before it got its answer.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.events.EventDispatcher)
class SocketCloseTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(15000)
	public function testAQuickHangUpIsAnnouncedOnce(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Int = 0;
		var live:Int = 0;
		var closes:Array<Int> = [];

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var index:Int = accepted++;
			live++;
			closes.push(0);
			e.socket.addEventListener(Event.CLOSE, function(_) {
				closes[index]++;
				live--;
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// Connect and hang up at once, before a tick can pass.
			for (_ in 0...5) {
				new WirePeer(server.localPort).hangUp();
			}

			NetPump.until(() -> accepted == 5 && live == 0, 5.0, function(_) {
				// And long enough for anything announced late to arrive.
				NetPump.wait(0.3, function() {
					Assert.equals(5, accepted);
					Assert.same([1, 1, 1, 1, 1], closes, "a connection was not announced closed exactly once");
					Assert.equals(0, live, "the live count drifted");
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	@:timeout(15000)
	public function testAPeerThatLeavesEndsItsSocket(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		var closes:Int = 0;
		var before:Int = __tickListeners();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			accepted = e.socket;
			accepted.addEventListener(Event.CLOSE, function(_) closes++);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);

			NetPump.until(() -> accepted != null, 5.0, function(_) {
				peer.close();

				NetPump.until(() -> closes > 0, 5.0, function(_) {
					NetPump.wait(0.3, function() {
						Assert.equals(1, closes, "the peer leaving was not announced exactly once");
						Assert.isFalse(accepted != null && accepted.connected, "the socket still says it is connected after its peer left");
						// The listener's own accept tick is all that may be left,
						// and on Node a listener has none.
						var allowed:Int = #if nodejs 0 #else 1 #end;
						Assert.isTrue(__tickListeners() - before <= allowed, "the socket whose peer left is still visited every tick");
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}

	@:timeout(15000)
	public function testAHalfClosedPeerGetsItsAnswer(async:Async):Void {
		var server = new ServerSocket();
		var request:String = "";
		var peerClosed:Bool = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket = e.socket;
			socket.peerShutdownPolicy = HALF_OPEN;
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) request += socket.readUTFBytes(socket.bytesAvailable));
			socket.addEventListener(Event.PEER_CLOSE, function(_) {
				// The whole request is in: answer it, then close.
				peerClosed = true;
				socket.writeUTFBytes("ANSWER TO " + request);
				socket.flush();
				socket.close();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.send(Bytes.ofString("REQ"));
			peer.shutdownWrite();

			NetPump.until(() -> {
				peer.poll();
				return peer.ended;
			}, 5.0, function(_) {
				Assert.isTrue(peerClosed, "the half-close was never reported as one");
				Assert.equals("ANSWER TO REQ", peer.text(), "a peer that half-closed never got its answer");
				peer.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	#if nodejs
	/**
		An idle connection costs a Node runtime nothing a tick, and what is
		written to it without a flush still goes.

		Every Node socket was ticked for as long as it was open, to flush what
		had been written: a visit a tick for each connection, idle or not. A
		write now asks for a flush at the end of the pass, and a socket is
		ticked only while a streaming writer is feeding it.
	**/
	@:timeout(15000)
	public function testAnIdleNodeConnectionIsNotTicked(async:Async):Void {
		var before:Int = __tickListeners();
		var server = new ServerSocket();
		var accepted:Socket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted = e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			var got:String = "";
			client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) got += client.readUTFBytes(client.bytesAvailable));
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> accepted != null && client.connected, 5.0, function(_) {
				Assert.equals(before, __tickListeners(), "open connections are visited every tick");

				// Written, and never flushed.
				accepted.writeUTFBytes("unflushed");

				NetPump.until(() -> got == "unflushed", 5.0, function(_) {
					Assert.equals("unflushed", got, "a write without a flush never went");
					Assert.equals(before, __tickListeners(), "a connection that was written to is still visited every tick");
					try client.close() catch (_:Dynamic) {}
					try accepted.close() catch (_:Dynamic) {}
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end

	private static function __tickListeners():Int {
		var runtime:CrossByte = CrossByte.current();
		var listeners:Array<Dynamic> = runtime.__eventMap == null ? null : runtime.__eventMap.get(TickEvent.TICK);
		return listeners == null ? 0 : listeners.length;
	}
	#end
}
