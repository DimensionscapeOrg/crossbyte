package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.net._internal.stun.TurnStream;
import utest.Assert;

/**
	A relay reached over a TCP or TLS connection, on real sockets: the part
	`TurnClientTest` cannot reach in memory, where every datagram finds its
	relay by the address it is sent to whatever the transport.

	Native and the jvm, like the other cases built on `FakeTurnRelaySocket`.
**/
class TurnStreamTest extends utest.Test {
	private function unsupported():Bool {
		if (!DatagramSocket.isSupported || !TurnClient.isSupported) {
			Assert.isTrue(!DatagramSocket.isSupported || !TurnClient.isSupported);
			return true;
		}

		return false;
	}

	/**
		A relay that redirects with 300 Try Alternate over TCP is followed to
		the one it names, over a connection of its own.

		The stream was opened once, to the first relay, and went on carrying
		everything there: the retry meant for the alternate reached the relay
		that had just redirected it, which redirected it again, and the
		allocation failed as a redirection back to a relay already asked.
	**/
	public function testATryAlternateOverTcpIsFollowed():Void {
		if (unsupported()) return;

		var first = new FakeTurnRelaySocket();
		var second = new FakeTurnRelaySocket();

		try {
			first.start();
			first.startTcp();
			second.start();
			second.startTcp();
			first.relay.allocateError = {code: 300, reason: "Try Alternate", alternate: {address: "127.0.0.1", port: second.tcpPort}};

			var outcome = __allocate(new TurnClient("127.0.0.1", first.tcpPort, "user", "secret", TCP));

			Assert.isNull(outcome.failure, "the redirection was not followed: " + outcome.failure);
			Assert.isTrue(outcome.client.active, "no allocation was made");
			Assert.equals(1, first.relay.count("allocate-error"), "the first relay never redirected, so this proved nothing");
			Assert.equals(1, second.relay.allocations, "the relay redirected to holds no allocation");
			Assert.equals(0, first.relay.allocations);
			Assert.equals(second.tcpPort, outcome.client.serverPort);

			outcome.stream.close();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		first.close();
		second.close();
	}

	/**
		And over TLS, to a relay whose certificate the client checks.
	**/
	public function testATryAlternateOverTlsIsFollowed():Void {
		if (unsupported()) return;

		var fixture = TLSTestFixture.trusted();

		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TURN over TLS case did not run");
			return;
		}

		var first = new FakeTurnRelaySocket();
		var second = new FakeTurnRelaySocket();

		try {
			first.start();
			first.startTcp(fixture.certificate, fixture.key);
			second.start();
			second.startTcp(fixture.certificate, fixture.key);
			first.relay.allocateError = {code: 300, reason: "Try Alternate", alternate: {address: "127.0.0.1", port: second.tcpPort}};

			var client = new TurnClient("127.0.0.1", first.tcpPort, "user", "secret", TLS);
			client.certAuthority = fixture.certificate;
			var outcome = __allocate(client);

			Assert.isNull(outcome.failure, "the redirection was not followed: " + outcome.failure);
			Assert.isTrue(client.active, "no allocation was made");
			Assert.equals(1, second.relay.allocations, "the relay redirected to holds no allocation");

			outcome.stream.close();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		first.close();
		second.close();
	}

	/**
		Over TLS the alternate's ALTERNATE-DOMAIN is the name its connection
		is opened to, and so the name its certificate is checked against (RFC
		8489 section 14.16): ALTERNATE-SERVER gives only an address, which a
		relay's certificate rarely names. Over TCP the address is used.
	**/
	public function testATlsRedirectionIsCheckedAgainstTheAlternateDomain():Void {
		if (!TurnClient.isSupported) {
			Assert.isFalse(TurnClient.isSupported);
			return;
		}

		for (transport in [TurnTransport.TLS, TurnTransport.TCP]) {
			var network = new TurnNetwork();
			network.addRelay("198.51.100.20", 5349);
			network.relay.allocateError = {
				code: 300,
				reason: "Try Alternate",
				alternate: {address: "198.51.100.20", port: 5349},
				alternateDomain: "turn2.example.org"
			};

			var client = network.client(null, "user", "secret", "192.0.2.10", 0, null, transport);
			client.allocated.then(_ -> {}, _ -> {});
			client.allocate(network.now);
			network.run(() -> client.active, 5);

			Assert.equals(transport == TLS ? "turn2.example.org" : "198.51.100.20", @:privateAccess client.__streamHost,
				"a redirection over " + transport + " is connected to the wrong name");
		}
	}

	/** Allocates through a stream, pumping the runtime, and says how it went. **/
	private function __allocate(client:TurnClient):{client:TurnClient, stream:TurnStream, failure:String} {
		var stream = new TurnStream(client);
		var failure:String = null;

		client.allocated.then(_ -> {}, error -> failure = error);
		client.allocate(haxe.Timer.stamp());

		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + 10;

		while (!client.active && failure == null && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			client.poll(haxe.Timer.stamp());
			crossbyte.sys.System.sleep(0.001);
		}

		return {client: client, stream: stream, failure: failure};
	}
}
