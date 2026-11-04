package crossbyte.net;

import utest.Assert;
#if (cpp || java || jvm)
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
#end

/**
	What a secure socket writes arrives as it was written, when the system
	refuses part of it on the way. mbedTLS finishes a refused write from the
	record it has already made, and answers the length it is given then, so a
	socket that asked again for more than it was refused for was told bytes had
	gone that had not: the stream lost them with nothing said at either end. On
	the jvm the TLS socket finishes a record the system took part of, and held
	the end of what was written until something more was written or read.
**/
@:timeout(40000)
@:access(crossbyte.net.Socket)
class SocketSecureWriteTest extends utest.Test {
	#if (cpp || java || jvm)
	/**
		Every byte of a stream checked at the far end, in each size of write,
		a slice at a time and more when there is room, as a proxy or a download
		writes. Lost, it stops short of its length with the bytes after the gap
		a record out of place: on Windows natively 8 MiB read 8.2 MB, wrong from
		a few hundred kilobytes in, on every run.
	**/
	public function testAStreamArrivesWholeWhateverIsRefused():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}
		for (slice in [1024, 4096, 64 * 1024]) {
			__stream(fixture, slice);
		}
	}

	/**
		A WebSocket session writes through a buffer of its own, and retries it
		the same way: what went missing there cut a frame, which a client
		reads as nonsense and closes on.
	**/
	public function testAWebSocketSessionArrivesWholeWhateverIsRefused():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}

		var writer:CrossByte = SpreadSupport.runtime(60);
		var reader:CrossByte = SpreadSupport.runtime(60);
		var session:Null<WebSocket> = null;
		var server:ServerWebSocket = SpreadSupport.on(writer, () -> {
			var listener:ServerWebSocket = new ServerWebSocket(true);
			listener.cert = {certificate: fixture.certificate, key: fixture.key};
			listener.addEventListener(ServerSocketConnectEvent.CONNECT, e -> session = cast e.socket);
			listener.bind(0, "127.0.0.1");
			listener.listen();
			return listener;
		});

		var messages:Int = #if (cpp || java || jvm) 128 #else 32 #end;
		var size:Int = 64 * 1024;
		var got:Int = 0;
		var wrong:Int = -1;
		var ended:Bool = false;
		var client:WebSocket = SpreadSupport.on(reader, () -> {
			var socket:WebSocket = new WebSocket();
			socket.secure = true;
			socket.verifyCert = false;
			socket.maxMessageSize = size * 2;
			socket.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent):Void {
				var data:ByteArray = e.data;
				if (wrong < 0 && (data.length != size || data[0] != (got & 0xFF) || data[size - 1] != (got & 0xFF))) {
					wrong = got;
				}
				got++;
			});
			socket.addEventListener(Event.CLOSE, _ -> ended = true);
			socket.connect("127.0.0.1", server.localPort);
			return socket;
		});
		Assert.isTrue(SpreadSupport.waitFor(() -> session != null, 10.0), "no session opened");

		// Written a piece at a time with a backlog kept, so what waits has
		// grown by the time the system takes a write it refused.
		var sent:Int = 0;
		SpreadSupport.waitFor(() -> {
			SpreadSupport.on(writer, () -> {
				while (sent < messages && session.connected && session.outputBufferLength < 256 * 1024) {
					var piece:ByteArray = new ByteArray();
					for (i in 0...size) {
						piece.writeByte(sent & 0xFF);
					}
					session.sendBinary(piece);
					sent++;
				}
				return true;
			});
			return sent >= messages || ended;
		}, 20.0);
		SpreadSupport.waitFor(() -> got >= messages || ended, 10.0);

		SpreadSupport.on(writer, () -> {
			server.close();
			if (session.connected) {
				session.close();
			}
			return true;
		});
		SpreadSupport.on(reader, () -> {
			if (client.connected) {
				client.close();
			}
			return true;
		});
		SpreadSupport.stop([writer, reader]);

		Assert.isFalse(ended && got < messages, 'the client closed at message $got of $messages');
		Assert.equals(messages, got, "messages were lost on the way");
		Assert.equals(-1, wrong, 'message $wrong was not as it was sent');
	}

	/**
		A peer reading a little at a time leaves room a little at a time, so
		a record is often taken in part, and the last one with it. On the jvm
		the rest of that record stayed in the TLS socket with nothing to send
		it, and a session's last message never finished arriving.
	**/
	public function testAWebSocketSessionReadSlowlyGetsItsEnd():Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the case did not run");
			return;
		}

		var writer:CrossByte = SpreadSupport.runtime(60);
		var reader:CrossByte = SpreadSupport.runtime(60);
		var session:Null<WebSocket> = null;
		var server:ServerWebSocket = SpreadSupport.on(writer, () -> {
			var listener:ServerWebSocket = new ServerWebSocket(true);
			listener.cert = {certificate: fixture.certificate, key: fixture.key};
			listener.addEventListener(ServerSocketConnectEvent.CONNECT, e -> session = cast e.socket);
			listener.bind(0, "127.0.0.1");
			listener.listen();
			return listener;
		});

		var client:Socket = SpreadSupport.on(reader, () -> {
			var socket:Socket = new Socket();
			socket.secure = true;
			socket.verifyCert = false;
			socket.maxInputBufferSize = 32 * 1024;
			socket.addEventListener(Event.CONNECT, function(_):Void {
				socket.writeUtfBytes("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
					+ "Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nSec-WebSocket-Version: 13\r\n\r\n");
				socket.flush();
			});
			socket.connect("127.0.0.1", server.localPort);
			return socket;
		});
		Assert.isTrue(SpreadSupport.waitFor(() -> session != null, 10.0), "no session opened");

		// Less than a frame's worth each, so each is one frame of four bytes and itself.
		var messages:Int = 16;
		var size:Int = 60 * 1024;
		SpreadSupport.on(writer, () -> {
			var message:ByteArray = new ByteArray();
			for (i in 0...size) {
				message.writeByte(0x5A);
			}
			for (i in 0...messages) {
				session.sendBinary(message);
			}
			return true;
		});

		var received:ByteArray = new ByteArray();
		var wanted:Int = -1;
		var seen:Int = -1;
		var quietSince:Float = haxe.Timer.stamp();
		SpreadSupport.waitFor(() -> {
			SpreadSupport.on(reader, () -> {
				var take:Int = client.bytesAvailable < 8 * 1024 ? client.bytesAvailable : 8 * 1024;
				if (take > 0) {
					client.readBytes(received, received.length, take);
				}
				return true;
			});
			if (wanted < 0) {
				var head:Int = received.toString().indexOf("\r\n\r\n");
				if (head >= 0) {
					wanted = head + 4 + messages * (4 + size);
				}
			}
			if (received.length != seen) {
				seen = received.length;
				quietSince = haxe.Timer.stamp();
			}
			return (wanted > 0 && received.length >= wanted) || haxe.Timer.stamp() - quietSince > 4.0;
		}, 30.0);

		SpreadSupport.on(writer, () -> {
			server.close();
			if (session.connected) {
				session.close();
			}
			return true;
		});
		SpreadSupport.on(reader, () -> {
			if (client.connected) {
				client.close();
			}
			return true;
		});
		SpreadSupport.stop([writer, reader]);

		Assert.isTrue(wanted > 0, "the upgrade was never answered");
		Assert.equals(wanted, received.length, "the end of a message read slowly never came");
	}

	private function __stream(fixture:TLSTestFixture.TLSFixtureData, slice:Int):Void {
		var writer:CrossByte = SpreadSupport.runtime(60);
		var reader:CrossByte = SpreadSupport.runtime(60);
		var accepted:Null<Socket> = null;
		var server:ServerSocket = SpreadSupport.on(writer, () -> {
			var listener:ServerSocket = new ServerSocket(true);
			listener.setCertificate(fixture.certificate, fixture.key);
			listener.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			listener.bind(0, "127.0.0.1");
			listener.listen();
			return listener;
		});

		var total:Int = #if (cpp || java || jvm) 8 * 1024 * 1024 #else 2 * 1024 * 1024 #end;
		var got:Int = 0;
		var firstWrong:Int = -1;
		var client:Socket = SpreadSupport.on(reader, () -> {
			var socket:Socket = new Socket();
			socket.secure = true;
			socket.verifyCert = false;
			var sink:ByteArray = new ByteArray();
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				sink.clear();
				var arrived:Int = socket.bytesAvailable;
				socket.readBytes(sink, 0, arrived);
				for (i in 0...arrived) {
					if (firstWrong < 0 && sink[i] != ((got + i) & 0xFF)) {
						firstWrong = got + i;
					}
				}
				got += arrived;
			});
			socket.connect("127.0.0.1", server.localPort);
			return socket;
		});
		Assert.isTrue(SpreadSupport.waitFor(() -> accepted != null, 10.0), "the connection was never accepted");

		var left:Int = total;
		SpreadSupport.on(writer, () -> {
			var piece:ByteArray = new ByteArray();
			for (i in 0...slice) {
				piece.writeByte(i & 0xFF);
			}
			function more():Void {
				while (left > 0 && accepted.connected && accepted.bytesPending < 256 * 1024) {
					accepted.writeBytes(piece, 0, slice);
					accepted.flush();
					left -= slice;
				}
			}
			accepted.__onWritableDrain = more;
			more();
			return true;
		});

		// Until it has all come, or nothing has for a while.
		var seen:Int = -1;
		var quietSince:Float = haxe.Timer.stamp();
		SpreadSupport.waitFor(() -> {
			if (got != seen) {
				seen = got;
				quietSince = haxe.Timer.stamp();
			}
			return got >= total || haxe.Timer.stamp() - quietSince > 4.0;
		}, 30.0);

		SpreadSupport.on(writer, () -> {
			accepted.__onWritableDrain = null;
			server.close();
			if (accepted.connected) {
				accepted.close();
			}
			return true;
		});
		SpreadSupport.on(reader, () -> {
			if (client.connected) {
				client.close();
			}
			return true;
		});
		SpreadSupport.stop([writer, reader]);

		Assert.equals(total, got, 'a stream written $slice bytes at a time lost bytes on the way');
		Assert.equals(-1, firstWrong, 'a stream written $slice bytes at a time was wrong from byte $firstWrong');
	}
	#end
}
