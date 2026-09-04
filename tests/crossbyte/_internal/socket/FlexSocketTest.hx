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

		// ALPN is TLS-only for the same reason verifyCert is: there is no
		// handshake on a plain socket to carry it.
		Assert.isTrue(throwsSslOnlyError(() -> socket.setALPN(["h2"])));
		Assert.isTrue(throwsSslOnlyError(() -> {
			var ignored = socket.getALPN();
		}));

		Assert.equals(#if (cpp || java || jvm) true #else false #end, FlexSocket.alpnSupported);
	}

	public function testSecureSocketAcceptsAlpnBeforeConnecting():Void {
		var socket = new FlexSocket(true);
		Assert.isTrue(socket.isSecure);

		// Accepted on every target: where alpnSupported is false the call is a
		// no-op rather than an error, so a caller can offer h2 unconditionally
		// and read back null on the targets that cannot negotiate it.
		socket.setALPN(["h2", "http/1.1"]);
		socket.setALPN(null);
		socket.setALPN(["h2"]);

		// Nothing is negotiated until a handshake happens.
		Assert.isNull(socket.getALPN());

		closeQuietly(socket);
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
