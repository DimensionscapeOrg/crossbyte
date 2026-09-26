package crossbyte.net;

import utest.Assert;

/**
	A blocking read with a timeout set gives up at the timeout.

	On the jvm `setTimeout` was stored and never read: a blocking NIO channel
	has no read timeout of its own, so a read with nothing coming waited for
	ever -- and CrossByte's HTTP client reads a response exactly that way, with
	its idle limit as the timeout, so it could wait for ever on a server that
	stopped sending.

	Not on eval, which raises a socket timeout as a native error no Haxe code
	can catch.
**/
class SysSocketTimeoutTest extends utest.Test {
	#if (cpp || java || jvm)
	public function testABlockingReadGivesUpAtItsTimeout():Void {
		var server = new sys.net.Socket();
		var client = new sys.net.Socket();
		var peer:sys.net.Socket = null;

		try {
			server.bind(new sys.net.Host("127.0.0.1"), 0);
			server.listen(1);
			client.connect(new sys.net.Host("127.0.0.1"), server.host().port);
			peer = server.accept();
			client.setTimeout(0.3);

			var started:Float = haxe.Timer.stamp();
			var gaveUp:Bool = false;
			try {
				client.input.readByte();
			} catch (_:Dynamic) {
				gaveUp = true;
			}
			var took:Float = haxe.Timer.stamp() - started;

			Assert.isTrue(gaveUp, "a read with nothing to read returned something");
			Assert.isTrue(took < 5.0, 'the read gave up only after $took s');
			Assert.isTrue(took >= 0.2, 'the read gave up after $took s, before its timeout');

			// A timed-out read leaves the socket usable.
			peer.output.writeByte(42);
			peer.output.flush();
			Assert.equals(42, client.input.readByte());
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
