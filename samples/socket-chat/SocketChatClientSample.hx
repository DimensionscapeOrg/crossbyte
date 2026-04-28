import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.net.Socket;
import sys.thread.Deque;
import sys.thread.Thread;

@:access(crossbyte.core.CrossByte)
class SocketChatClientSample {
	public static function main():Void {
		var args = Sys.args();
		var host = args.length > 0 ? args[0] : SocketChatCommon.DEFAULT_HOST;
		var port = SocketChatCommon.parsePort(args, 1, SocketChatCommon.DEFAULT_PORT);
		var requestedName = args.length > 2 ? args[2] : "guest";

		var runtime = new CrossByte(true, DEFAULT, true);
		var socket = new Socket();
		var inbox = new ChatInbox();
		var consoleQueue:Deque<String> = new Deque();
		var running = true;
		var connected = false;

		Thread.create(() -> readConsole(consoleQueue));

		socket.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			Sys.println('[client] connected to ${host}:${port}');
			Sys.println("[client] commands: /nick <name>, /who, /quit");
			SocketChatCommon.sendFrame(socket, '/nick ${SocketChatCommon.sanitizeName(requestedName, "guest")}');
		});

		socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			SocketChatCommon.pumpIncoming(socket, inbox, message -> Sys.println(message));
		});

		socket.addEventListener(IOErrorEvent.IO_ERROR, event -> {
			Sys.println('[client] connection error: ${event.text}');
			running = false;
		});

		socket.addEventListener(Event.CLOSE, _ -> {
			Sys.println("[client] disconnected");
			running = false;
		});

		socket.connect(host, port);

		try {
			while (running) {
				drainConsole(consoleQueue, socket, connected, value -> running = value);
				runtime.pump(SocketChatCommon.PUMP_INTERVAL, 0);
				Sys.sleep(0.001);
			}
		} catch (error:Dynamic) {
			try {
				if (socket.connected) {
					socket.close();
				}
			} catch (_:Dynamic) {}
			runtime.exit();
			throw error;
		}

		try {
			if (socket.connected) {
				socket.close();
			}
		} catch (_:Dynamic) {}
		runtime.exit();
	}

	private static function drainConsole(queue:Deque<String>, socket:Socket, connected:Bool, setRunning:Bool->Void):Void {
		while (true) {
			var line = queue.pop(false);
			if (line == null) {
				return;
			}

			var message = StringTools.trim(line);
			if (message.length == 0) {
				continue;
			}

			if (!connected) {
				Sys.println("[client] still connecting...");
				continue;
			}

			if (message == "/quit") {
				SocketChatCommon.sendFrame(socket, "/quit");
				setRunning(false);
				return;
			}

			SocketChatCommon.sendFrame(socket, message);
		}
	}

	private static function readConsole(queue:Deque<String>):Void {
		while (true) {
			try {
				queue.add(Sys.stdin().readLine());
			} catch (_:Dynamic) {
				queue.add("/quit");
				return;
			}
		}
	}
}
