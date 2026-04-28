import crossbyte.core.HostApplication;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;

class UDPSample extends HostApplication {
	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("DatagramSocket is only supported on native sys targets.");
		return;
		#end

		var app = new UDPSample();
		app.run();
	}

	private var receiver:DatagramSocket;
	private var sender:DatagramSocket;
	private var received:String = null;
	private var failed:String = null;

	public function new() {
		super();
	}

	private function run():Void {
		receiver = new DatagramSocket();
		sender = new DatagramSocket();

		receiver.addEventListener(DatagramSocketDataEvent.DATA, __onData);
		receiver.addEventListener(IOErrorEvent.IO_ERROR, event -> failed = event.text);
		sender.addEventListener(IOErrorEvent.IO_ERROR, event -> failed = event.text);

		receiver.bind(0, "127.0.0.1");
		receiver.receive();

		var payload = bytesOf("hello over udp");
		sender.send(payload, 0, payload.length, "127.0.0.1", receiver.localPort);

		var deadline = Sys.time() + 2.0;
		while (received == null && failed == null && Sys.time() < deadline) {
			advance(1 / 60, 0);
			Sys.sleep(0.01);
		}

		sender.close();
		receiver.close();

		if (failed != null) {
			throw failed;
		}

		if (received == null) {
			throw "UDP sample timed out waiting for a datagram.";
		}

		Sys.println("UDP sample completed.");
		Sys.println('received -> "$received"');
	}

	private function __onData(event:DatagramSocketDataEvent):Void {
		received = event.data.toString();
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}
}
