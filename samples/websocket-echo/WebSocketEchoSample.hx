import crossbyte.core.HostApplication;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerWebSocket;
import crossbyte.net.WebSocket;
import haxe.Timer;

class WebSocketEchoSample extends HostApplication {
	private static inline var HOST:String = "127.0.0.1";
	private static inline var PORT:Int = 18080;
	private static inline var MESSAGE:String = "hello websocket";
	private static inline var TIMEOUT_SECONDS:Float = 5.0;

	public static function main():Void {
		var app = new WebSocketEchoSample();
		app.run();
	}

	public function new() {
		super();
	}

	private function run():Void {
		var server = new ServerWebSocket();
		var accepted:Array<WebSocket> = [];
		var done = false;
		var echoed:String = null;

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
			client.writeUTFBytes(MESSAGE);
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			echoed = client.readUTFBytes(client.bytesAvailable);
			Sys.println('echo: $echoed');
			done = true;
		});
		client.connect(HOST, PORT);

		var deadline = Timer.stamp() + TIMEOUT_SECONDS;
		while (!done && Timer.stamp() < deadline) {
			advance(1 / 60, 0);
			Sys.sleep(0.001);
		}

		for (socket in accepted) {
			closeQuietly(socket);
		}
		closeQuietly(client);
		try {
			server.close();
		} catch (_:Dynamic) {}
		shutdown();

		// Reported as an explicit exit status rather than a thrown error so
		// this doubles as a CI check: an uncaught throw leaves hxcpp exiting
		// 127, which reads as "command not found" in a build log.
		if (!done) {
			Sys.println('FAIL: no echo received within ${TIMEOUT_SECONDS}s.');
			Sys.exit(1);
		}

		// Checked rather than assumed: without this the round trip "passes"
		// on any bytes coming back, including the wrong ones.
		if (echoed != MESSAGE) {
			Sys.println('FAIL: expected "$MESSAGE", received "$echoed".');
			Sys.exit(1);
		}

		Sys.println("OK: websocket echo round trip completed.");
	}

	private static function closeQuietly(socket:WebSocket):Void {
		try {
			if (socket != null && socket.connected) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}
