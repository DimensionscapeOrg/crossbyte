package crossbyte.net;

import crossbyte.errors.ArgumentError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import utest.Async;

/**
	A `wss://` `NetHost` serves with the certificate it is given.

	It could not be given one. The constructor bound its `ServerWebSocket`
	itself, with no way to reach `cert` first, and a TLS server's material
	has to be in place before it binds: every handshake failed, and nothing
	said why.
**/
class NetHostTLSTest extends utest.Test {
	// An address that is not this machine's, from a block kept for
	// documentation (RFC 5737): a host refused before it binds never touches
	// it, and one that tried to bind it could not.
	private static inline var ELSEWHERE:String = "192.0.2.1:8443";

	public function testAWssHostWithoutACertificateIsRefused():Void {
		Assert.raises(() -> new NetHost('wss://$ELSEWHERE'), ArgumentError);
	}

	public function testACertificateForAHostThatWouldNotUseItIsRefused():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			Assert.pass();
			return;
		}
		Assert.raises(() -> new NetHost('tcp://$ELSEWHERE', null, null, null, false, {certificate: fixture.certificate, key: fixture.key}),
			ArgumentError);
	}

	#if (cpp || java || jvm || nodejs)
	@:timeout(20000)
	public function testAWssHostServesWithTheCertificateItWasGiven(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the wss host did not run");
			async.done();
			return;
		}

		// A URI names its port, and 0 is not one: a port that was free a
		// moment ago, taken from a listener once it closes.
		var probe = new ServerSocket();
		probe.bind(0, "127.0.0.1");
		probe.listen();

		NetPump.until(() -> probe.localPort != 0, 5.0, function(_) {
			var port:Int = probe.localPort;
			try probe.close() catch (_:Dynamic) {}

			var host = new NetHost('wss://127.0.0.1:$port', function(connection:INetConnection) {
				connection.onData = input -> {
					var answer = new ByteArray();
					answer.writeUTFBytes(input.readUTFBytes(input.bytesAvailable).toUpperCase());
					answer.position = 0;
					connection.send(answer);
				};
				connection.readEnabled = true;
			}, null, null, true, {certificate: fixture.certificate, key: fixture.key});

			var heard:String = "";
			var failure:String = null;
			var client = new WebSocket();
			client.secure = true;
			client.certAuthority = fixture.certificate;
			client.addEventListener(Event.CONNECT, function(_) {
				client.writeUTFBytes("over wss");
				client.flush();
			});
			client.addEventListener(ProgressEvent.SOCKET_DATA, function(_) heard += client.readUTFBytes(client.bytesAvailable));
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);

			// Node claims the port a turn after listen().
			NetPump.wait(0.2, function() {
				client.connect("127.0.0.1", port);

				NetPump.until(() -> heard.length >= 8 || failure != null, 10.0, function(_) {
					Assert.equals("OVER WSS", heard, "the wss host did not answer: " + failure);
					try client.close() catch (_:Dynamic) {}
					try host.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end
}
