package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	What a `WebSocket` client does on its own side of a connection, against
	servers that do not behave.
**/
class WebSocketClientTest extends utest.Test {
	#if (cpp || java || jvm || nodejs)
	/**
		A server that accepts the connection and never answers the upgrade.

		Nothing bounded the wait: `timeout` covered the TCP connect and no
		further, and a client that had sent its upgrade sat in CONNECTING for
		as long as the peer kept the connection open. A TLS listener spoken to
		in plain text is one such peer, and so is anything at the wrong port.
	**/
	@:timeout(20000)
	public function testAnUnansweredUpgradeIsGivenUpOnAfterTheTimeout(async:Async):Void {
		var server = new ServerSocket();
		var held:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) held.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		client.timeout = 400;

		var connected:Bool = false;
		var closed:Bool = false;
		var failure:String = null;
		var started:Float = 0.0;
		var took:Float = -1.0;

		client.addEventListener(Event.CONNECT, function(_) connected = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
		client.addEventListener(Event.CLOSE, function(_) {
			closed = true;
			took = haxe.Timer.stamp() - started;
		});

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			started = haxe.Timer.stamp();
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> closed || connected, 8.0, function(_) {
				Assert.isFalse(connected, "an upgrade nobody answered was reported as connected");
				Assert.isTrue(closed, "a client whose upgrade went unanswered was never given up on");
				Assert.isTrue(took >= 0.3 && took < 3.0, 'gave up after $took s against a timeout of 0.4 s');
				Assert.isTrue(failure != null && failure.indexOf("upgrade") >= 0, "the failure did not say what went unanswered: " + failure);

				for (socket in held) {
					try socket.close() catch (_:Dynamic) {}
				}
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A connection refused is reported as refused: an ioError that says
		so, and no CONNECT. On Linux and macOS a refused connect leaves the
		socket writable, which was taken for a connection, so the client sent
		its upgrade into nothing and ended in a 1006 that did not say why.
	**/
	@:timeout(15000)
	public function testARefusedConnectionSaysItWasRefused(async:Async):Void {
		// A port nothing listens on, obtained rather than assumed.
		var vacant = new ServerSocket();
		vacant.bind(0, "127.0.0.1");
		vacant.listen(1);

		NetPump.until(() -> vacant.localPort != 0, 5.0, function(_) {
			var port:Int = vacant.localPort;
			try vacant.close() catch (_:Dynamic) {}

			var client = new WebSocket();
			var connected:Bool = false;
			var closed:Bool = false;
			var failure:String = null;
			client.addEventListener(Event.CONNECT, function(_) connected = true);
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);
			client.addEventListener(Event.CLOSE, function(_) closed = true);
			client.connect("127.0.0.1", port);

			NetPump.until(() -> connected || (failure != null && closed), 8.0, function(_) {
				Assert.isFalse(connected, "a refused connection was reported as connected");
				Assert.isTrue(failure != null && failure.toLowerCase().indexOf("refused") >= 0,
					"the failure did not say the connection was refused: " + failure);
				try client.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end
}
