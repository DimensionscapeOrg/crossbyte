package crossbyte.net.rtc;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.SctpAssociation;
import crossbyte.net.rtc._internal.sctp.SctpAssociationState;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;
import utest.Assert;

/**
	Two associations opening one between them, with no network in the way.

	The handshake is four messages rather than three on purpose, and what the
	extra one buys -- that the side being asked commits nothing until the asker
	has proved it can receive -- is a property that can be tested directly here
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
		addresses that cannot answer cost the receiver nothing -- the same
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

		The cookie is the whole of what the answering side trusts -- it holds no
		other state about the peer -- so accepting one it did not issue would
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
			[new SctpChunk(SctpPacket.CHUNK_HEARTBEAT, 0)]);

		pair.server.receive(wrong.encode(), 0);
		Assert.equals(0, seen, "a packet carrying another association's tag was passed up");

		// And the same chunk with the right tag is.
		var right = new SctpPacket(SctpAssociation.DEFAULT_PORT, SctpAssociation.DEFAULT_PORT, pair.server.localTag,
			[new SctpChunk(SctpPacket.CHUNK_HEARTBEAT, 0)]);

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
		single step would carry a packet there *and* the reply back -- and a test
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
