package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import crossbyte.net.rtc.PeerDescription;
import crossbyte.utils.IntParse;

/**
	A `PeerDescription` written as SDP, and read back from it.

	Two CrossByte peers have no reason to serialise a description any particular
	way, they can pass the structure. A browser does: `RTCPeerConnection`
	takes an offer and an answer as SDP and gives them back the same way, so
	this is the translation, and it is the only thing standing between the stack
	and a browser at the other end.

	It renders exactly enough for a data channel. There is no media here, no
	codec negotiation, no BUNDLE of several streams, a data channel is one
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

		RFC 4145 uses 9, the discard port, precisely because it means nothing,
		a peer that dialled it would reach a service defined to throw traffic
		away, which is a safer accident than reaching something real.
	**/
	private static inline var UNUSED_PORT:Int = 9;

	/**
		What a document that says nothing about message size is taken to allow:
		RFC 8841's default, 64 KB.
	**/
	public static inline var DEFAULT_MAX_MESSAGE_SIZE:Int = 65536;

	/** The media section id written when a description has none of its own. **/
	public static inline var DEFAULT_MID:String = "0";

	/**
		Renders a description as an offer or an answer.

		@param setup Which DTLS role to claim, overriding what the description
		already says. Rarely wanted: `PeerConnection.description()` fills the
		field in from the role it has settled on, and passing a different value
		here writes a document that disagrees with the connection sending it.
		Omitted, the description's own answer is used.
	**/
	public static function toSdp(description:PeerDescription, ?setup:String):String {
		if (description == null) {
			throw new ArgumentError("A description is required.");
		}

		if (description.fingerprint == null || description.fingerprint.length == 0) {
			throw new ArgumentError("A description with no fingerprint cannot be written as SDP: the fingerprint is the whole of what authenticates the peer, and a document without one describes a session anybody could answer.");
		}

		var role:String = setup != null ? setup : (description.setup != null ? description.setup : SETUP_ACTPASS);

		// The offer's own identification for the section, which an answer has
		// to repeat: a browser matches the answer's m= section to its offer's
		// by it, and an answer saying "0" to an offer that said "data" is one
		// it cannot place.
		var mid:String = description.mid != null ? description.mid : DEFAULT_MID;

		if (!isToken(mid)) {
			throw new ArgumentError("A media section id must be an SDP token, not \"" + mid + "\".");
		}

		var lines:Array<String> = [
			"v=0",
			// The origin's session id and version are required and, for a data
			// channel, unused. Constants rather than a clock: nothing here
			// renegotiates, so a changing version would only be noise.
			"o=- 0 0 IN IP4 127.0.0.1",
			"s=-",
			"t=0 0",
			"a=group:BUNDLE " + mid,
			"m=application " + UNUSED_PORT + " UDP/DTLS/SCTP webrtc-datachannel",
			"c=IN IP4 0.0.0.0",
			"a=mid:" + mid,
			"a=ice-ufrag:" + description.usernameFragment,
			"a=ice-pwd:" + description.password,
			"a=fingerprint:sha-256 " + description.fingerprint,
			"a=setup:" + role,
			"a=sctp-port:" + SctpPortDefault,
			"a=max-message-size:" + (description.maxMessageSize != null ? description.maxMessageSize : MaxMessageSize)
		];

		if (description.candidates != null) {
			for (i in 0...description.candidates.length) {
				lines.push("a=" + writeCandidate(description.candidates[i], i + 1));
			}
		}

		// Only when the description says gathering is over. It was written into
		// every document, so an answer sent before its reflexive candidate had
		// come back told the peer to stop listening for the very candidate that
		// would have reached it.
		if (description.endOfCandidates == true) {
			lines.push("a=end-of-candidates");
		}

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
		var mid:String = null;
		var endOfCandidates:Bool = false;
		var maxMessageSize:Int = DEFAULT_MAX_MESSAGE_SIZE;
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
			} else if (StringTools.startsWith(line, "a=max-message-size:")) {
				maxMessageSize = readMaxMessageSize(line.substr("a=max-message-size:".length));
			} else if (StringTools.startsWith(line, "a=fingerprint:")) {
				// The first one this can check, however many follow. A peer may
				// list several, under several hashes, and a later sha-1 line used
				// to overwrite the sha-256 before it with nothing, refusing the
				// whole document for lacking what it had.
				var read = readFingerprint(line);

				if (fingerprint == null && read != null) {
					fingerprint = read;
				}
			} else if (StringTools.startsWith(line, "a=mid:")) {
				// A data channel is one section, so the first is the one.
				var value = StringTools.trim(line.substr("a=mid:".length));

				if (mid == null && isToken(value)) {
					mid = value;
				}
			} else if (line == "a=end-of-candidates") {
				endOfCandidates = true;
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
			setup: setup,
			mid: mid,
			endOfCandidates: endOfCandidates,
			maxMessageSize: maxMessageSize
		};
	}

	/**
		`a=max-message-size`'s value: a size, or 0 for any size.

		Digits too many for an Int are a peer saying its limit is larger than
		anything this end could send, which is what 0 says too. Anything that
		is not digits at all is ignored, leaving the RFC's default.
	**/
	private static function readMaxMessageSize(text:String):Int {
		text = StringTools.trim(text);

		var size:Int = IntParse.decimal(text);

		if (size >= 0) {
			return size;
		}

		return allDigits(text) ? 0 : DEFAULT_MAX_MESSAGE_SIZE;
	}

	/**
		Whether a media section id is an SDP token (RFC 4566): printable, and
		free of the spaces and separators that would let it spill into the rest
		of the line, or, with a line break, into a line of its own.
	**/
	private static function isToken(text:String):Bool {
		if (text == null || text.length == 0 || text.length > 256) {
			return false;
		}

		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			var token:Bool = (code >= "0".code && code <= "9".code) || (code >= "a".code && code <= "z".code)
				|| (code >= "A".code && code <= "Z".code) || "!#$%&'*+-.^_`{|}~".indexOf(String.fromCharCode(code)) >= 0;

			if (!token) {
				return false;
			}
		}

		return true;
	}

	/** Printable, and one word: nothing at or below a space, nothing past `~`. **/
	private static function isField(text:String):Bool {
		if (text == null || text.length == 0) {
			return false;
		}

		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);

			if (code <= " ".code || code > "~".code) {
				return false;
			}
		}

		return true;
	}

	private static function allDigits(text:String):Bool {
		if (text.length == 0) {
			return false;
		}

		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);

			if (code < "0".code || code > "9".code) {
				return false;
			}
		}

		return true;
	}

	/**
		The role to answer an offer with.

		`actpass` leaves the choice here, and `active` is the conventional
		answer, it makes the answering peer the DTLS client, which is what a
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

		Which is *not* the same as being ICE-controlling, though for two peers
		that both use `PeerConnection` the two usually land on opposite sides
		and one could be mistaken for the other. A browser separates them
		plainly: it offers, so it nominates, and it offers `actpass`, so the
		peer answering it is the DTLS client while the browser keeps the ICE
		role. What follows the value here is the handshake, the SCTP
		association, and which end takes the even data channel streams.
	**/
	public static function isClient(setup:String):Bool {
		return setup == SETUP_ACTIVE;
	}

	/**
		One candidate as a line: `candidate:foundation component transport
		priority address port typ type`, and `raddr`/`rport` after it for
		anything that is not a host candidate.

		Without the `a=`, which is how a trickled candidate travels, what a
		browser's `RTCIceCandidate.candidate` holds and `addIceCandidate` takes.
		A description written as SDP puts `a=` in front of each.

		The foundation groups candidates that share a base and a path, and is
		used to freeze redundant checks. Nothing here freezes anything, so each
		candidate gets its own, which is the conservative answer: candidates
		that share a foundation may be skipped together, and getting that wrong
		loses paths, while giving each its own only forgoes an optimisation.

		A reflexive or relayed candidate's related address is the private one
		it was found from, so one the description does not give is written as
		`0.0.0.0` port 0, as browsers do: the grammar asks for the field, and
		the peer has no use for this machine's inside address.

		@param foundation Distinct per candidate within one description.
	**/
	public static function writeCandidate(candidate:CandidateDescription, foundation:Int = 1):String {
		// Fields are separated by spaces and lines by line breaks, so a value
		// holding either would write lines of its own into the document.
		if (!isField(candidate.address) || !isField(candidate.type)
			|| (candidate.relatedAddress != null && !isField(candidate.relatedAddress))) {
			throw new ArgumentError("A candidate's address and type must be single words, with no spaces or line breaks.");
		}

		var line = "candidate:" + foundation + " 1 udp " + candidate.priority + " " + candidate.address + " " + candidate.port + " typ "
			+ candidate.type;

		if (candidate.relatedAddress != null && candidate.relatedPort != null) {
			line += " raddr " + candidate.relatedAddress + " rport " + candidate.relatedPort;
		} else if (candidate.type != "host") {
			line += " raddr 0.0.0.0 rport 0";
		}

		return line;
	}

	/**
		Reads one candidate line, with or without its `a=`: a line from a
		description, or one the peer trickled.

		Public so trickled candidates can be read the way a description's are.
		It was private, and an application passing a browser's candidates on had
		to write its own parser, and get the field order right itself.

		@return The candidate, or null for one this stack cannot use: TCP, a
		component other than the one a data channel has, or a priority or port
		that is not a number in range. Skipped rather than refused, since the
		candidates are the peer's to choose and one unusable one is not a
		reason to fail the rest.
	**/
	public static function readCandidate(line:String):Null<CandidateDescription> {
		if (line == null) {
			return null;
		}

		var text = StringTools.trim(line);

		if (StringTools.startsWith(text, "a=")) {
			text = text.substr(2);
		}

		if (!StringTools.startsWith(text, "candidate:")) {
			return null;
		}

		var parts = [for (part in text.substr("candidate:".length).split(" ")) if (part.length > 0) part];

		// foundation, component, transport, priority, address, port, "typ", type
		if (parts.length < 8 || parts[6] != "typ") {
			return null;
		}

		// A data channel has one component. RTP's second would be a different
		// flow, and pairing it as the first would check a path nothing uses.
		if (parts[1] != "1") {
			return null;
		}

		// TCP candidates are a thing a browser offers and this stack has no
		// transport for. Skipped rather than accepted into a check that could
		// only fail.
		if (parts[2].toLowerCase() != "udp") {
			return null;
		}

		// RFC 8445: a priority from 1 to 2^31 - 1, and a port that can be
		// dialled. IntParse answers the same for text a peer wrote on every
		// target, where Std.parseInt does not.
		var priority:Int = IntParse.decimal(parts[3]);
		var port:Int = IntParse.decimal(parts[5], 65535);

		if (priority < 1 || port < 1) {
			return null;
		}

		var candidate:CandidateDescription = {
			address: parts[4],
			port: port,
			type: parts[7],
			priority: priority
		};

		// What follows the type is name and value in pairs, in no fixed order.
		var at:Int = 8;

		while (at + 1 < parts.length) {
			switch (parts[at]) {
				case "raddr":
					candidate.relatedAddress = parts[at + 1];
				case "rport":
					var related:Int = IntParse.decimal(parts[at + 1], 65535);

					if (related >= 0) {
						candidate.relatedPort = related;
					}
				default:
			}

			at += 2;
		}

		return candidate;
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

	/**
		What this stack will accept in one message, advertised so a peer knows.

		The largest message the receiver reassembles. It used to be the receive
		window, twice that: a peer told two megabytes had anything over one
		acknowledged fragment by fragment and then dropped whole, so its sender
		saw success and nothing arrived.
	**/
	private static var MaxMessageSize(get, never):Int;

	private static function get_MaxMessageSize():Int {
		return crossbyte.net.rtc._internal.sctp.SctpDataTransfer.MAX_REASSEMBLY;
	}
}
