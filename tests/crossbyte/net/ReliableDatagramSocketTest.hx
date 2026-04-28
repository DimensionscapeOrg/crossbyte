package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;

class ReliableDatagramSocketTest extends utest.Test {
	public function testDatagramModeHandshakeAndDeliveryOverLocalhost():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var delivered:String = null;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = event.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, dataEvent -> {
					dataEvent.data.position = 0;
					delivered = dataEvent.data.readUTFBytes(dataEvent.data.length);
				});
			});
			server.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);

			client.send(bytesOf("reliable"));
			pumpUntil(() -> delivered != null, 2.0);

			Assert.isTrue(client.connected);
			Assert.notNull(accepted);
			Assert.isTrue(accepted.connected);
			Assert.equals("reliable", delivered);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testStreamModeHandshakeAndDeliveryOverLocalhost():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var delivered:String = null;

		try {
			server.socketMode = STREAM;
			client.mode = STREAM;
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = event.socket;
				accepted.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
					delivered = accepted.readUTFBytes(accepted.bytesAvailable);
				});
			});
			server.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);

			client.writeUTFBytes("stream");
			client.flush();
			pumpUntil(() -> delivered != null, 2.0);

			Assert.equals("stream", delivered);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(accepted);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);
	}

	public function testConnectionTimeoutDispatchesIOErrorAndCloses():Void {
		if (!requireDatagramSupport()) return;

		var client = new ReliableDatagramSocket();
		var unused = new DatagramSocket();
		var errors = 0;
		var closes = 0;

		try {
			unused.bind(0, "127.0.0.1");
			var unusedPort = unused.localPort;
			unused.close();

			client.timeout = 10;
			client.addEventListener(IOErrorEvent.IO_ERROR, _ -> errors++);
			client.addEventListener(Event.CLOSE, _ -> closes++);
			client.connect("127.0.0.1", unusedPort);

			pumpUntil(() -> errors > 0, 1.0);

			Assert.equals(1, errors);
			Assert.equals(1, closes);
			Assert.isFalse(client.connected);
			Assert.isTrue(throwsIOError(() -> client.send(bytesOf("late"))));
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeDatagramQuietly(unused);
			throw e;
		}

		closeQuietly(client);
		closeDatagramQuietly(unused);
	}

	private static function requireDatagramSupport():Bool {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return false;
		}
		return true;
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeQuietly(socket:ReliableDatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeServerQuietly(server:ReliableDatagramServerSocket):Void {
		try {
			if (server != null) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeDatagramQuietly(socket:DatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function throwsIOError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IOError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}
