package crossbyte.net;

import utest.Assert;

/**
	Reading a byte at the end of a connection reports the end.

	On eval `readByte` answered 0 there, a byte like any other, where every
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

	#if (sys && !(js || php || eval))
	/**
		A reset is a failure, not the end of the stream.

		Natively `readByte` took every error but "Blocking" for the end, so a
		connection reset partway through read as one that ended cleanly, as
		hl's and neko's reads did until they were fixed, and a reader that
		stops at the end took whatever it had as whole. Not on eval, where a
		reset is a native error no Haxe catch sees.
	**/
	public function testAResetIsAFailureNotTheEnd():Void {
		var server = new sys.net.Socket();
		var client = new sys.net.Socket();
		var peer:sys.net.Socket = null;

		try {
			server.bind(new sys.net.Host("127.0.0.1"), 0);
			server.listen(1);
			client.connect(new sys.net.Host("127.0.0.1"), server.host().port);
			peer = server.accept();

			// Sent to the peer and never read: closing over it is a reset.
			client.output.writeString("unread");
			client.output.flush();
			crossbyte.sys.System.sleep(0.1);
			#if (java || jvm)
			// The JDK closes gracefully even over unread data; a zero linger
			// is how a Java socket is made to reset.
			var channel:java.nio.channels.SocketChannel = cast @:privateAccess peer.channel;
			channel.socket().setSoLinger(true, 0);
			#end
			peer.close();
			peer = null;
			crossbyte.sys.System.sleep(0.1);

			var outcome:String = "a byte";
			try {
				client.input.readByte();
			} catch (_:haxe.io.Eof) {
				outcome = "the end of the stream";
			} catch (_:Dynamic) {
				outcome = "a failure";
			}
			Assert.equals("a failure", outcome, "a reset read as " + outcome);
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
