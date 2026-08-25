import crossbyte.core.CrossByte;
import crossbyte.net.LocalAddress;
import crossbyte.net.ice.IceCandidate;
import crossbyte.net.rtc.DataChannel;
import crossbyte.net.rtc.PeerConnection;
import crossbyte.net.rtc.SessionDescription;

/**
	The CrossByte half of the browser interoperability test.

	A browser offers, this answers, and a data channel opens between a real
	`RTCPeerConnection` and the stack in `crossbyte.net.rtc`. It is the only
	test that can tell whether the wire formats built here are the ones the rest
	of the world uses -- everything else in the suite proves this code agrees
	with itself.

	Signalling is stdin and stdout, one JSON object per line, because the
	harness driving both ends is already a process that can read and write them.
	A real application would use whatever channel it already has.

	Run by `ci/interop/run.js`; not useful on its own.
**/
@:access(crossbyte.core.CrossByte)
class BrowserInteropPeer {
	static var connection:PeerConnection;
	static var channel:DataChannel;
	static var finished:Bool = false;
	static var echoed:Bool = false;

	static function main():Void {
		new CrossByte(true, DEFAULT, true);

		if (!PeerConnection.isSupported) {
			say({event: "unsupported"});
			return;
		}

		// The offer arrives before anything is built, because what it says
		// about DTLS roles decides how this peer is constructed.
		var offerLine = Sys.stdin().readLine();
		var offer:Dynamic = haxe.Json.parse(offerLine);
		var remote = SessionDescription.fromSdp(offer.sdp);

		// The answerer, which makes this peer ICE-controlled. It says nothing
		// about the DTLS role: the browser offers `actpass`, so this end takes
		// the client half, and `connect` below is what settles that.
		connection = new PeerConnection(false);
		connection.bind(0, "0.0.0.0");

		// Bound to the wildcard, so the socket cannot say where it is. The
		// browser's own candidate is the destination to ask about: whichever
		// interface reaches it is the address it should be told to dial.
		var reachable = new Map<String, Bool>();

		for (candidate in remote.candidates) {
			if (reachable.exists(candidate.address)) {
				continue;
			}

			reachable.set(candidate.address, true);

			LocalAddress.forDestination(candidate.address).then(function(local:String):Void {
				connection.addLocalCandidate(IceCandidate.host(local, connection.localPort));
			}, function(_):Void {});
		}

		// Loopback as well, for the case where the browser offers it: a socket
		// on the wildcard can be reached there too, and it costs one candidate.
		connection.addLocalCandidate(IceCandidate.host("127.0.0.1", connection.localPort));

		connection.onChannel = function(opened:DataChannel):Void {
			channel = opened;
			say({event: "channel", label: opened.label});

			opened.onMessage = function(text:String):Void {
				say({event: "message", text: text});
				opened.send("echo:" + text);
				echoed = true;
			};
		};

		connection.ready.then(function(_):Void {
			say({event: "ready"});
		}, function(error:String):Void {
			say({event: "failed", reason: error});
			finished = true;
		});

		// Before describing this end, because the answer has to state which DTLS
		// role was taken and that is not known until the offer has been read.
		connection.connect(remote);

		say({event: "answer", sdp: SessionDescription.toSdp(connection.description())});

		// Driven here rather than from the tick, so the process exits when the
		// exchange is done rather than idling until something kills it.
		var runtime = CrossByte.current();
		var deadline = Sys.time() + 30;

		while (!finished && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);

			if (echoed) {
				// One more turn so the reply is actually written before this
				// stops pumping. A message queued and never flushed is a test
				// that fails for the wrong reason.
				var settle = Sys.time() + 0.5;

				while (Sys.time() < settle) {
					runtime.pump(1 / 60, 0);
					Sys.sleep(0.001);
				}

				finished = true;
			}
		}

		say({event: "done", echoed: echoed});
		connection.close();
	}

	/** One JSON object per line, flushed, because the harness reads by line. **/
	static function say(value:Dynamic):Void {
		Sys.stdout().writeString(haxe.Json.stringify(value) + "\n");
		Sys.stdout().flush();
	}
}
