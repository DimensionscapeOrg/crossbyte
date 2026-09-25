import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;

class RUDPSample extends HostApplication {
	// What the client presents to be let in. A real one would be issued by
	// something the server trusts, signed and short lived, since it crosses
	// the network in the clear.
	private static inline var TICKET:String = "ticket-42";

	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("ReliableDatagramSocket is only supported on native sys targets.");
		return;
		#end

		var app = new RUDPSample();
		app.run();
	}

	private var server:ReliableDatagramServerSocket;
	private var client:ReliableDatagramSocket;
	private var accepted:ReliableDatagramSocket;
	private var serverReceived:String = null;
	private var admittedOn:String = null;
	private var clientReceived:String = null;
	private var failed:String = null;
	private var clientSent:Bool = false;

	public function new() {
		super();
	}

	private function run():Void {
		server = new ReliableDatagramServerSocket();
		client = new ReliableDatagramSocket();

		// Asked before the server allocates anything for the session.
		server.admit = (_, _, payload) -> payload.toString() == TICKET;
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
			accepted = event.socket;
			admittedOn = accepted.connectPayload.toString();
			accepted.addEventListener(IOErrorEvent.IO_ERROR, ioEvent -> failed = ioEvent.text);
			accepted.addEventListener(DatagramSocketDataEvent.DATA, dataEvent -> {
				serverReceived = dataEvent.data.toString();
				accepted.send(bytesOf("echo: " + serverReceived));
			});
		});

		client.addEventListener(Event.CONNECT, _ -> {
			if (!clientSent) {
				clientSent = true;
				client.send(bytesOf("hello over rudp"));
			}
		});
		client.addEventListener(IOErrorEvent.IO_ERROR, event -> failed = event.text);
		client.addEventListener(DatagramSocketDataEvent.DATA, event -> clientReceived = event.data.toString());

		server.bind(0, "127.0.0.1");
		server.listen();
		client.connect("127.0.0.1", server.localPort, bytesOf(TICKET));

		var deadline = Sys.time() + 3.0;
		while (clientReceived == null && failed == null && Sys.time() < deadline) {
			advance(1 / 60, 0);
			Sys.sleep(0.01);
		}

		closeQuietly(client);
		closeQuietly(accepted);
		closeServerQuietly(server);

		if (failed != null) {
			throw failed;
		}

		if (clientReceived == null) {
			throw "RUDP sample timed out waiting for the echoed payload.";
		}

		Sys.println("RUDP sample completed.");
		Sys.println('admitted on -> "$admittedOn"');
		Sys.println('server received -> "$serverReceived"');
		Sys.println('client received -> "$clientReceived"');
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
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
}
