package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;

@:access(crossbyte.net.ServerWebSocket)
class NetHostTest extends utest.Test {
	public function testFromServerSocketAcceptsAndForwardsDisconnect():Void {
		var server = new ServerSocket();
		var host:NetHost = null;
		var client = new Socket();
		var accepted:INetConnection = null;
		var disconnectReason:Reason = null;

		try {
			server.bind(0, "127.0.0.1");
			host = NetHost.fromServerSocket(server, connection -> accepted = connection, (connection, reason) -> {
				if (accepted == connection) {
					disconnectReason = reason;
				}
			});
			host.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> accepted != null, 2.0);

			Assert.notNull(accepted);
			Assert.equals(Protocol.TCP, accepted.protocol);
			Assert.equals(server.localPort, host.localPort);

			client.close();
			pumpUntil(() -> disconnectReason != null, 2.0);

			Assert.equals(Reason.Closed, disconnectReason);
		} catch (e:Dynamic) {
			closeSocketQuietly(client);
			closeHostQuietly(host);
			throw e;
		}

		closeSocketQuietly(client);
		closeHostQuietly(host);
	}

	public function testListenIsIdempotentForSingleAcceptedClient():Void {
		var server = new ServerSocket();
		var host:NetHost = null;
		var client = new Socket();
		var accepts = 0;

		try {
			server.bind(0, "127.0.0.1");
			host = NetHost.fromServerSocket(server, _ -> accepts++);
			host.listen();
			host.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> accepts > 0, 2.0);

			Assert.equals(1, accepts);
		} catch (e:Dynamic) {
			closeSocketQuietly(client);
			closeHostQuietly(host);
			throw e;
		}

		closeSocketQuietly(client);
		closeHostQuietly(host);
	}

	public function testFromServerWebSocketWrapsAcceptedWebSocket():Void {
		var server = new ServerWebSocket();
		var accepted:INetConnection = null;
		var host = NetHost.fromServerWebSocket(server, connection -> accepted = connection);
		var socket = new WebSocket();

		server.bind(0, "127.0.0.1");
		host.listen();
		server.dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));

		Assert.notNull(accepted);
		Assert.equals(Protocol.WEBSOCKET, accepted.protocol);
		closeHostQuietly(host);
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeSocketQuietly(socket:Socket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeHostQuietly(host:NetHost):Void {
		try {
			if (host != null) {
				host.close();
			}
		} catch (_:Dynamic) {}
	}
}
