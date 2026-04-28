import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.Timer;

@:access(crossbyte.core.CrossByte)
class WebSocketEchoSample {
	private static inline var HOST:String = "127.0.0.1";
	private static inline var PORT:Int = 18080;

	public static function main():Void {
		var runtime = new CrossByte(true, DEFAULT, true);
		var server = new ServerWebSocket();
		var accepted:Array<WebSocket> = [];
		var done = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			var peer:WebSocket = cast event.socket;
			accepted.push(peer);
			peer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var data = new ByteArray();
				peer.readBytes(data, 0, peer.bytesAvailable);
				peer.writeBytes(data);
				peer.flush();
			});
		});

		server.bind(PORT, HOST);
		server.listen();

		var client = new WebSocket();
		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("hello websocket");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			var message = client.readUTFBytes(client.bytesAvailable);
			Sys.println('echo: $message');
			done = true;
		});
		client.connect(HOST, PORT);

		var deadline = Timer.stamp() + 5.0;
		while (!done && Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}

		for (socket in accepted) {
			closeQuietly(socket);
		}
		closeQuietly(client);
		try {
			server.close();
		} catch (_:Dynamic) {}
		runtime.exit();

		if (!done) {
			throw "Timed out waiting for websocket echo.";
		}
	}

	private static function closeQuietly(socket:WebSocket):Void {
		try {
			if (socket != null && socket.connected) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}
