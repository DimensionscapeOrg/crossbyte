import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import haxe.Timer;
import sys.thread.Deque;
import sys.thread.Thread;

@:access(crossbyte.core.CrossByte)
class SocketChatServerSample {
	private static var peers:Array<ChatPeer> = [];
	private static var nextGuestId:Int = 1;

	public static function main():Void {
		var args = Sys.args();
		var host = args.length > 0 ? args[0] : SocketChatCommon.DEFAULT_HOST;
		var port = SocketChatCommon.parsePort(args, 1, SocketChatCommon.DEFAULT_PORT);

		var runtime = new CrossByte(true, DEFAULT, true);
		var server = new ServerSocket();
		var consoleQueue:Deque<String> = new Deque();
		var running = true;

		Thread.create(() -> readConsole(consoleQueue));

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			var socket:Socket = event.socket;
			var peer = new ChatPeer(socket, 'guest-${nextGuestId++}');
			peers.push(peer);

			Sys.println('[server] ${peer.name} connected from ${socket.remoteAddress}:${socket.remotePort}');
			sendToPeer(peer, 'welcome ${peer.name} - type /nick <name>, /who, or /quit');
			broadcast('[server] ${peer.name} joined the chat.', peer);

			socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				SocketChatCommon.pumpIncoming(socket, peer.inbox, message -> handlePeerMessage(peer, message));
			});

			socket.addEventListener(Event.CLOSE, _ -> {
				removePeer(peer, true);
			});
		});

		server.bind(port, host);
		server.listen();

		Sys.println('[server] listening on ${server.localAddress}:${server.localPort}');
		Sys.println("[server] commands: /clients, /say <message>, /quit");

		try {
			while (running) {
				drainConsole(consoleQueue, value -> running = value);
				runtime.pump(SocketChatCommon.PUMP_INTERVAL, 0);
				Sys.sleep(0.001);
			}
		} catch (error:Dynamic) {
			for (peer in peers.copy()) {
				closePeer(peer);
			}
			peers = [];
			try {
				server.close();
			} catch (_:Dynamic) {}
			runtime.exit();
			throw error;
		}

		for (peer in peers.copy()) {
			closePeer(peer);
		}
		peers = [];
		try {
			server.close();
		} catch (_:Dynamic) {}
		runtime.exit();
	}

	private static function handlePeerMessage(peer:ChatPeer, raw:String):Void {
		var message = StringTools.trim(raw);
		if (message.length == 0) {
			return;
		}

		if (StringTools.startsWith(message, "/nick ")) {
			var previous = peer.name;
			peer.name = SocketChatCommon.sanitizeName(message.substr(6), previous);
			if (peer.name == previous) {
				sendToPeer(peer, '[server] nickname unchanged: ${peer.name}');
			} else {
				sendToPeer(peer, '[server] nickname set to ${peer.name}');
				broadcast('[server] ${previous} is now known as ${peer.name}.', null);
			}
			return;
		}

		switch (message) {
			case "/who":
				var names = [for (entry in peers) entry.name].join(", ");
				sendToPeer(peer, '[server] connected: ${names}');
			case "/quit":
				sendToPeer(peer, "[server] goodbye");
				closePeer(peer);
			default:
				broadcast('${peer.name}: ${message}', null);
		}
	}

	private static function drainConsole(queue:Deque<String>, setRunning:Bool->Void):Void {
		while (true) {
			var line = queue.pop(false);
			if (line == null) {
				return;
			}

			var command = StringTools.trim(line);
			if (command.length == 0) {
				continue;
			}

			if (command == "/quit") {
				Sys.println("[server] shutting down");
				setRunning(false);
				return;
			}

			if (command == "/clients") {
				var roster = [for (peer in peers) peer.name].join(", ");
				Sys.println('[server] clients: ${roster.length > 0 ? roster : "(none)"}');
				continue;
			}

			if (StringTools.startsWith(command, "/say ")) {
				var announcement = StringTools.trim(command.substr(5));
				if (announcement.length > 0) {
					broadcast('[server] ${announcement}', null);
				}
				continue;
			}

			Sys.println("[server] unknown command");
		}
	}

	private static function broadcast(message:String, except:ChatPeer):Void {
		Sys.println(message);
		for (peer in peers) {
			if (peer != except) {
				sendToPeer(peer, message);
			}
		}
	}

	private static function sendToPeer(peer:ChatPeer, message:String):Void {
		try {
			if (peer.socket != null && peer.socket.connected) {
				SocketChatCommon.sendFrame(peer.socket, message);
			}
		} catch (_:Dynamic) {}
	}

	private static function removePeer(peer:ChatPeer, announce:Bool):Void {
		if (peer.removed) {
			return;
		}

		peer.removed = true;
		peers.remove(peer);
		if (announce) {
			broadcast('[server] ${peer.name} left the chat.', null);
		}
	}

	private static function closePeer(peer:ChatPeer):Void {
		removePeer(peer, true);
		try {
			if (peer.socket != null && peer.socket.connected) {
				peer.socket.close();
			}
		} catch (_:Dynamic) {}
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

private class ChatPeer {
	public final socket:Socket;
	public final inbox:ChatInbox;
	public var name:String;
	public var removed:Bool = false;

	public function new(socket:Socket, name:String) {
		this.socket = socket;
		this.name = name;
		this.inbox = new ChatInbox();
	}
}
