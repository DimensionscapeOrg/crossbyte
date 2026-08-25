package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import crossbyte.net.rtc.PeerDescription;

/**
	A `PeerDescription` written as SDP, and read back from it.

	Two CrossByte peers have no reason to serialise a description any particular
	way -- they can pass the structure. A browser does: `RTCPeerConnection`
	takes an offer and an answer as SDP and gives them back the same way, so
	this is the translation, and it is the only thing standing between the stack
	and a browser at the other end.

	It renders exactly enough for a data channel. There is no media here, no
	codec negotiation, no BUNDLE of several streams -- a data channel is one
	`m=application` line, and everything the connection needs hangs off it.

	## What each line is doing

	The `m=` line names the protocol stack in the order it is layered:
	`UDP/DTLS/SCTP webrtc-datachannel`, which is precisely what CrossByte
	assembled. The port on it is 9, the discard port, because ICE decides the
	real one and SDP has to put something there; `c=IN IP4 0.0.0.0` is there for
	the same reason.

	`a=setup` is the one that decides who does what. `actpass` means the offerer
	will take whichever role the answer leaves; `active` is the DTLS client and
	`passive` the server. A browser offers `actpass` and expects an answer to
	choose, and choosing wrong produces two peers both waiting for a
	ClientHello.

	`a=fingerprint` is the authentication. Everything else in the document is
	routing.
**/
class SessionDescription {
	/** SDP lines are CRLF-terminated, and a browser is strict about it. **/
	private static inline var EOL:String = "\r\n";

	/** The DTLS client. **/
	public static inline var SETUP_ACTIVE:String = "active";

	/** The DTLS server. **/
	public static inline var SETUP_PASSIVE:String = "passive";

	/** Undecided: whichever role the answer leaves. **/
	public static inline var SETUP_ACTPASS:String = "actpass";

	/**
		The port SDP puts on a line whose real port ICE will choose.

		RFC 4145 uses 9, the discard port, precisely because it means nothing --
		a peer that dialled it would reach a service defined to throw traffic
		away, which is a safer accident than reaching something real.
	**/
	private static inline var UNUSED_PORT:Int = 9;

	/**
		Renders a description as an offer or an answer.

		@param setup Which DTLS role to claim. An offer usually says `actpass`;
		an answer must say `active` or `passive`, and must say the opposite of
		what it is answering.
	**/
	public static function toSdp(description:PeerDescription, setup:String = SETUP_ACTPASS):String {
		if (description == null) {
			throw new ArgumentError("A description is required.");
		}

		if (description.fingerprint == null || description.fingerprint.length == 0) {
			throw new ArgumentError("A description with no fingerprint cannot be written as SDP: the fingerprint is the whole of what authenticates the peer, and a document without one describes a session anybody could answer.");
		}

		var lines:Array<String> = [
			"v=0",
			// The origin's session id and version are required and, for a data
			// channel, unused. Constants rather than a clock: nothing here
			// renegotiates, so a changing version would only be noise.
			"o=- 0 0 IN IP4 127.0.0.1",
			"s=-",
			"t=0 0",
			"a=group:BUNDLE 0",
			"m=application " + UNUSED_PORT + " UDP/DTLS/SCTP webrtc-datachannel",
			"c=IN IP4 0.0.0.0",
			"a=mid:0",
			"a=ice-ufrag:" + description.usernameFragment,
			"a=ice-pwd:" + description.password,
			"a=fingerprint:sha-256 " + description.fingerprint,
			"a=setup:" + setup,
			"a=sctp-port:" + SctpPortDefault,
			"a=max-message-size:" + MaxMessageSize
		];

		if (description.candidates != null) {
			for (i in 0...description.candidates.length) {
				lines.push(candidateLine(description.candidates[i], i + 1));
			}
		}

		// Gathering is complete by the time this is rendered, so the peer is
		// told not to wait for candidates that will never trickle in.
		lines.push("a=end-of-candidates");

		return lines.join(EOL) + EOL;
	}

	/**
		Reads an offer or answer back into a description.

		Everything not needed for a data channel is ignored rather than
		rejected: a browser's offer carries lines this does not use, and
		refusing a document for containing more than the minimum would refuse
		every real one.

		@throws ArgumentError if the fingerprint or ICE credentials are missing,
		since a description without them cannot be connected on and failing here
		names the reason.
	**/
	public static function fromSdp(sdp:String):PeerDescription {
		if (sdp == null || sdp.length == 0) {
			throw new ArgumentError("An SDP document is required.");
		}

		var usernameFragment:String = null;
		var password:String = null;
		var fingerprint:String = null;
		var setup:String = null;
		var candidates:Array<CandidateDescription> = [];

		// Split on either ending: the RFC says CRLF and implementations mostly
		// comply, but a document that has been through a text field or a JSON
		// round trip may not have.
		for (raw in StringTools.replace(sdp, "\r\n", "\n").split("\n")) {
			var line = StringTools.trim(raw);

			if (line.length == 0) {
				continue;
			}

			if (StringTools.startsWith(line, "a=ice-ufrag:")) {
				usernameFragment = line.substr("a=ice-ufrag:".length);
			} else if (StringTools.startsWith(line, "a=ice-pwd:")) {
				password = line.substr("a=ice-pwd:".length);
			} else if (StringTools.startsWith(line, "a=setup:")) {
				setup = line.substr("a=setup:".length);
			} else if (StringTools.startsWith(line, "a=fingerprint:")) {
				fingerprint = readFingerprint(line);
			} else if (StringTools.startsWith(line, "a=candidate:")) {
				var candidate = readCandidate(line);

				if (candidate != null) {
					candidates.push(candidate);
				}
			}
		}

		if (fingerprint == null) {
			throw new ArgumentError("That SDP carries no sha-256 fingerprint, so there would be nothing to check the peer's certificate against.");
		}

		if (usernameFragment == null || password == null) {
			throw new ArgumentError("That SDP carries no ICE credentials, so no connectivity check could be signed.");
		}

		return {
			usernameFragment: usernameFragment,
			password: password,
			fingerprint: fingerprint,
			candidates: candidates,
			setup: setup
		};
	}

	/**
		The role to answer an offer with.

		`actpass` leaves the choice here, and `active` is the conventional
		answer -- it makes the answering peer the DTLS client, which is what a
		browser expects when it offers. An offer that has already committed to a
		role gets the opposite, because both peers taking the same one is two
		peers waiting for a ClientHello neither will send.
	**/
	public static function answerSetupFor(offered:String):String {
		return switch (offered) {
			case SETUP_ACTIVE: SETUP_PASSIVE;
			case SETUP_PASSIVE: SETUP_ACTIVE;
			default: SETUP_ACTIVE;
		}
	}

	/**
		Whether a peer claiming `setup` is the DTLS client.

		Which is also whether it should be the controlling peer here, the two
		being the same bit throughout this stack.
	**/
	public static function isClient(setup:String):Bool {
		return setup == SETUP_ACTIVE;
	}

	// ------------------------------------------------------------------

	/**
		`a=candidate:foundation component transport priority address port typ
		type`.

		The foundation groups candidates that share a base and a path, and is
		used to freeze redundant checks. Nothing here freezes anything, so each
		candidate gets its own -- which is the conservative answer: candidates
		that share a foundation may be skipped together, and getting that wrong
		loses paths, while giving each its own only forgoes an optimisation.
	**/
	private static function candidateLine(candidate:CandidateDescription, foundation:Int):String {
		return "a=candidate:" + foundation + " 1 udp " + candidate.priority + " " + candidate.address + " " + candidate.port + " typ "
			+ candidate.type;
	}

	private static function readCandidate(line:String):Null<CandidateDescription> {
		var parts = line.substr("a=candidate:".length).split(" ");

		// foundation, component, transport, priority, address, port, "typ", type
		if (parts.length < 8) {
			return null;
		}

		// TCP candidates are a thing a browser offers and this stack has no
		// transport for. Skipped rather than accepted into a check that could
		// only fail.
		if (parts[2].toLowerCase() != "udp") {
			return null;
		}

		var priority = Std.parseInt(parts[3]);
		var port = Std.parseInt(parts[5]);

		if (priority == null || port == null) {
			return null;
		}

		return {
			address: parts[4],
			port: port,
			type: parts[7],
			priority: priority
		};
	}

	/**
		`a=fingerprint:sha-256 AB:CD:...`, and only sha-256.

		A browser offers sha-256 and CrossByte computes sha-256. A document
		naming another hash is one whose certificate could not be checked here,
		and taking the digest anyway would compare two different functions'
		output and refuse every certificate.
	**/
	private static function readFingerprint(line:String):Null<String> {
		var value = line.substr("a=fingerprint:".length);
		var space = value.indexOf(" ");

		if (space <= 0) {
			return null;
		}

		if (value.substr(0, space).toLowerCase() != "sha-256") {
			return null;
		}

		return StringTools.trim(value.substr(space + 1)).toUpperCase();
	}

	/** The SCTP port both ends of a data channel use. **/
	private static var SctpPortDefault(get, never):Int;

	private static function get_SctpPortDefault():Int {
		return crossbyte.net.rtc._internal.sctp.SctpAssociation.DEFAULT_PORT;
	}

	/** What this stack will accept in one message, advertised so a peer knows. **/
	private static var MaxMessageSize(get, never):Int;

	private static function get_MaxMessageSize():Int {
		return crossbyte.net.rtc._internal.sctp.SctpAssociation.RECEIVE_WINDOW;
	}
}
