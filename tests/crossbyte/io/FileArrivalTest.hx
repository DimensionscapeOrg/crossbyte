package crossbyte.io;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.net.DatagramSocket;
import utest.Assert;

/**
	"Copy it to keep it", from the side that is handed the payload: a
	datagram saved to a file from inside its `DATA` listener.

	`File.data` is a member read later, and its doc says `save()` sets it to
	what it saved. It is set to the `ByteArray` passed, by reference: saved
	from a payload valid only during its call, the file's `data` reads as
	whatever the socket put there next, nothing, once the call returned.
**/
class FileArrivalTest extends utest.Test {
	public function testWhatAFileSavedFromADatagramSaysItSavedIsTheDatagram():Void {
		if (!DatagramSocket.isSupported) {
			Assert.pass();
			return;
		}

		var dir = File.createTempDirectory();
		var file = dir.resolvePath("packet.bin");
		var server = new DatagramSocket();
		var client = new DatagramSocket();
		server.bind(0, "127.0.0.1");
		client.bind(0, "127.0.0.1");
		server.receive();

		var text:String = "a datagram, saved as it arrived";
		var saved:Int = 0;
		server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			file.save(e.data, true);
			saved++;
		});

		var bytes = new ByteArray();
		bytes.writeUTFBytes(text);
		client.send(bytes, 0, 0, "127.0.0.1", server.localPort);

		var runtime = CrossByte.current();
		var deadline:Float = haxe.Timer.stamp() + 5.0;
		while (saved < 1 && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 120, 0);
			crossbyte.sys.System.sleep(0.001);
		}

		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}

		Assert.equals(1, saved, "the datagram never arrived");
		var onDisk:String = sys.io.File.getContent(file.nativePath);
		var said:String = file.data.toString();
		try dir.deleteDirectory(true) catch (_:Dynamic) {}

		Assert.equals(text, onDisk, "the file on disk is not the datagram");
		Assert.equals(text, said, 'File.data is not what save() saved, but "$said"');
	}
}
