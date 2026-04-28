package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;

class SocketSingleCase extends utest.Test {
	public function testClientServerEchoOverLocalhost():Void {
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var echoed:String = null;
		var connected = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var data = new ByteArray();
				serverPeer.readBytes(data, 0, serverPeer.bytesAvailable);
				serverPeer.writeBytes(data);
				serverPeer.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			client.writeUTFBytes("ping");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			echoed = client.readUTFBytes(client.bytesAvailable);
		});
		try {
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> echoed != null, 2.0);
			Assert.isTrue(connected);
			Assert.notNull(serverPeer);
			Assert.equals("ping", echoed);
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testIpv6ClientServerEchoOnLoopback():Void {
		if (!requireIpv6Loopback()) {
			Assert.pass();
			return;
		}

		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var echoed:String = null;
		var connected = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var data = new ByteArray();
				serverPeer.readBytes(data, 0, serverPeer.bytesAvailable);
				serverPeer.writeBytes(data);
				serverPeer.flush();
			});
		});
		server.bind(0, "::1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			client.writeUTFBytes("pong");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			echoed = client.readUTFBytes(client.bytesAvailable);
		});
		try {
			client.connect("::1", server.localPort);
			pumpUntil(() -> echoed != null, 2.0);
			Assert.isTrue(connected);
			Assert.notNull(serverPeer);
			Assert.equals("pong", echoed);
			Assert.equals("::1", server.localAddress);
			Assert.equals("::1", serverPeer.localAddress);
			Assert.equals("::1", client.remoteAddress);
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testServerSocketIdlePumpDoesNotClose():Void {
		var server = new ServerSocket();
		var closeEvents = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
		server.addEventListener(Event.CLOSE, _ -> closeEvents++);

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			CrossByte.current().pump(1 / 60, 0);
			Assert.isTrue(server.listening);
			Assert.equals(0, closeEvents);
		} catch (e:Dynamic) {
			closeServerQuietly(server);
			throw e;
		}

		closeServerQuietly(server);
	}

	public static function requireIpv6Loopback():Bool {
		var server = new ServerSocket();
		try {
			server.bind(0, "::1");
			server.close();
			return true;
		} catch (_:Dynamic) {
			try {
				server.close();
			} catch (_:Dynamic) {}
			return false;
		}
	}

	private static function closeQuietly(socket:Socket):Void {
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

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}
