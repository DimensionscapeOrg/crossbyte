import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.net.LocalAddress;
import crossbyte.net.ice.IceCandidate;
import crossbyte.net.rtc.DataChannel;
import crossbyte.net.rtc.PeerConnection;
import crossbyte.net.rtc.PeerConnectionHost;
import crossbyte.net.rtc.SessionDescription;
import crossbyte.net.rtc._internal.sctp.SctpDataChunk;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;

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
		shared = instruction.host == true;

		if (instruction.mode == "offer") {
			offerToBrowser();
		} else {
			answerBrowser(SessionDescription.fromSdp(instruction.sdp));
		}

		pumpUntilDone();

		if (instruction.restart == true && connection.connected) {
			if (instruction.mode == "offer") {
				restartTowardBrowser();
			} else {
				restartFromBrowser();
			}
		}

		say({event: "done", echoed: echoed});
		connection.close();

		if (host != null) {
			host.close();
		}
	}

	/** Whether a message sent after an ICE restart has made the round trip. **/
	static var echoedAfterRestart:Bool = false;

	/** The channel this end opened toward the browser, in the offering direction. **/
	static var offeredChannel:DataChannel = null;

	/**
		The browser restarted ICE, as it does when its network changes, and its
		new offer comes on stdin. The answer goes back; then the new agent has
		to take over and the old channel to carry a message both ways.
	**/
	static function restartFromBrowser():Void {
		var line:Dynamic = haxe.Json.parse(Sys.stdin().readLine());
		var before = connection.agent;

		connection.connect(SessionDescription.fromSdp(line.restart));
		say({event: "restart-answer", sdp: SessionDescription.toSdp(connection.description()), restarting: connection.iceRestarting});

		pumpWhile(() -> connection.agent == before || connection.iceRestarting || !echoedAfterRestart);
		say({event: "restarted", switched: connection.agent != before && !connection.iceRestarting, echoed: echoedAfterRestart, path: path()});
	}

	/**
		This end restarts ICE and offers; the browser's answer comes on stdin.
		Once the new agent carries the session, a message goes out on the
		channel opened before the restart and has to come back.
	**/
	static function restartTowardBrowser():Void {
		var before = connection.agent;

		connection.restartIce();
		say({event: "restart-offer", sdp: SessionDescription.toSdp(connection.description())});

		var line:Dynamic = haxe.Json.parse(Sys.stdin().readLine());
		connection.connect(SessionDescription.fromSdp(line.answer));

		pumpWhile(() -> connection.agent == before || connection.iceRestarting);

		if (offeredChannel != null && offeredChannel.open) {
			offeredChannel.send("after restart");
		}

		pumpWhile(() -> !echoedAfterRestart);
		say({event: "restarted", switched: connection.agent != before && !connection.iceRestarting, echoed: echoedAfterRestart, path: path()});
	}

	/** Pumps while `waiting` holds, for at most twenty seconds. **/
	static function pumpWhile(waiting:Void->Bool):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + 20;

		while (waiting() && haxe.Timer.stamp() < deadline && connection.closeReason == null) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	/** Whether the connection shares a `PeerConnectionHost`'s socket rather than binding its own. **/
	static var shared:Bool = false;

	static var host:PeerConnectionHost = null;

	/**
		The connection, on a socket of its own or on a host's -- which routes a
		browser's checks by their ufrag, the answers to this end's by their
		transaction, and DTLS by the address the path was proved to. The
		browser is the only judge of the first two that is not this code.
	**/
	static function create(isOfferer:Bool):PeerConnection {
		if (shared) {
			host = new PeerConnectionHost();
			host.bind(0, "0.0.0.0");
			return host.createConnection(isOfferer);
		}

		var created = new PeerConnection(isOfferer);
		created.bind(0, "0.0.0.0");
		return created;
	}

	/**
		The browser offered; this end answers.

		ICE-controlled, and the DTLS client, because the offer said `actpass`.
	**/
	static function answerBrowser(remote:crossbyte.net.rtc.PeerDescription):Void {
		connection = create(false);

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
		connection = create(true);

		// No peer candidates to aim at yet, so the question is the general one:
		// which interface carries the default route. That is the address a
		// browser on this machine will be able to reach.
		gatherToward([]);

		connection.ready.then(function(_):Void {
			say({event: "ready", dtlsClient: connection.dtlsClient, iceControlling: connection.iceControlling, path: path()});

			var channel = connection.createDataChannel("interop");

			// The terms CrossByte writes into DCEP, for the browser to read back.
			connection.createDataChannel("state", false, "", 0);

			offeredChannel = channel;

			channel.onMessage = function(text:String):Void {
				say({event: "message", text: text});
				echoed = true;

				if (text == "echo:after restart") {
					echoedAfterRestart = true;
				}
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

			// The browser's partially reliable channels: reported as read, so
			// the harness can hold them to what the browser asked for.
			if (opened.label == "state" || opened.label == "ordered-state") {
				say({
					event: "terms",
					label: opened.label,
					ordered: opened.ordered,
					maxRetransmits: opened.maxRetransmits,
					maxPacketLifeTime: opened.maxPacketLifeTime
				});
			}

			if (opened.label == "ordered-state") {
				loseFirstAndCarryOn(opened);
				return;
			}

			opened.onMessage = function(text:String):Void {
				say({event: "message", text: text});
				opened.send("echo:" + text);
				echoed = true;

				if (text == "after restart") {
					echoedAfterRestart = true;
				}
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
		Sends on an ordered channel that may send each message once, losing the
		first message on purpose -- and loses the browser's first on it too.

		It is not sent again -- that is what `maxRetransmits: 0` means -- so the
		browser holds everything after it until a FORWARD TSN says to skip it.
		The rest arriving, in order, is the browser agreeing with how CrossByte
		wrote that chunk; a FORWARD TSN it could not read would leave them held.

		The other way round, the browser's first message on the channel is
		dropped as it arrives, before the transfer sees it. The browser may not
		send it again either, so it gives up on it and sends its own FORWARD
		TSN, and what CrossByte then delivers is its reading of Chrome's. The
		browser starts only once CrossByte's first message reaches it, so this
		is in place whatever the two of them bundle.
	**/
	static function loseFirstAndCarryOn(channel:DataChannel):Void {
		var association = @:privateAccess connection.__association;
		var send = association.onSend;
		var lost:Bool = false;

		association.onSend = function(payload:ByteArray):Void {
			if (!lost) {
				var packet = SctpPacket.decode(payload, false);

				for (chunk in (packet == null ? [] : packet.chunks)) {
					var data = SctpDataChunk.fromChunk(chunk);

					if (data != null && data.streamId == channel.id && data.protocolId == SctpDataChunk.PPID_STRING) {
						lost = true;
						say({event: "lost", tsn: data.tsn});
						return;
					}
				}
			}

			send(payload);
		};

		var receive = association.onChunk;
		var dropped:Bool = false;

		association.onChunk = function(chunk:SctpChunk, packet:SctpPacket):Void {
			if (!dropped) {
				var data = SctpDataChunk.fromChunk(chunk);

				if (data != null && data.streamId == channel.id && data.protocolId == SctpDataChunk.PPID_STRING) {
					dropped = true;
					data.payload.position = 0;
					say({event: "dropped", text: data.payload.readUTFBytes(data.payload.length)});
					return;
				}
			}

			receive(chunk, packet);
		};

		channel.onMessage = function(text:String):Void {
			received.push(text);

			if (received.length == 5) {
				say({event: "ordered-received", texts: received});
			}
		};

		lossy = channel;
		channel.send("lost");

		for (i in 1...6) {
			channel.send("kept-" + i);
		}
	}

	/** The channel losing its first message each way, until everything on it is settled. **/
	static var lossy:DataChannel = null;

	/** What arrived on it from the browser. **/
	static var received:Array<String> = [];

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
				// fails for the wrong reason. Longer while the lossy channel is
				// still waiting on the browser to move past what it lost, or on
				// the browser's own messages after the one lost on the way here.
				var settle = Sys.time() + 0.5;

				while (Sys.time() < settle || (lossy != null && Sys.time() < deadline && @:privateAccess connection.__transfer != null
					&& (@:privateAccess connection.__transfer.outstandingCount() > 0 || received.length < 5))) {
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
