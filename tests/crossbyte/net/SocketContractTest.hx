package crossbyte.net;

import crossbyte.errors.RangeError;
import crossbyte.errors.SecurityError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import utest.Async;

/**
	What `Socket`'s documentation promises, held to it.

	- The constructor promised a `SecurityError` for a port outside 0-65535,
	  and quietly made a socket that never connected.
	- `writeBytes` promised a `RangeError` for an offset or length past the
	  bytes given, and quietly wrote whatever part of them there was.
	- A `timeout` of 0 failed every native connect at once, where on Node it
	  meant no deadline; it means no deadline everywhere now.
	- Bytes written and then closed straight away were thrown away: every
	  write goes at the end of the pass, and `close()` came first.
**/
class SocketContractTest extends utest.Test {
	public function testAConstructorPortOutOfRangeIsASecurityError():Void {
		Assert.raises(() -> new Socket("127.0.0.1", 65536), SecurityError);
		Assert.raises(() -> new Socket("127.0.0.1", -1), SecurityError);
		// And no port is no connect, as before.
		var idle = new Socket(null, 0);
		Assert.isFalse(idle.connected);
	}

	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(15000)
	public function testWriteBytesPastTheBytesGivenIsARangeError(async:Async):Void {
		__connected(function(client, peer, done) {
			var bytes = new ByteArray();
			bytes.writeUTFBytes("abcd");

			Assert.raises(() -> client.writeBytes(bytes, 5), RangeError);
			Assert.raises(() -> client.writeBytes(bytes, 1, 4), RangeError);
			Assert.raises(() -> client.writeBytes(bytes, -1), RangeError);
			Assert.raises(() -> client.writeBytes(bytes, 0, -1), RangeError);
			// At the end is in range: nothing to write.
			client.writeBytes(bytes, 4);
			client.writeBytes(bytes, 1, 2);
			client.flush();

			NetPump.until(() -> peer.heard.length >= 2, 5.0, function(_) {
				Assert.equals("bc", peer.heard, "what was in range did not arrive alone");
				done();
			});
		}, async);
	}

	@:timeout(15000)
	public function testWhatIsWrittenBeforeCloseIsSent(async:Async):Void {
		__connected(function(client, peer, done) {
			client.writeUTFBytes("last words");
			client.close();

			NetPump.until(() -> peer.heard.length >= 10 || peer.ended, 5.0, function(_) {
				NetPump.wait(0.2, function() {
					Assert.equals("last words", peer.heard, "what was written just before close() was thrown away");
					done();
				});
			});
		}, async);
	}

	/**
		A socket's ends read null and 0 while it has none, before
		`connect()` and after `close()`, and the ones it was given while
		connected. Asking dereferenced a socket that was not there, so a
		close handler asking whom it had talked to threw, natively, and on
		the jvm an RPC session started on a connection still connecting
		threw a NullPointerException from `localAddress`.
	**/
	@:timeout(15000)
	public function testItsEndsReadNothingWhileItHasNone(async:Async):Void {
		var idle = new Socket();
		try {
			Assert.isNull(idle.localAddress, "an unconnected socket has a local address");
			Assert.equals(0, idle.localPort);
			Assert.isNull(idle.remoteAddress, "an unconnected socket has a remote address");
			Assert.equals(0, idle.remotePort);
		} catch (e:Dynamic) {
			Assert.fail("asking an unconnected socket for its ends threw: " + e);
		}

		__connected(function(client, peer, done) {
			Assert.equals("127.0.0.1", client.remoteAddress);
			Assert.isTrue(client.remotePort > 0);
			Assert.equals("127.0.0.1", client.localAddress);
			Assert.isTrue(client.localPort > 0);

			client.close();
			try {
				Assert.isNull(client.localAddress, "a closed socket still has a local address");
				Assert.equals(0, client.localPort);
				Assert.isNull(client.remoteAddress, "a closed socket still has a remote address");
				Assert.equals(0, client.remotePort);
			} catch (e:Dynamic) {
				Assert.fail("asking a closed socket for its ends threw: " + e);
			}
			done();
		}, async);
	}

	/**
		A `socketData` event's `bytesLoaded` is what arrived for it, as the
		native read loop has always said; on Node and in a page it was
		everything still unread, so an event for 4 bytes said 7 when the 3
		before them were not yet read.
	**/
	@:timeout(15000)
	public function testBytesLoadedIsWhatArrived(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted = e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			var loaded:Array<Int> = [];
			// Read nothing, so what arrives first is still unread when the
			// rest does.
			client.addEventListener(ProgressEvent.SOCKET_DATA, function(e:ProgressEvent) loaded.push(e.bytesLoaded));
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> client.connected && accepted != null, 5.0, function(_) {
				accepted.writeUTFBytes("abc");
				accepted.flush();

				NetPump.until(() -> loaded.length >= 1, 5.0, function(_) {
					accepted.writeUTFBytes("defg");
					accepted.flush();

					NetPump.until(() -> client.bytesAvailable >= 7, 5.0, function(_) {
						Assert.same([3, 4], loaded, "bytesLoaded was not what arrived for each event");
						Assert.equals(7, client.bytesAvailable);
						try client.close() catch (_:Dynamic) {}
						try accepted.close() catch (_:Dynamic) {}
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}

	@:timeout(15000)
	public function testATimeoutOfZeroConnects(async:Async):Void {
		__connected(function(client, peer, done) {
			Assert.isTrue(client.connected);
			done();
		}, async, 0);
	}
	#end

	/**
		And over TLS, where the deadline counts the handshake: a peer that
		never answers it is waited on, not given up on at once. Not on eval,
		whose handshake holds the runtime until it is done.
	**/
	#if (cpp || java || jvm || nodejs)
	@:timeout(15000)
	public function testATimeoutOfZeroWaitsForAHandshake(async:Async):Void {
		var server = new ServerSocket();
		var silent:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) silent.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			var failure:String = null;
			client.secure = true;
			client.verifyCert = false;
			client.timeout = 0;
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
			client.connect("127.0.0.1", server.localPort);

			NetPump.wait(1.0, function() {
				Assert.isNull(failure, "a connect with no deadline was given up on: " + failure);
				try client.close() catch (_:Dynamic) {}
				for (peer in silent) {
					try peer.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	#if (cpp || java || jvm || eval || nodejs)
	/** A client connected to a server that keeps what it hears, and `then` once it is. **/
	private function __connected(then:(Socket, Heard, Void->Void)->Void, async:Async, ?timeout:Int):Void {
		var server = new ServerSocket();
		var peer = new Heard();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket = e.socket;
			accepted.push(socket);
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) peer.heard += socket.readUTFBytes(socket.bytesAvailable));
			socket.addEventListener(Event.CLOSE, function(_) peer.ended = true);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			var failure:String = null;
			if (timeout != null) {
				client.timeout = timeout;
			}
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> (client.connected && accepted.length > 0) || failure != null, 5.0, function(_) {
				if (!client.connected) {
					Assert.fail("the client never connected: " + failure);
					try server.close() catch (_:Dynamic) {}
					async.done();
					return;
				}
				then(client, peer, function() {
					try client.close() catch (_:Dynamic) {}
					for (socket in accepted) {
						try socket.close() catch (_:Dynamic) {}
					}
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end
}

private class Heard {
	public var heard:String = "";
	public var ended:Bool = false;

	public function new() {}
}
