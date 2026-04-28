package crossbyte._internal.socket;

import haxe.io.Bytes;
import haxe.io.Error;
import sys.net.Socket as SysSocket;
import utest.Assert;

class FlexSocketTest extends utest.Test {
	public function testPlainSocketStateAndCustomStorage():Void {
		var socket = new FlexSocket();
		socket.custom = {name: "client"};

		Assert.isFalse(socket.isSecure);
		Assert.equals("client", socket.custom.name);
		Assert.isTrue(throwsSslOnlyError(() -> {
			var ignored = socket.verifyCert;
		}));
		Assert.isTrue(throwsSslOnlyError(() -> socket.verifyCert = true));
	}

	public function testBindListenSelectAcceptAndReadOverLocalhost():Void {
		var server = new FlexSocket();
		var client = new FlexSocket();
		var peer:SysSocket = null;

		try {
			server.bind("127.0.0.1", 0);
			server.listen(1);

			client.connect("127.0.0.1", server.host().port);

			var ready = FlexSocket.select([server], [], [], 1.0);
			Assert.equals(1, ready.read.length);

			peer = server.accept();
			client.output.writeString("ping");
			client.output.flush();

			Assert.equals("ping", peer.input.read(4).toString());
		} catch (e:Dynamic) {
			closeSysQuietly(peer);
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeSysQuietly(peer);
		closeQuietly(client);
		closeQuietly(server);
	}

	public function testDefaultListenBacklogCanAcceptConnection():Void {
		var server = new FlexSocket();
		var client = new FlexSocket();
		var peer:SysSocket = null;

		try {
			server.bind("127.0.0.1", 0);
			server.listen();
			client.connect("127.0.0.1", server.host().port);
			peer = server.accept();

			Assert.notNull(peer);
		} catch (e:Dynamic) {
			closeSysQuietly(peer);
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeSysQuietly(peer);
		closeQuietly(client);
		closeQuietly(server);
	}

	private static function throwsSslOnlyError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (message:String) {
			return message.indexOf("secure socket") >= 0;
		} catch (_:Dynamic) {
			return false;
		}
	}

	private static function closeQuietly(socket:FlexSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeSysQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}
