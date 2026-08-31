import crossbyte.core.CrossByte;
import crossbyte.net.rtc.DataChannel;
import crossbyte.net.rtc.PeerConnection;
import crossbyte.net.rtc.PeerDescription;

/**
	Two peers connecting with no path between them but a relay somebody else
	wrote.

	`PeerConnectionRelayTest` does the same thing against a TURN server in this
	repository, which is worth having and cannot answer one question: that
	server verifies a request with the very code that produced it, so the two
	agree perfectly about anything they are both wrong about. Long-term
	credentials are the obvious place for that -- the key is MD5 of username,
	realm and password rather than the password itself -- but it applies just as
	well to permissions, to Send indications and to how relayed data is wrapped.

	Driven by `ci/relay/run.js`, which starts the server and checks what it
	logged; not useful on its own.
**/
@:access(crossbyte.core.CrossByte)
class RelayInteropPeer {
	static function main():Void {
		new CrossByte(true, DEFAULT, true);

		if (!PeerConnection.isSupported) {
			Sys.println("unsupported here");
			return;
		}

		var server = Sys.args()[0];
		var port = Std.parseInt(Sys.args()[1]);
		var username = Sys.args()[2];
		var password = Sys.args()[3];

		var alice = new PeerConnection(true);
		var bob = new PeerConnection(false);

		// Different loopback addresses, so a datagram a peer sent itself and one
		// the relay forwarded do not share a source -- which is what makes the
		// server's permission checking mean anything.
		alice.bind(0, "127.0.0.2");
		bob.bind(0, "127.0.0.3");

		var relays = 0;
		var failure:String = null;

		alice.gatherRelayed(server, username, password, port).then(function(c):Void {
			Sys.println("alice was lent " + c.address + ":" + c.port);
			relays++;
		}, function(e):Void failure = "alice: " + e);

		bob.gatherRelayed(server, username, password, port).then(function(c):Void {
			Sys.println("bob was lent   " + c.address + ":" + c.port);
			relays++;
		}, function(e):Void failure = "bob: " + e);

		pump(() -> relays == 2 || failure != null, 15);

		if (failure != null) {
			Sys.println("FAILED   " + failure);
			return;
		}

		if (relays != 2) {
			Sys.println("FAILED   only " + relays + " of two allocations were granted");
			return;
		}

		var heard:String = null;

		bob.onChannel = function(channel:DataChannel):Void {
			channel.onMessage = function(text:String):Void heard = text;
		};

		alice.connect(relayOnly(bob));
		bob.connect(relayOnly(alice));

		pump(() -> alice.connected && bob.connected, 40);

		if (!alice.connected || !bob.connected) {
			Sys.println("FAILED   the peers never connected through the relay (alice " + alice.connected + ", bob " + bob.connected + ")");
			return;
		}

		Sys.println("connected over " + (alice.agent.selectedPair.local.type : String) + " -> "
			+ (alice.agent.selectedPair.remote.type : String));

		var chat = alice.createDataChannel("chat");
		pump(() -> chat.open, 15);

		if (!chat.open) {
			Sys.println("FAILED   the channel never opened");
			return;
		}

		chat.send("across somebody else's relay");
		pump(() -> heard != null, 15);

		if (heard != "across somebody else's relay") {
			Sys.println("FAILED   the message did not survive: " + heard);
			return;
		}

		Sys.println("SUCCESS  a data channel message crossed a relay nobody here wrote");

		alice.close();
		bob.close();
	}

	/** Only the relayed candidate, so no direct path is ever offered. **/
	static function relayOnly(connection:PeerConnection):PeerDescription {
		var described = connection.description();
		var kept = [];

		for (candidate in described.candidates) {
			if (candidate.type == "relay") {
				kept.push(candidate);
			}
		}

		described.candidates = kept;
		return described;
	}

	static function pump(done:Void->Bool, seconds:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + seconds;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}
}
