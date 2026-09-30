package crossbyte.net;

import utest.Assert;

/**
	Reading a byte at the end of a connection reports the end.

	On eval `readByte` answered 0 there -- a byte like any other -- where every
	other target throws `Eof`. A reader waiting for a delimiter at the end of a
	connection, such as a line reader, read zeros for ever instead of stopping.
**/
class SysSocketEofTest extends utest.Test {
	#if (sys && !(js || php))
	public function testReadingPastTheEndOfAConnectionThrowsEof():Void {
		var server = new sys.net.Socket();
		var client = new sys.net.Socket();
		var peer:sys.net.Socket = null;

		try {
			server.bind(new sys.net.Host("127.0.0.1"), 0);
			server.listen(1);
			client.connect(new sys.net.Host("127.0.0.1"), server.host().port);
			peer = server.accept();

			peer.output.writeByte(7);
			peer.output.flush();
			// The end of the stream, after the one byte: an orderly close.
			peer.shutdown(false, true);

			Assert.equals(7, client.input.readByte());

			var ended:Bool = false;
			var read:Null<Int> = null;
			try {
				read = client.input.readByte();
			} catch (_:haxe.io.Eof) {
				ended = true;
			}
			Assert.isTrue(ended, 'a byte was read past the end of the connection: $read');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try client.close() catch (_:Dynamic) {}
		if (peer != null) {
			try peer.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}
	#end
}
