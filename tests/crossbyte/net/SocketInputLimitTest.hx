package crossbyte.net;

#if !(js && !nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
#end
import utest.Assert;
import utest.Async;

/**
	`Socket.maxInputBufferSize`: what a peer can make a connection hold that
	its application has not read.

	There was no limit. One peer sending to a connection whose application
	read a message a tick made a server hold 664 MB in a second; here a
	connection holds its limit and no more, and under the default policy
	the rest waits on the peer, TCP's window holding it back, and arrives
	whole once the application reads.
**/
class SocketInputLimitTest extends utest.Test {
	/** Backpressure, at 16 MiB, unless the application says otherwise. **/
	public function testTheDefaultIsBackpressureAtSixteenMegabytes():Void {
		var socket = new Socket();
		Assert.equals(16 * 1024 * 1024, Socket.DEFAULT_MAX_INPUT_BUFFER_SIZE);
		Assert.equals(Socket.DEFAULT_MAX_INPUT_BUFFER_SIZE, socket.maxInputBufferSize);
		Assert.equals(InputOverflowPolicy.PAUSE, socket.inputOverflowPolicy);
	}

	#if !(js && !nodejs)
	private static inline var LIMIT:Int = 64 * 1024;
	// Past the limit by one read: a TLS record natively, or one of Node's
	// reads, 64 KB.
	private static inline var READ:Int = 64 * 1024;

	#if !eval
	// Not on eval, whose sockets block: a client writing to a server that has
	// stopped reading waits there, on the runtime the server needs.

	/**
		A connection whose application reads nothing holds its limit and no
		more, however much its peer sends; once the application reads, the
		rest arrives, all of it and in order.
	**/
	@:timeout(60000)
	public function testAnUnreadConnectionHoldsItsLimitThenTakesTheRest(async:Async):Void {
		var total:Int = 4 * 1024 * 1024;
		__pair(PAUSE, LIMIT, function(server:ServerSocket, client:Socket, accepted:Socket, done:Void->Void):Void {
			// Fed 64 KB at a time while the peer's own buffer has room, as a
			// sender of messages writes: Windows takes a single send whole,
			// however large.
			var pattern:ByteArray = __pattern(total);
			var written:Int = 0;
			function feed():Bool {
				while (written < total && client.connected && client.bytesPending < 128 * 1024) {
					var piece:Int = total - written < 64 * 1024 ? total - written : 64 * 1024;
					client.writeBytes(pattern, written, piece);
					client.flush();
					written += piece;
				}
				return false;
			}
			NetPump.until(feed, 1.0, function(_):Void {
				var held:Int = accepted.bytesAvailable;
				Assert.isTrue(held > 0, "nothing arrived");
				Assert.isTrue(held <= LIMIT + READ, "a connection read nothing and held " + held + " bytes, over its limit of " + LIMIT);
				Assert.isTrue(accepted.connected, "a connection at its limit was closed under PAUSE");
				#if (cpp || java || jvm)
				// The peer's own kernel buffer and this side's were asked for
				// small, so what the server did not read waited at the sender.
				Assert.isTrue(written < total || client.bytesPending > 0, "the peer was not held back: it sent everything");
				#end

				var received = new ByteArray();
				var most:Int = held;
				function take():Void {
					var available:Int = accepted.bytesAvailable;
					if (available > most) {
						most = available;
					}
					if (available > 0) {
						accepted.readBytes(received, received.length, available);
					}
				}
				take();
				accepted.addEventListener(ProgressEvent.SOCKET_DATA, _ -> take());
				NetPump.until(() -> {
					feed();
					return received.length >= total;
				}, 30.0, function(_):Void {
					Assert.equals(total, received.length, "the rest did not arrive once the application read");
					Assert.isTrue(__matches(received, total), "what arrived was not what was sent");
					Assert.isTrue(most <= LIMIT + READ, "the connection held " + most + " bytes at once");
					done();
				});
			});
		}, async);
	}

	/**
		Under `CLOSE`, a peer sending past the limit to an application not
		reading has its connection closed, with an `ioError` saying why, and
		no more than the limit was held for it.
	**/
	@:timeout(30000)
	public function testAPeerSendingPastTheLimitIsClosedUnderClose(async:Async):Void {
		__pair(CLOSE, LIMIT, function(server:ServerSocket, client:Socket, accepted:Socket, done:Void->Void):Void {
			var said:String = null;
			var closed:Bool = false;
			var heldAtError:Int = -1;
			accepted.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> {
				said = e.text;
				heldAtError = accepted.bytesAvailable;
			});
			accepted.addEventListener(Event.CLOSE, _ -> closed = true);
			client.writeBytes(__pattern(1024 * 1024));
			client.flush();
			NetPump.until(() -> closed, 10.0, function(_):Void {
				Assert.isTrue(closed, "a peer sending past the limit was not closed under CLOSE");
				Assert.notNull(said, "the close came without an ioError saying why");
				Assert.isTrue(said != null && said.indexOf("maxInputBufferSize") >= 0, "the ioError did not name the limit: " + said);
				Assert.isTrue(heldAtError >= 0 && heldAtError <= LIMIT + READ, "the connection held " + heldAtError + " bytes before it was closed");
				done();
			});
		}, async);
	}

	/** `0` holds whatever arrives, as before there was a limit. **/
	@:timeout(30000)
	public function testNoLimitHoldsWhatArrives(async:Async):Void {
		var total:Int = 1024 * 1024;
		__pair(PAUSE, 0, function(server:ServerSocket, client:Socket, accepted:Socket, done:Void->Void):Void {
			client.writeBytes(__pattern(total));
			client.flush();
			NetPump.until(() -> accepted.bytesAvailable >= total, 10.0, function(_):Void {
				Assert.equals(total, accepted.bytesAvailable, "a connection with no limit did not take what arrived");
				done();
			});
		}, async);
	}

	#if (cpp || java || jvm || nodejs)
	/**
		Over TLS, read a little at a time while the limit stops and starts
		the reads: everything arrives, whole. A TLS read asked for less than
		its record leaves the rest decrypted inside the session, where a poll
		cannot see it; the socket reads a whole record or none.
	**/
	@:timeout(60000)
	public function testATlsConnectionStoppedAndStartedLosesNothing(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TLS case did not run");
			async.done();
			return;
		}
		var total:Int = 1024 * 1024;
		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		var accepted:Socket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> {
			accepted = e.socket;
			accepted.maxInputBufferSize = 32 * 1024;
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		var client = new Socket();
		client.secure = true;
		client.certAuthority = fixture.certificate;
		var connected:Bool = false;
		client.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			client.writeBytes(__pattern(total));
			client.flush();
		});
		var received = new ByteArray();
		var most:Int = 0;
		function finish():Void {
			try client.close() catch (_:Dynamic) {}
			if (accepted != null) {
				try accepted.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			async.done();
		}
		NetPump.until(() -> server.localPort != 0, 5.0, function(_):Void {
			client.connect("127.0.0.1", server.localPort);
			// A slow reader: 8 KB a turn.
			NetPump.until(function():Bool {
				if (accepted != null) {
					var available:Int = accepted.bytesAvailable;
					if (available > most) {
						most = available;
					}
					var take:Int = available < 8 * 1024 ? available : 8 * 1024;
					if (take > 0) {
						accepted.readBytes(received, received.length, take);
					}
				}
				return received.length >= total;
			}, 40.0, function(_):Void {
				Assert.isTrue(connected, "the secure client never connected");
				Assert.equals(total, received.length, "a TLS connection read slowly under its limit lost bytes");
				Assert.isTrue(__matches(received, total), "what arrived over TLS was not what was sent");
				Assert.isTrue(most <= 32 * 1024 + READ, "the TLS connection held " + most + " bytes at once");
				finish();
			});
		});
	}
	#end

	#end

	/**
		A server and a client connected to it, the accepted end given `limit`
		and `policy` before anything arrives; `run` is handed both, and a
		`done` that closes everything and ends the case.
	**/
	private static function __pair(policy:InputOverflowPolicy, limit:Int, run:(ServerSocket, Socket, Socket, Void->Void) -> Void, async:Async):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		#if (cpp || java || jvm)
		// Small kernel buffers both ways, so what is held back is held at the
		// sender rather than taken by the kernel's.
		server.receiveBufferSize = 32 * 1024;
		#end
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> {
			accepted = e.socket;
			accepted.maxInputBufferSize = limit;
			accepted.inputOverflowPolicy = policy;
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		var client = new Socket();
		#if (cpp || java || jvm)
		client.sendBufferSize = 32 * 1024;
		#end
		var connected:Bool = false;
		client.addEventListener(Event.CONNECT, _ -> connected = true);
		function done():Void {
			try client.close() catch (_:Dynamic) {}
			if (accepted != null) {
				try accepted.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			async.done();
		}
		NetPump.until(() -> server.localPort != 0, 5.0, function(_):Void {
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> connected && accepted != null, 5.0, function(up:Bool):Void {
				if (!up) {
					Assert.fail("the connection never came up");
					done();
					return;
				}
				run(server, client, accepted, done);
			});
		});
	}

	private static function __pattern(length:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		for (i in 0...length) {
			bytes[i] = (i * 31 + (i >> 8)) & 0xFF;
		}
		bytes.position = 0;
		return bytes;
	}

	private static function __matches(bytes:ByteArray, length:Int):Bool {
		if (bytes.length != length) {
			return false;
		}
		for (i in 0...length) {
			if (bytes[i] != (i * 31 + (i >> 8)) & 0xFF) {
				return false;
			}
		}
		return true;
	}
	#end
}
