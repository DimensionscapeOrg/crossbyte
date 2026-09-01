import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.net.LocalAddress;
import crossbyte.net.ice.IceCandidate;
import crossbyte.net.rtc.DataChannel;
import crossbyte.net.rtc.PeerConnection;
import crossbyte.net.rtc.SessionDescription;

/**
	The CrossByte half of the browser interoperability test, in either
	direction.

	It is the only test here whose result depends on an implementation nobody in
	this repository wrote. Everything else proves this code agrees with itself.

	## Why both directions

	They exercise opposite role combinations, and a stack that gets one right
	can still have the other backwards.

	Answering a browser makes this peer ICE-controlled and the DTLS client at
	once, because the browser offers -- taking the ICE role -- and offers
	`actpass`, leaving the client half here. Offering to a browser inverts both:
	this peer nominates, and the browser's answer of `active` makes it the DTLS
	server. Since the SCTP association is opened by the DTLS client and the even
	data channel streams belong to it, the second direction has this peer
	listening for an association and taking the odd streams -- none of which the
	first direction touches.

	A connection that drove both roles from one bit passed the answering
	direction and could not have completed this one.

	Signalling is stdin and stdout, one JSON object per line, because the
	harness driving both ends is already a process that reads and writes them.

	Run by `ci/interop/run.js`; not useful on its own.
**/
@:access(crossbyte.core.CrossByte)
class BrowserInteropPeer {
	static var connection:PeerConnection;
	static var finished:Bool = false;
	static var echoed:Bool = false;

	static function main():Void {
		new CrossByte(true, DEFAULT, true);

		if (!PeerConnection.isSupported) {
			say({event: "unsupported"});
			return;
		}

		var instruction:Dynamic = haxe.Json.parse(Sys.stdin().readLine());

		if (instruction.mode == "offer") {
			offerToBrowser();
		} else {
			answerBrowser(SessionDescription.fromSdp(instruction.sdp));
		}

		pumpUntilDone();

		say({event: "done", echoed: echoed});
		connection.close();
	}

	/**
		The browser offered; this end answers.

		ICE-controlled, and the DTLS client, because the offer said `actpass`.
	**/
	static function answerBrowser(remote:crossbyte.net.rtc.PeerDescription):Void {
		connection = new PeerConnection(false);
		connection.bind(0, "0.0.0.0");

		gatherToward([for (candidate in remote.candidates) candidate.address]);
		watchForChannel();

		// Before describing this end: the answer has to state which DTLS role
		// was taken, and that is not known until the offer has been read.
		connection.connect(remote);

		say({event: "answer", sdp: SessionDescription.toSdp(connection.description())});
	}

	/**
		This end offers; the browser answers.

		ICE-controlling, and -- once the browser answers `active` -- the DTLS
		server, so the browser opens the SCTP association and takes the even
		streams. The channel is opened from here, which is what makes the
		browser's `ondatachannel` fire.
	**/
	static function offerToBrowser():Void {
		connection = new PeerConnection(true);
		connection.bind(0, "0.0.0.0");

		// No peer candidates to aim at yet, so the question is the general one:
		// which interface carries the default route. That is the address a
		// browser on this machine will be able to reach.
		gatherToward([]);

		connection.ready.then(function(_):Void {
			say({event: "ready", dtlsClient: connection.dtlsClient, iceControlling: connection.iceControlling, path: path()});

			var channel = connection.createDataChannel("interop");

			channel.onMessage = function(text:String):Void {
				say({event: "message", text: text});
				echoed = true;
			};

			channel.opened.then(function(_):Void {
				say({event: "channel", label: channel.label});
				channel.send("from crossbyte");
			}, function(_):Void {});
		}, function(error:String):Void {
			say({event: "failed", reason: error});
			finished = true;
		});

		say({event: "offer", sdp: SessionDescription.toSdp(connection.description())});

		// The answer comes back on the same channel the instruction arrived on.
		var answer:Dynamic = haxe.Json.parse(Sys.stdin().readLine());
		connection.connect(SessionDescription.fromSdp(answer.sdp));
	}

	/**
		Adds the addresses this peer can be reached at.

		Bound to the wildcard, so the socket cannot say where it is. Each of the
		peer's own candidates is a destination to ask about -- whichever
		interface reaches it is the address to advertise.

		The default route is asked as well, always, and not only when there are
		no destinations to aim at. A browser publishes its host candidates as
		`.local` mDNS names, which resolve to nothing here, so asking only about
		them yields nothing and the peer advertises loopback alone. That passes
		this test, both ends being on one machine, and describes a peer no
		browser on any other machine could reach -- a green run for a connection
		that does not work.
	**/
	static function gatherToward(destinations:Array<String>):Void {
		var asked = new Map<String, Bool>();

		for (destination in destinations) {
			if (asked.exists(destination)) {
				continue;
			}

			asked.set(destination, true);

			LocalAddress.forDestination(destination).then(function(local:String):Void {
				addHost(local);
			}, function(_):Void {});
		}

		LocalAddress.primary().then(function(local:String):Void {
			addHost(local);
		}, function(_):Void {});

		// Loopback as well: a socket on the wildcard is reachable there too, and
		// it costs one candidate.
		addHost("127.0.0.1");
	}

	/**
		What the connection settled on, which is the whole of what the mDNS case
		proves.

		A browser publishes no address anything here can dial, so every pair
		built from its description is unreachable and the path has to be learned
		the other way round -- from the source address of a check the browser
		sent, which ICE calls a peer-reflexive candidate. Reporting the type
		lets the harness assert that is what happened, rather than observing a
		connection and assuming why.
	**/
	static function path():Dynamic {
		var pair = connection.agent.selectedPair;

		if (pair == null) {
			return null;
		}

		return {
			remoteType: (pair.remote.type : String),
			remoteAddress: pair.remote.address,
			localAddress: pair.local.address
		};
	}

	static var advertised:Map<String, Bool> = new Map();

	static function addHost(address:String):Void {
		if (advertised.exists(address)) {
			return;
		}

		advertised.set(address, true);
		connection.addLocalCandidate(IceCandidate.host(address, connection.localPort));
	}

	/** The answering direction, where the browser opens the channel. **/
	static function watchForChannel():Void {
		connection.ready.then(function(_):Void {
			say({event: "ready", dtlsClient: connection.dtlsClient, iceControlling: connection.iceControlling, path: path()});
		}, function(error:String):Void {
			say({event: "failed", reason: error});
			finished = true;
		});

		connection.onChannel = function(opened:DataChannel):Void {
			say({event: "channel", label: opened.label});

			opened.onMessage = function(text:String):Void {
				say({event: "message", text: text});
				opened.send("echo:" + text);
				echoed = true;
			};

			// Bytes come back verbatim, empty ones included: an empty binary
			// message travels as PPID 57 rather than 53, and echoing it is what
			// makes the browser judge that both directions of both ids agree.
			opened.onBytes = function(payload:crossbyte.io.ByteArray):Void {
				say({event: "bytes", length: payload.length});
				opened.sendBytes(payload);
			};
		};
	}

	/**
		Driven here rather than from the tick, so the process exits when the
		exchange is done rather than idling until something kills it.
	**/
	static function pumpUntilDone():Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + 30;

		while (!finished && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);

			if (echoed) {
				// One more turn so a reply is actually written before this stops
				// pumping. A message queued and never flushed is a test that
				// fails for the wrong reason.
				var settle = Sys.time() + 0.5;

				while (Sys.time() < settle) {
					runtime.pump(1 / 60, 0);
					Sys.sleep(0.001);
				}

				finished = true;
			}
		}
	}

	/** One JSON object per line, flushed, because the harness reads by line. **/
	static function say(value:Dynamic):Void {
		Sys.stdout().writeString(haxe.Json.stringify(value) + "\n");
		Sys.stdout().flush();
	}
}
