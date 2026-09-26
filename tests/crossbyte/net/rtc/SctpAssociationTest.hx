package crossbyte.net.rtc;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.SctpAssociation;
import crossbyte.net.rtc._internal.sctp.SctpAssociationState;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;
import crossbyte.net.rtc._internal.sctp.SctpParameter;
import utest.Assert;

/**
	Two associations opening one between them, with no network in the way.

	The handshake is four messages rather than three on purpose, and what the
	extra one buys, that the side being asked commits nothing until the asker
	has proved it can receive, is a property that can be tested directly here
	by watching what each side holds and when.
**/
class SctpAssociationTest extends utest.Test {
	private function unsupported():Bool {
		if (!SctpAssociation.isSupported) {
			Assert.isFalse(SctpAssociation.isSupported);
			return true;
		}

		return false;
	}

	/**
		The four-way handshake, end to end.
	**/
	public function testTwoPeersOpenAnAssociation():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var opened = false;
		pair.client.established.then(_ -> opened = true, _ -> {});

		Assert.isTrue(pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED
			&& pair.server.state == SctpAssociationState.ESTABLISHED), "the association never opened");

		Assert.isTrue(opened, "the established future never resolved");

		// Each side ends up holding the other's tag, which is what every later
		// packet is stamped with.
		Assert.equals(pair.client.localTag, pair.server.remoteTag);
		Assert.equals(pair.server.localTag, pair.client.remoteTag);
		Assert.notEquals(0, pair.client.localTag, "a zero tag would make every packet unverifiable");
		Assert.notEquals(0, pair.server.localTag);
	}

	/**
		Closing before it completes tells whoever was waiting.

		Every path that settled this future ran from the handshake, and closing
		is what stops the handshake, so a caller that closed mid-negotiation
		was left holding a future that could not settle either way. The same gap
		existed in every class in this stack that hands one out.
	**/
	public function testClosingBeforeTheAssociationOpensTellsWhoeverWaited():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var opened:Bool = false;
		var failure:String = null;
		pair.client.established.then(_ -> opened = true, error -> failure = error);

		pair.client.close();

		Assert.isFalse(opened, "a closed association reported itself established");
		Assert.notNull(failure, "closing left `established` pending forever");
	}

	/**
		The exchange takes exactly four messages and no more.

		INIT, INIT ACK, COOKIE ECHO, COOKIE ACK. A fifth would mean something is
		being retransmitted, which on a lossless wire means a message was not
		recognised.
	**/
	public function testTheHandshakeIsFourMessages():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		Assert.equals(4, pair.exchanged, "the handshake took " + pair.exchanged + " messages rather than four");
		Assert.equals(SctpPacket.CHUNK_INIT, pair.types[0]);
		Assert.equals(SctpPacket.CHUNK_INIT_ACK, pair.types[1]);
		Assert.equals(SctpPacket.CHUNK_COOKIE_ECHO, pair.types[2]);
		Assert.equals(SctpPacket.CHUNK_COOKIE_ACK, pair.types[3]);
	}

	/**
		The property the fourth message exists for.

		A peer that is asked to open an association holds nothing until a cookie
		comes back to it. That is what makes a flood of forged INITs from
		addresses that cannot answer cost the receiver nothing, the same
		attack SYN cookies were retrofitted onto TCP to survive, designed into
		SCTP from the start.
	**/
	public function testTheAnsweringPeerHoldsNothingUntilTheCookieReturns():Void {
		if (unsupported()) return;

		var pair = Pair.make();

		// Far enough for the INIT to arrive and be answered, and no further.
		pair.step();
		pair.step();

		Assert.notEquals(SctpAssociationState.ESTABLISHED, pair.server.state,
			"the answering peer opened the association before the cookie came back");

		// It answered, and it is still listening rather than holding a
		// half-open association.
		Assert.isTrue(pair.exchanged >= 2, "the INIT was never answered");
		Assert.equals(SctpAssociationState.LISTENING, pair.server.state);
	}

	/**
		A cookie that was never issued opens nothing.

		The cookie is the whole of what the answering side trusts, it holds no
		other state about the peer, so accepting one it did not issue would
		make the fourth message decorative and the defence with it.
	**/
	public function testAForgedCookieIsRefused():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.step();
		pair.step();

		// Somebody else's cookie, addressed correctly and stamped with the tag
		// the server handed out. Everything about it is right except that the
		// server never issued it.
		var forged = new ByteArray();

		for (i in 0...32) {
			forged.writeByte(i);
		}

		forged.position = 0;

		var packet = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.server.localTag,
			[new SctpChunk(SctpPacket.CHUNK_COOKIE_ECHO, 0, forged)]);

		pair.server.receive(packet.encode(), 0);

		Assert.notEquals(SctpAssociationState.ESTABLISHED, pair.server.state, "a cookie the server never issued opened an association");
	}

	/**
		A packet stamped with the wrong tag is not part of this association.

		Tags are what let an association survive a peer restarting on the same
		port: the new peer's packets carry a tag nobody here handed out, and are
		refused rather than folded into the old session.
	**/
	public function testAPacketWithTheWrongTagIsIgnored():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		var seen = 0;
		pair.server.onChunk = (_, _) -> seen++;

		// A chunk the data layer would want, on a tag that is not this
		// association's.
		var wrong = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.server.localTag + 1,
			[new SctpChunk(SctpPacket.CHUNK_SACK, 0)]);

		pair.server.receive(wrong.encode(), 0);
		Assert.equals(0, seen, "a packet carrying another association's tag was passed up");

		// And the same chunk with the right tag is.
		var right = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.server.localTag,
			[new SctpChunk(SctpPacket.CHUNK_SACK, 0)]);

		pair.server.receive(right.encode(), 0);
		Assert.equals(1, seen, "a packet on this association was not passed up");
	}

	/**
		The INIT is the one packet sent with a zero tag.

		There is nothing else to put there: the sender has not been told the
		peer's tag yet. Every packet after it carries one, and a peer that sent
		a second zero-tagged packet would be asking to have it discarded.
	**/
	public function testOnlyTheInitCarriesAZeroTag():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		Assert.equals(0, pair.tags[0], "the INIT should carry no tag, having none to carry");

		for (i in 1...pair.tags.length) {
			Assert.notEquals(0, pair.tags[i], "message " + i + " went out with a zero verification tag");
		}
	}

	/**
		Nothing answering is reported rather than waited on forever.
	**/
	public function testAnUnansweredInitEventuallyFails():Void {
		if (unsupported()) return;

		var alone = new SctpAssociation();
		var failure:String = null;
		alone.established.then(_ -> {}, error -> failure = error);

		alone.associate(0);

		var now = 0.0;

		for (_ in 0...200) {
			alone.poll(now);
			now += 1.0;
		}

		Assert.notNull(failure, "an association nobody answered never reported a failure");
		Assert.equals(SctpAssociationState.CLOSED, alone.state);
	}

	/**
		A peer that aborts is reported, with the reason it gave.

		An ABORT used to close the association without telling anything above
		it: no event, no future, and the channels on top went on reporting
		themselves open. This is what a browser's `pc.close()` puts on the
		wire, so it was the ordinary way for a peer to leave, and nothing heard
		it.
	**/
	public function testAnAbortFromThePeerIsReported():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		var reasons:Array<String> = [];
		pair.server.onClose = reason -> reasons.push(reason);

		// The peer leaving, and saying why.
		pair.client.abort("tab closed");
		pair.step();

		Assert.equals(SctpAssociationState.CLOSED, pair.server.state, "the ABORT did not end the association");
		Assert.equals(1, reasons.length, "a peer that aborted was reported " + reasons.length + " times rather than once");

		if (reasons.length == 1) {
			Assert.isTrue(reasons[0].indexOf("aborted") >= 0, "the reason does not say the peer aborted: " + reasons[0]);
			Assert.isTrue(reasons[0].indexOf("tab closed") >= 0, "the reason the peer gave was lost: " + reasons[0]);
		}

		// And the end that aborted is not told about its own decision.
		Assert.equals(SctpAssociationState.CLOSED, pair.client.state);
	}

	/**
		An ABORT stamped for some other association ends nothing.

		RFC 4960 section 8.5.1: the association's own tag, or the peer's
		reflected with the T bit set. It used to take any ABORT at all, which
		inside a DTLS session only the peer can send, but an ABORT belonging
		to an association that has already been replaced is still not about
		this one.
	**/
	public function testAnAbortCarryingTheWrongTagIsIgnored():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		var closes:Int = 0;
		pair.server.onClose = _ -> closes++;

		var stale = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.server.localTag + 1,
			[new SctpChunk(SctpPacket.CHUNK_ABORT, 0)]);
		pair.server.receive(stale.encode(), 0);

		// The peer's own tag without the flag saying it is reflected.
		var unflagged = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.server.remoteTag,
			[new SctpChunk(SctpPacket.CHUNK_ABORT, 0)]);
		pair.server.receive(unflagged.encode(), 0);

		Assert.equals(SctpAssociationState.ESTABLISHED, pair.server.state, "an ABORT for another association ended this one");
		Assert.equals(0, closes);

		// Reflected, and flagged as such: that one is ours.
		var reflected = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.server.remoteTag,
			[new SctpChunk(SctpPacket.CHUNK_ABORT, 0x01)]);
		pair.server.receive(reflected.encode(), 0);

		Assert.equals(SctpAssociationState.CLOSED, pair.server.state, "an ABORT with the peer's tag reflected was refused");
		Assert.equals(1, closes);
	}

	/**
		A HEARTBEAT is answered, with what it carried copied back unchanged.

		RFC 4960 section 8.3 says it must be. It never was: only DATA and SACK
		reached anything, and HEARTBEAT ACK was defined and never sent. A peer
		whose stack probes idle paths, a browser's does, counts every
		unanswered probe as a failure and gives the association up after a
		few minutes of a channel that only received.
	**/
	public function testAHeartbeatIsAnsweredWithWhatItCarried():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		var answers:Array<SctpChunk> = [];
		pair.client.onSend = function(payload:ByteArray):Void {
			var packet = SctpPacket.decode(payload);

			if (packet != null && packet.chunk(SctpPacket.CHUNK_HEARTBEAT_ACK) != null) {
				answers.push(packet.chunk(SctpPacket.CHUNK_HEARTBEAT_ACK));
			}
		};

		// Heartbeat Info, RFC 4960 section 3.3.5: opaque to everyone but the sender.
		var info = new ByteArray();
		info.endian = Endian.BIG_ENDIAN;
		info.writeShort(1);
		info.writeShort(12);
		info.writeDouble(1234.5);
		info.position = 0;

		pair.client.receive(pair.server.packetFor([new SctpChunk(SctpPacket.CHUNK_HEARTBEAT, 0, info)]), 0);

		Assert.equals(1, answers.length, "a HEARTBEAT drew " + answers.length + " answers rather than one");

		if (answers.length == 1) {
			var echoed = answers[0].value;
			var same:Bool = echoed.length == info.length;

			for (i in 0...info.length) {
				if (!same || echoed[i] != info[i]) {
					same = false;
					break;
				}
			}

			Assert.isTrue(same, "the HEARTBEAT ACK did not carry back what the HEARTBEAT did");
		}

		// Not for another association's tag.
		var stray = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.client.localTag + 1,
			[new SctpChunk(SctpPacket.CHUNK_HEARTBEAT, 0, info)]);
		pair.client.receive(stray.encode(), 0);
		Assert.equals(1, answers.length, "a HEARTBEAT for another association was answered");
	}

	/**
		A peer that shuts down gracefully is answered, and its going reported.

		RFC 4960 section 9.2: SHUTDOWN, SHUTDOWN ACK, SHUTDOWN COMPLETE. It was
		ignored, so the peer retransmitted its SHUTDOWN until it gave up and
		aborted, and this end heard of none of it.
	**/
	public function testAShutdownFromThePeerIsAnsweredAndReported():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		var answered:Int = 0;
		pair.client.onSend = function(payload:ByteArray):Void {
			var packet = SctpPacket.decode(payload);

			if (packet != null && packet.chunk(SctpPacket.CHUNK_SHUTDOWN_ACK) != null) {
				answered++;
			}
		};

		var reasons:Array<String> = [];
		pair.client.onClose = reason -> reasons.push(reason);

		// The peer has had everything this end sent, which is nothing.
		var cumulative = new ByteArray();
		cumulative.endian = Endian.BIG_ENDIAN;
		cumulative.writeInt((pair.client.localTsn - 1) | 0);
		cumulative.position = 0;

		pair.client.receive(pair.server.packetFor([new SctpChunk(SctpPacket.CHUNK_SHUTDOWN, 0, cumulative)]), 0);

		Assert.equals(1, answered, "a SHUTDOWN with nothing outstanding was not answered at once");
		Assert.equals(SctpAssociationState.SHUTDOWN_ACK_SENT, pair.client.state);
		Assert.equals(0, reasons.length, "the association was reported gone before the peer confirmed");

		// Lost, so the peer asks again, and is answered again.
		pair.client.receive(pair.server.packetFor([new SctpChunk(SctpPacket.CHUNK_SHUTDOWN, 0, cumulative)]), 0);
		Assert.equals(2, answered, "a repeated SHUTDOWN was not answered again");

		pair.client.receive(pair.server.packetFor([new SctpChunk(SctpPacket.CHUNK_SHUTDOWN_COMPLETE, 0)]), 0);

		Assert.equals(SctpAssociationState.CLOSED, pair.client.state, "SHUTDOWN COMPLETE did not close the association");
		Assert.equals(1, reasons.length, "a peer that shut down was reported " + reasons.length + " times");

		if (reasons.length == 1) {
			Assert.isTrue(reasons[0].indexOf("shut") >= 0, "the reason does not say the peer shut down: " + reasons[0]);
		}
	}

	/**
		A peer that asks to shut down and never confirms is still let go.
	**/
	public function testAShutdownThePeerNeverConfirmsStillEnds():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		var answered:Int = 0;
		pair.client.onSend = function(payload:ByteArray):Void {
			var packet = SctpPacket.decode(payload);

			if (packet != null && packet.chunk(SctpPacket.CHUNK_SHUTDOWN_ACK) != null) {
				answered++;
			}
		};

		var reasons:Array<String> = [];
		pair.client.onClose = reason -> reasons.push(reason);

		var cumulative = new ByteArray();
		cumulative.endian = Endian.BIG_ENDIAN;
		cumulative.writeInt((pair.client.localTsn - 1) | 0);
		cumulative.position = 0;

		pair.client.receive(pair.server.packetFor([new SctpChunk(SctpPacket.CHUNK_SHUTDOWN, 0, cumulative)]), 0);

		var now = 0.0;

		while (reasons.length == 0 && now < 600) {
			now += 0.5;
			pair.client.poll(now);
		}

		Assert.equals(1, reasons.length, "an unconfirmed shutdown never ended the association");
		Assert.equals(SctpAssociation.MAX_ATTEMPTS, answered, "the answer was sent " + answered + " times before giving up");
	}

	/**
		Both ends say they understand FORWARD TSN, and both hear it.

		RFC 3758 has a peer abandon nothing it sends, and act on no FORWARD TSN,
		unless the other said it understands them, with the parameter, or by
		listing the chunk as a supported extension. Neither INIT nor INIT ACK
		carried either, so a browser opening a channel with
		`maxRetransmits: 0` had it made reliable without a word.
	**/
	public function testBothEndsSayTheyUnderstandForwardTsn():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var init:SctpPacket = null;

		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		Assert.isTrue(pair.client.peerSupportsForwardTsn, "the answering end did not say it understands FORWARD TSN");
		Assert.isTrue(pair.server.peerSupportsForwardTsn, "the asking end did not say it understands FORWARD TSN");

		// And in both of the forms a peer may look for.
		var fresh = new SctpAssociation();
		fresh.onSend = payload -> init = SctpPacket.decode(payload);
		fresh.associate(0);

		var chunk = init != null ? init.chunk(SctpPacket.CHUNK_INIT) : null;

		if (chunk == null) {
			Assert.fail("no INIT was sent");
			return;
		}

		var parameters = SctpParameter.readAll(chunk.value, 16, chunk.value.length);
		Assert.notNull(SctpParameter.find(parameters, SctpParameter.FORWARD_TSN_SUPPORTED), "the INIT has no Forward-TSN-Supported parameter");

		var extensions = SctpParameter.find(parameters, SctpParameter.SUPPORTED_EXTENSIONS);
		Assert.notNull(extensions, "the INIT lists no supported extensions");

		if (extensions != null) {
			extensions.value.position = 0;
			Assert.equals(SctpPacket.CHUNK_FORWARD_TSN, extensions.value.readUnsignedByte(), "FORWARD TSN is not among the extensions listed");
		}

		fresh.close();
	}

	public function testStreamsAndWindowAreExchanged():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		pair.run(() -> pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED);

		Assert.equals(SctpAssociation.STREAM_COUNT, pair.client.peerOutboundStreams);
		Assert.equals(SctpAssociation.STREAM_COUNT, pair.server.peerInboundStreams);
		Assert.equals(SctpAssociation.RECEIVE_WINDOW, pair.client.peerReceiveWindow);
		Assert.notEquals(0, pair.client.remoteTsn, "the peer's initial TSN was never read");
	}
}

/** A client and a server, and the queue between them. **/
private class Pair {
	public var client:SctpAssociation;
	public var server:SctpAssociation;

	/** How many packets have crossed, and what each carried. **/
	public var exchanged:Int = 0;

	public var types:Array<Int> = [];
	public var tags:Array<Int> = [];

	private var toServer:Array<ByteArray> = [];
	private var toClient:Array<ByteArray> = [];
	private var now:Float = 0;

	public static function make():Pair {
		var pair = new Pair();
		pair.client = new SctpAssociation();
		pair.server = new SctpAssociation();

		pair.client.onSend = payload -> {
			pair.record(payload);
			pair.toServer.push(payload);
		};

		pair.server.onSend = payload -> {
			pair.record(payload);
			pair.toClient.push(payload);
		};

		pair.server.listen();
		pair.client.associate(0);
		return pair;
	}

	private function new() {}

	public function record(payload:ByteArray):Void {
		exchanged++;

		var packet = SctpPacket.decode(payload);

		if (packet != null && packet.chunks.length > 0) {
			types.push(packet.chunks[0].type);
			tags.push(packet.verificationTag);
		}
	}

	/**
		Delivers whatever is queued, once, in one hop.

		Both queues are taken before either is delivered. Reading the second one
		afterwards would include what the first delivery had just produced, so a
		single step would carry a packet there *and* the reply back, and a test
		counting hops, or checking what a peer holds partway through, would be
		measuring something other than what it says.
	**/
	public function step():Void {
		var outbound = toServer;
		var inbound = toClient;
		toServer = [];
		toClient = [];

		for (payload in outbound) {
			server.receive(payload, now);
		}

		for (payload in inbound) {
			client.receive(payload, now);
		}

		now += 0.01;
	}

	public function run(done:Void->Bool):Bool {
		for (_ in 0...100) {
			client.poll(now);
			server.poll(now);
			step();

			if (done()) {
				return true;
			}
		}

		return done();
	}
}
