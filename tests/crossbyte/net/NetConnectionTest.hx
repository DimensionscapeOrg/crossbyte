package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;

@:access(crossbyte.net.Socket)
@:access(crossbyte.net.WebSocket)
class NetConnectionTest extends utest.Test {
	public function testFromSocketWithConnectedSocketInvokesReadyCallback():Void {
		#if !cpp
		Assert.isTrue(true);
		return;
		#end

		var server = new ServerSocket();
		var client = new Socket();
		var accepted:Socket = null;
		var readyCount = 0;
		var wrapped:NetConnection = null;

		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, event -> {
			accepted = event.socket;
		});

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			client.connect("127.0.0.1", server.localPort);

			pumpUntil(() -> accepted != null, 2.0);

			wrapped = NetConnection.fromSocketWith(accepted, null, () -> readyCount++, null, null);

			Assert.notNull(wrapped);
			Assert.equals(1, readyCount);
			Assert.isTrue(wrapped.connected);
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

	public function testUdpConnectionReceivesDataWhenReadEnabled():Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		var receiverSocket = new DatagramSocket();
		var sender:NetConnection = null;
		var receiver:NetConnection = null;
		var received:String = null;

		try {
			receiverSocket.bind(0, "127.0.0.1");
			receiver = NetConnection.fromDatagramSocket(receiverSocket);
			receiver.onData = input -> {
				received = input.readUTFBytes(input.length);
			};
			receiver.readEnabled = true;

			sender = new NetConnection('udp://127.0.0.1:${receiverSocket.localPort}');
			sender.send(bytesOf("ping"));

			pumpUntil(() -> received != null, 2.0);

			Assert.equals("ping", received);
			Assert.equals(Protocol.UDP, receiver.protocol);
			Assert.equals(receiverSocket.localPort, receiver.localPort);
		} catch (e:Dynamic) {
			closeDatagramQuietly(receiverSocket);
			closeNetQuietly(sender);
			throw e;
		}

		closeDatagramQuietly(receiverSocket);
		closeNetQuietly(sender);
	}

	public function testWebSocketConnectionAdaptsReadyDataAndCloseEvents():Void {
		var socket = new WebSocket();
		var connection = NetConnection.fromWebSocket(socket);
		var readyCount = 0;
		var closed:Reason = null;
		var received:String = null;

		connection.onReady = () -> readyCount++;
		connection.onClose = reason -> closed = reason;
		connection.onData = input -> {
			received = input.readUTFBytes(input.length);
		};
		connection.readEnabled = true;

		socket.__input = new ByteArray();
		socket.__input.writeUTFBytes("hello");
		socket.__input.position = 0;
		socket.dispatchEvent(new Event(Event.CONNECT));
		socket.dispatchEvent(new ProgressEvent(ProgressEvent.SOCKET_DATA, socket.__input.length, 0));
		socket.dispatchEvent(new Event(Event.CLOSE));

		Assert.equals(1, readyCount);
		Assert.equals("hello", received);
		Assert.equals(Reason.Closed, closed);
		Assert.equals(socket, NetConnection.toWebSocket(connection));
		Assert.isNull(NetConnection.toDatagramSocket(connection));
	}

	public function testReliableDatagramConnectionReceivesDataWhenReadEnabled():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client:NetConnection = null;
		var accepted:NetConnection = null;
		var received:String = null;
		var readyCount = 0;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
				accepted = NetConnection.fromReliableDatagramSocket(event.socket);
				accepted.onData = input -> received = input.readUTFBytes(input.length);
				accepted.readEnabled = true;
			});
			server.listen();

			client = new NetConnection('rudp://127.0.0.1:${server.localPort}', null, () -> readyCount++);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 2.0);

			client.send(bytesOf("reliable"));
			pumpUntil(() -> received != null, 2.0);

			Assert.equals(1, readyCount);
			Assert.equals(Protocol.RUDP, client.protocol);
			Assert.equals(Protocol.RUDP, accepted.protocol);
			Assert.equals("reliable", received);
			Assert.notNull(NetConnection.toReliableDatagramSocket(client));
			Assert.isNull(NetConnection.toSocket(client));
		} catch (e:Dynamic) {
			closeNetQuietly(client);
			closeNetQuietly(accepted);
			closeReliableServerQuietly(server);
			throw e;
		}

		closeNetQuietly(client);
		closeNetQuietly(accepted);
		closeReliableServerQuietly(server);
	}

	public function testDatagramSocketExtractorReturnsWrappedSocket():Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		var socket = new DatagramSocket();
		var connection = NetConnection.fromDatagramSocket(socket);

		Assert.equals(socket, NetConnection.toDatagramSocket(connection));
		Assert.isNull(NetConnection.toReliableDatagramSocket(connection));
		closeDatagramQuietly(socket);
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

	private static function closeQuietly(socket:Socket):Void {
		try {
			if (socket != null && socket.__socket != null) {
				socket.close();
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

	private static function closeServerQuietly(server:ServerSocket):Void {
		try {
			if (server != null && server.listening) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeNetQuietly(connection:NetConnection):Void {
		try {
			if (connection != null) {
				connection.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeReliableServerQuietly(server:ReliableDatagramServerSocket):Void {
		try {
			if (server != null) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}
}
