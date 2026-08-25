package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import crossbyte.net.rtc.PeerDescription;
import utest.Assert;

/**
	SDP in and SDP out, which is the only thing between this stack and a
	browser.

	The offer used here is a real one, taken from Chrome. That matters more than
	a round trip does: a codec that reads back what it wrote agrees with itself
	perfectly and may still not understand a word a browser says.
**/
class SessionDescriptionTest extends utest.Test {
	/**
		An offer as Chrome actually writes one.

		Trimmed of the lines a data channel does not use, but otherwise exactly
		the shape and order a browser produces -- including the `a=` lines this
		codec ignores, since a parser that refused a document for containing
		more than the minimum would refuse every real one.
	**/
	private static inline var CHROME_OFFER:String = "v=0\r\n"
		+ "o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n"
		+ "s=-\r\n"
		+ "t=0 0\r\n"
		+ "a=group:BUNDLE 0\r\n"
		+ "a=extmap-allow-mixed\r\n"
		+ "a=msid-semantic: WMS\r\n"
		+ "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
		+ "c=IN IP4 0.0.0.0\r\n"
		+ "a=candidate:1467250027 1 udp 2122260223 192.168.0.196 46243 typ host generation 0 network-id 1\r\n"
		+ "a=candidate:435653019 1 tcp 1518280447 192.168.0.196 9 typ host tcptype active generation 0\r\n"
		+ "a=ice-ufrag:ETEn\r\n"
		+ "a=ice-pwd:OtSK0WRNHhqzUsHKnZaHhcHm\r\n"
		+ "a=ice-options:trickle\r\n"
		+ "a=fingerprint:sha-256 41:FE:38:80:C1:6C:0C:E2:5E:B1:5F:AF:41:4C:E5:3D:4C:1E:0C:1E:5D:2E:38:63:AA:35:0F:69:82:1A:1E:8C\r\n"
		+ "a=setup:actpass\r\n"
		+ "a=mid:0\r\n"
		+ "a=sctp-port:5000\r\n"
		+ "a=max-message-size:262144\r\n";

	/**
		A browser's offer is understood.

		The single most important case here, and the reason the vector is a real
		one rather than something this codec produced.
	**/
	public function testAChromeOfferIsUnderstood():Void {
		var description = SessionDescription.fromSdp(CHROME_OFFER);

		Assert.equals("ETEn", description.usernameFragment);
		Assert.equals("OtSK0WRNHhqzUsHKnZaHhcHm", description.password);
		Assert.equals("41:FE:38:80:C1:6C:0C:E2:5E:B1:5F:AF:41:4C:E5:3D:4C:1E:0C:1E:5D:2E:38:63:AA:35:0F:69:82:1A:1E:8C", description.fingerprint);
		Assert.equals("actpass", description.setup);
	}

	/**
		A TCP candidate is left out rather than tried.

		Chrome offers one and this stack has no transport for it. Accepting it
		would put a pair in the check list that could only ever fail, spending
		the retransmission budget to learn what the transport field already
		said.
	**/
	public function testATcpCandidateIsSkipped():Void {
		var description = SessionDescription.fromSdp(CHROME_OFFER);

		Assert.equals(1, description.candidates.length, "the TCP candidate should not have been taken");
		Assert.equals("192.168.0.196", description.candidates[0].address);
		Assert.equals(46243, description.candidates[0].port);
		Assert.equals("host", description.candidates[0].type);
		Assert.equals(2122260223, description.candidates[0].priority);
	}

	/**
		A candidate line carries trailing attributes, and they are not the type.

		Chrome appends `generation`, `network-id` and more after the type. A
		parser that read the last field, or split on the wrong count, would take
		one of those for the candidate type and rank every candidate as a relay.
	**/
	public function testTrailingCandidateAttributesAreNotMistakenForTheType():Void {
		var description = SessionDescription.fromSdp(CHROME_OFFER);

		Assert.equals("host", description.candidates[0].type, "a trailing attribute was read as the candidate type");
	}

	/**
		The priority survives, because both peers must sort by the same number.

		Recomputing it from the type locally would be free and wrong: the peer
		already decided what this candidate is worth and is ordering its own
		list by that.
	**/
	public function testThePeersPriorityIsKeptRatherThanRecomputed():Void {
		var description = SessionDescription.fromSdp(CHROME_OFFER);

		Assert.equals(2122260223, description.candidates[0].priority);

		// Not what this implementation would have computed for a host
		// candidate, which is the point.
		Assert.notEquals(crossbyte.net.ice.IceCandidate.computePriority(crossbyte.net.ice.IceCandidateType.HOST),
			description.candidates[0].priority);
	}

	public function testADescriptionRendersAndReadsBack():Void {
		var original:PeerDescription = {
			usernameFragment: "abcd",
			password: "a-password-of-adequate-length",
			fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
			candidates: [
				{address: "10.0.0.2", port: 50000, type: "host", priority: 2130706431},
				{address: "203.0.113.5", port: 61000, type: "srflx", priority: 1694498815}
			]
		};

		var back = SessionDescription.fromSdp(SessionDescription.toSdp(original, SessionDescription.SETUP_ACTIVE));

		Assert.equals(original.usernameFragment, back.usernameFragment);
		Assert.equals(original.password, back.password);
		Assert.equals(original.fingerprint, back.fingerprint);
		Assert.equals("active", back.setup);
		Assert.equals(2, back.candidates.length);
		Assert.equals("srflx", back.candidates[1].type);
		Assert.equals(1694498815, back.candidates[1].priority);
	}

	/**
		The lines a browser insists on.

		SDP is not a format that tolerates omissions: a missing `v=` or `m=` is
		refused outright, and a data channel without `a=sctp-port` describes a
		session with nothing to carry.
	**/
	public function testTheRenderedDocumentCarriesWhatABrowserRequires():Void {
		var sdp = SessionDescription.toSdp({
			usernameFragment: "abcd",
			password: "a-password-of-adequate-length",
			fingerprint: "AA:BB",
			candidates: []
		});

		for (required in [
			"v=0",
			"m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
			"c=IN IP4 0.0.0.0",
			"a=ice-ufrag:abcd",
			"a=fingerprint:sha-256 AA:BB",
			"a=mid:0",
			"a=sctp-port:5000",
			"a=setup:actpass"
		]) {
			Assert.isTrue(sdp.indexOf(required) >= 0, "the document is missing a line a browser requires: " + required);
		}
	}

	/**
		Lines end with CRLF, which a browser is strict about.

		A document with bare newlines is rejected by `setRemoteDescription`, and
		the failure names the parse rather than the ending.
	**/
	public function testLinesEndTheWayTheRfcSays():Void {
		var sdp = SessionDescription.toSdp({
			usernameFragment: "abcd",
			password: "a-password-of-adequate-length",
			fingerprint: "AA:BB",
			candidates: []
		});

		Assert.isTrue(sdp.indexOf("\r\n") >= 0);

		// No newline anywhere without a carriage return before it.
		for (i in 0...sdp.length) {
			if (sdp.charAt(i) == "\n") {
				Assert.equals("\r", sdp.charAt(i - 1), "a line ended with a bare newline at " + i);
			}
		}
	}

	/**
		Both peers must not take the same DTLS role.

		An answer of `active` to an offer of `active` is two peers each waiting
		for the other's ClientHello, and nothing in the resulting silence says
		why.
	**/
	public function testTheAnswerTakesTheOppositeRole():Void {
		Assert.equals("active", SessionDescription.answerSetupFor("actpass"));
		Assert.equals("passive", SessionDescription.answerSetupFor("active"));
		Assert.equals("active", SessionDescription.answerSetupFor("passive"));

		Assert.isTrue(SessionDescription.isClient("active"));
		Assert.isFalse(SessionDescription.isClient("passive"));
		Assert.isFalse(SessionDescription.isClient("actpass"));
	}

	/**
		A document with nothing to authenticate against is refused.

		The alternative is a connection that completes a handshake with whoever
		answered.
	**/
	public function testADocumentWithoutAFingerprintIsRefused():Void {
		var withoutFingerprint = StringTools.replace(CHROME_OFFER, "a=fingerprint:sha-256 ", "a=x-fingerprint:sha-256 ");

		Assert.raises(() -> SessionDescription.fromSdp(withoutFingerprint), ArgumentError);
		Assert.raises(() -> SessionDescription.fromSdp(""), ArgumentError);
		Assert.raises(() -> SessionDescription.fromSdp(null), ArgumentError);
	}

	/**
		A fingerprint under another hash is not a fingerprint this can check.

		Comparing a sha-1 digest against a sha-256 one refuses every
		certificate, so the document is refused instead, where the reason is
		still legible.
	**/
	public function testAFingerprintUnderAnotherHashIsRefused():Void {
		var sha1 = StringTools.replace(CHROME_OFFER, "a=fingerprint:sha-256 ", "a=fingerprint:sha-1 ");

		Assert.raises(() -> SessionDescription.fromSdp(sha1), ArgumentError);
	}

	public function testADescriptionWithoutAFingerprintCannotBeRendered():Void {
		Assert.raises(() -> SessionDescription.toSdp({
			usernameFragment: "abcd",
			password: "a-password-of-adequate-length",
			fingerprint: "",
			candidates: []
		}), ArgumentError);

		Assert.raises(() -> SessionDescription.toSdp(null), ArgumentError);
	}
}
