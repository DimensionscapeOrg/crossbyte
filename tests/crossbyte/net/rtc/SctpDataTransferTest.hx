package crossbyte.net.rtc;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.SctpAssociation;
import crossbyte.net.rtc._internal.sctp.SctpAssociationState;
import crossbyte.net.rtc._internal.sctp.SctpDataChunk;
import crossbyte.net.rtc._internal.sctp.SctpDataTransfer;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;
import utest.Assert;

/**
	Messages over an open association, with a wire that can be told to misbehave.

	The guarantees this layer makes, reliable, and ordered per stream, are
	only visible when something goes wrong, so the harness here can drop packets
	and reorder them on demand. Over a wire that never loses anything, an
	implementation that never retransmits and one that does look identical.
**/
class SctpDataTransferTest extends utest.Test {
	/** A SACK saying what has arrived and how much room is left. **/
	private function sack(cumulative:Int, window:Int):SctpChunk {
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeInt(cumulative);
		value.writeInt(window);
		value.writeShort(0);
		value.writeShort(0);
		value.position = 0;
		return new SctpChunk(SctpPacket.CHUNK_SACK, 0, value);
	}

	/** The window a SACK built right now would offer the peer. **/
	private function advertised(transfer:SctpDataTransfer):Int {
		var sack = @:privateAccess transfer.__buildSack();
		sack.value.position = 4;
		return sack.value.readInt();
	}

	/** Everything the receiver is holding, walked rather than trusted. **/
	private function walked(transfer:SctpDataTransfer):Int {
		var total:Int = 0;

		for (key in (@:privateAccess transfer.__partial).keys()) {
			for (fragment in (@:privateAccess transfer.__partial).get(key).fragments) {
				total += fragment.payload.length;
			}
		}

		for (streamId in (@:privateAccess transfer.__held).keys()) {
			for (message in (@:privateAccess transfer.__held).get(streamId).bySequence) {
				total += message.payload.length;
			}
		}

		return total;
	}

	/** What is really in the network: sent, and neither acknowledged nor found lost. **/
	private function inFlight(transfer:SctpDataTransfer):Int {
		var total:Int = 0;
		var all = @:privateAccess transfer.__unacknowledged;

		for (i in (@:privateAccess transfer.__outstandingAt)...all.length) {
			var sent = all[i];

			if (!sent.acked && !sent.lost) {
				total += sent.data.payload.length;
			}
		}

		return total;
	}

	/** A payload that says which sequence it belongs to. **/
	private function numbered(sequence:Int):ByteArray {
		var payload = new ByteArray();
		payload.writeShort(sequence);
		payload.position = 0;
		return payload;
	}

	private function filled(size:Int):ByteArray {
		var payload = new ByteArray();
		payload.length = size;
		payload.position = 0;
		return payload;
	}

	private function unsupported():Bool {
		if (!SctpAssociation.isSupported) {
			Assert.isFalse(SctpAssociation.isSupported);
			return true;
		}

		return false;
	}

	public function testAMessageCrossesIntact():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var got:String = null;
		pair.serverData.onMessage = (_, payload, _) -> {
			payload.position = 0;
			got = payload.readUTFBytes(payload.length);
		};

		pair.clientData.send(0, text("a message"), SctpDataChunk.PPID_STRING, true, pair.now);
		pair.run(() -> got != null);

		Assert.equals("a message", got);
	}

	/**
		A message larger than one packet arrives as one message.

		Cut into fragments carrying the same stream sequence number, the first
		flagged B and the last E, and held at the receiver until both ends are
		present. Half a message delivered would be worse than none.
	**/
	public function testALargeMessageIsFragmentedAndReassembled():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var got:ByteArray = null;
		pair.serverData.onMessage = (_, payload, _) -> got = payload;

		// Several times the per-chunk limit, so this is genuinely fragmented.
		var large = new ByteArray();

		for (i in 0...5000) {
			large.writeByte(i & 0xFF);
		}

		large.position = 0;

		pair.clientData.send(0, large, SctpDataChunk.PPID_BINARY, true, pair.now);
		pair.run(() -> got != null);

		Assert.notNull(got, "a fragmented message never arrived");

		if (got == null) {
			return;
		}

		Assert.equals(5000, got.length, "the reassembled message is the wrong length");

		got.position = 0;
		var intact = true;

		for (i in 0...5000) {
			if (got.readUnsignedByte() != (i & 0xFF)) {
				intact = false;
				break;
			}
		}

		Assert.isTrue(intact, "the fragments were reassembled in the wrong order");
	}

	/**
		A dropped fragment is sent again.

		The wire swallows the first packet outright. Nothing about the message
		changes; it simply takes a retransmission to arrive, which is what
		reliable means and what a lossless test cannot demonstrate.
	**/
	public function testADroppedFragmentIsRetransmitted():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var got:String = null;
		pair.serverData.onMessage = (_, payload, _) -> {
			payload.position = 0;
			got = payload.readUTFBytes(payload.length);
		};

		pair.dropNextToServer = 1;
		pair.clientData.send(0, text("survives a loss"), SctpDataChunk.PPID_STRING, true, pair.now);

		Assert.isTrue(pair.run(() -> got != null), "a dropped fragment was never retransmitted");
		Assert.equals("survives a loss", got);
	}

	/**
		Ordered messages are delivered in order, whatever order they arrive in.

		The wire holds the first message back until the second has passed, so a
		receiver that delivered on arrival would hand them over backwards. This
		is the guarantee, and it is only visible when the network misbehaves.
	**/
	public function testOrderedMessagesAreDeliveredInOrder():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var order:Array<String> = [];
		pair.serverData.onMessage = (_, payload, _) -> {
			payload.position = 0;
			order.push(payload.readUTFBytes(payload.length));
		};

		pair.reorderNextToServer = true;
		pair.clientData.send(0, text("first"), SctpDataChunk.PPID_STRING, true, pair.now);
		pair.clientData.send(0, text("second"), SctpDataChunk.PPID_STRING, true, pair.now);

		pair.run(() -> order.length == 2);

		Assert.equals(2, order.length, "both messages should arrive");

		if (order.length == 2) {
			Assert.equals("first", order[0], "the messages were delivered in the order they arrived rather than the order they were sent");
			Assert.equals("second", order[1]);
		}
	}

	/**
		Unordered messages do not wait.

		The same reordering, and this time the receiver is expected to hand each
		one over as it lands. Unordered is not unreliable, both still arrive,
		it just declines to hold one message for another.
	**/
	public function testUnorderedMessagesDoNotWait():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var order:Array<String> = [];
		pair.serverData.onMessage = (_, payload, _) -> {
			payload.position = 0;
			order.push(payload.readUTFBytes(payload.length));
		};

		pair.reorderNextToServer = true;
		pair.clientData.send(0, text("first"), SctpDataChunk.PPID_STRING, false, pair.now);
		pair.clientData.send(0, text("second"), SctpDataChunk.PPID_STRING, false, pair.now);

		pair.run(() -> order.length == 2);

		Assert.equals(2, order.length);

		if (order.length == 2) {
			Assert.equals("second", order[0], "an unordered message was held back for one sent before it");
		}
	}

	/**
		Streams do not block each other.

		A message held up on one stream must not delay a message on another,
		which is the entire reason SCTP has streams and the reason a data
		channel is not simply run over TCP.
	**/
	public function testAStalledStreamDoesNotBlockAnother():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var arrived:Array<Int> = [];
		pair.serverData.onMessage = (streamId, _, _) -> arrived.push(streamId);

		// Stream 0's first message goes missing, so its second has to wait. The
		// message on stream 1 has nothing to wait for.
		pair.dropNextToServer = 1;
		pair.clientData.send(0, text("held up"), SctpDataChunk.PPID_STRING, true, pair.now);
		pair.clientData.send(1, text("unrelated"), SctpDataChunk.PPID_STRING, true, pair.now);

		pair.run(() -> arrived.length >= 1);

		Assert.isTrue(arrived.length >= 1, "nothing arrived at all");
		Assert.equals(1, arrived[0], "the message on the other stream waited for a stream it has nothing to do with");
	}

	/**
		Data the peer never acknowledges ends the association, and says so.

		After the last retransmission the fragment was dropped and the rest
		carried on. On an ordered stream that is a hole nothing will ever fill:
		everything behind it stalled for good, later fragments were resent up
		to eleven times, and the association went on reporting itself open
		while its peer was, by RFC 4960's own definition, unreachable.
	**/
	public function testDataThePeerNeverAcknowledgesEndsTheAssociation():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var reasons:Array<String> = [];
		pair.client.onClose = reason -> reasons.push(reason);

		pair.cutToServer = true;
		pair.clientData.send(0, filled(4 * SctpDataTransfer.MAX_PAYLOAD), SctpDataChunk.PPID_BINARY, true, pair.now);

		// Long enough for any retransmission schedule to run out, stepped
		// rather than run so the clock is the one being measured.
		var t0 = pair.now;

		while (reasons.length == 0 && pair.now - t0 < 600) {
			pair.clientData.poll(pair.now);
			pair.serverData.poll(pair.now);
			pair.step();
		}

		Assert.equals(1, reasons.length, "unacknowledged data ended the association " + reasons.length + " times rather than once");
		Assert.equals(SctpAssociationState.CLOSED, pair.client.state, "the association went on after its peer stopped acknowledging");

		if (reasons.length > 0) {
			Assert.isTrue(reasons[0].indexOf("acknowledg") >= 0, "the reason does not say what happened: " + reasons[0]);
		}

		// And nothing is sent into an association that has ended.
		var sent:Int = 0;
		pair.client.onSend = _ -> sent++;
		pair.clientData.poll(pair.now + 60);
		Assert.equals(0, sent, "an ended association kept retransmitting");
	}

	/**
		One send does not put the whole window on the wire at once.

		A megabyte went out in one call as 1,024 packets, because the only limit
		was the peer's window, which was two megabytes. Whatever path lay
		between could take it or drop it. Now the congestion window bounds what
		is in flight and no more than `MAX_BURST` packets leave together.
	**/
	public function testOneSendDoesNotBurstTheWholeWindow():Void {
		if (unsupported()) return;

		var link = Link.open();
		var packets:Int = 0;
		link.watchToServer = _ -> packets++;

		link.clientData.send(0, filled(1024 * 1024), SctpDataChunk.PPID_BINARY, true, link.now);

		Assert.isTrue(packets > 0, "nothing was sent at all");
		Assert.isTrue(packets <= SctpDataTransfer.MAX_BURST,
			"one send put " + packets + " packets on the wire at once, where " + SctpDataTransfer.MAX_BURST + " is the most");
		Assert.isTrue(link.clientData.bufferedAmount > 0, "a megabyte went out in one go");
	}

	/**
		A path that can carry only so much still delivers a large message.

		The bottleneck here drains two hundred packets a second and queues
		sixteen; what arrives while the queue is full is lost, as it is at a
		real one. A sender that put the peer's whole window on the wire at
		once, and resent each fragment on a fixed timer, had most of every
		burst dropped, resent it into the same queue, and gave fragments up
		after ten tries, a megabyte never arrived.
	**/
	public function testACongestedPathStillDeliversALargeMessage():Void {
		if (unsupported()) return;

		var link = Link.open();
		link.rate = 200;
		link.queueLimit = 16;

		var delivered:Int = -1;
		link.serverData.onMessage = (_, payload, _) -> delivered = payload.length;

		link.clientData.send(0, filled(1024 * 1024), SctpDataChunk.PPID_BINARY, true, link.now);
		link.runUntil(() -> delivered >= 0, 60);

		Assert.equals(1024 * 1024, delivered, "a megabyte through a congested path never arrived");
		Assert.equals(SctpAssociationState.ESTABLISHED, link.client.state, "the association gave up on a path that was only slow");

		// Not delivered by brute force: most of what went out got through.
		Assert.isTrue(link.dropped * 4 < link.sentToServer,
			link.dropped + " of " + link.sentToServer + " packets were dropped at the bottleneck");
	}

	/**
		A loss that later packets reveal is repaired without waiting out a timeout.

		The fragments sent after the lost one arrive, and the SACKs they draw
		each say the lost one is still missing. Three of those and it goes
		again, a round trip or so after it was lost. It used to wait for its own
		fixed half-second timer whatever the path was saying.
	**/
	public function testALossLaterPacketsRevealIsRepairedWithoutATimeout():Void {
		if (unsupported()) return;

		var link = Link.open();
		link.delay = 0.02;

		var dropped:Bool = false;
		link.dropToServer = function(payload:ByteArray):Bool {
			// The second DATA packet, once.
			if (!dropped && link.sentToServer == 2) {
				dropped = true;
				return true;
			}

			return false;
		};

		var delivered:Int = 0;
		link.serverData.onMessage = (_, _, _) -> delivered++;

		var start:Float = link.now;

		for (i in 0...12) {
			link.clientData.send(0, filled(SctpDataTransfer.MAX_PAYLOAD), SctpDataChunk.PPID_BINARY, true, link.now);
		}

		link.runUntil(() -> delivered == 12, 10);

		Assert.isTrue(dropped, "the harness never dropped anything, so this proves nothing");
		Assert.equals(12, delivered, "not everything arrived");
		Assert.isTrue(link.now - start < SctpDataTransfer.MIN_RTO,
			"the loss took " + (link.now - start) + " s to repair, which is a timeout rather than a fast retransmit");
	}

	/**
		A slow path is not flooded with copies once its round trip is known.

		The retransmission timer was a fixed half second, so on a path with a
		round trip of a second and a half every fragment was sent three times
		before its acknowledgement could possibly arrive, into whatever
		congestion made the path slow. The timer is measured now, and once it
		has been, nothing goes twice that the peer received.
	**/
	public function testASlowPathIsNotFloodedWithCopies():Void {
		if (unsupported()) return;

		var link = Link.open();
		link.delay = 0.75;

		var transmissions:Map<Int, Int> = new Map();
		link.watchToServer = function(payload:ByteArray):Void {
			var packet = SctpPacket.decode(payload);

			for (chunk in packet.chunks) {
				var data = SctpDataChunk.fromChunk(chunk);

				if (data != null) {
					transmissions.set(data.tsn, (transmissions.exists(data.tsn) ? transmissions.get(data.tsn) : 0) + 1);
				}
			}
		};

		var delivered:Int = 0;
		link.serverData.onMessage = (_, _, _) -> delivered++;

		// Two exchanges first, to have a round trip to measure. The first
		// fragment outlives the one second timeout a transfer starts with and
		// is sent twice, and Karn's rule will not time a fragment sent twice;
		// the second is what gets measured.
		for (i in 0...2) {
			link.clientData.send(0, filled(100), SctpDataChunk.PPID_BINARY, true, link.now);
			link.runUntil(() -> delivered == i + 1 && link.clientData.outstandingCount() == 0, 30);
		}

		transmissions = new Map();

		for (i in 0...6) {
			link.clientData.send(0, filled(100), SctpDataChunk.PPID_BINARY, true, link.now);
		}

		link.runUntil(() -> delivered == 8 && link.clientData.outstandingCount() == 0, 60);

		Assert.equals(8, delivered, "the messages never arrived");

		var copies:Int = 0;
		var tsns:Int = 0;

		for (tsn in transmissions.keys()) {
			tsns++;
			copies += transmissions.get(tsn);
		}

		Assert.isTrue(tsns > 0, "nothing was watched");
		Assert.equals(tsns, copies, "over a path with a 1.5 second round trip, " + tsns + " fragments went out " + copies
			+ " times: the timeout is shorter than the round trip");
	}

	/**
		A timeout that runs out doubles, rather than coming round again as soon.

		RFC 6298 section 5.5. The old schedule grew by half a second a time, so
		a path that had gone was resent into at an interval that barely moved.
	**/
	public function testATimeoutThatRunsOutDoubles():Void {
		if (unsupported()) return;

		var link = Link.open();
		link.cut = true;

		var sentAt:Array<Float> = [];
		link.watchToServer = _ -> sentAt.push(link.now);

		link.clientData.send(0, filled(100), SctpDataChunk.PPID_BINARY, true, link.now);
		link.runUntil(() -> sentAt.length >= 5, 120);

		Assert.isTrue(sentAt.length >= 5, "the fragment was sent " + sentAt.length + " times in two minutes");

		if (sentAt.length >= 5) {
			var first:Float = sentAt[2] - sentAt[1];
			var second:Float = sentAt[3] - sentAt[2];
			var third:Float = sentAt[4] - sentAt[3];

			Assert.floatEquals(first * 2, second, 0.05, "the timeout went from " + first + " to " + second + " rather than doubling");
			Assert.floatEquals(second * 2, third, 0.05, "the timeout went from " + second + " to " + third + " rather than doubling");
		}

		// And the window it may send into after a timeout is one packet.
		Assert.equals(SctpDataTransfer.MTU, link.clientData.congestionWindow);
	}

	/**
		The window grows while the path delivers, and halves when it loses.

		Slow start: every acknowledgement of a full window opens it further,
		so a transfer that starts cautious reaches the path's capacity in a
		few round trips. A loss says where that capacity was, and the window
		goes to half of what it had grown to.
	**/
	public function testTheWindowGrowsWhileThePathDeliversAndHalvesOnALoss():Void {
		if (unsupported()) return;

		var link = Link.open();
		link.delay = 0.01;

		var delivered:Int = 0;
		link.serverData.onMessage = (_, _, _) -> delivered++;

		link.clientData.send(0, filled(256 * 1024), SctpDataChunk.PPID_BINARY, true, link.now);
		link.runUntil(() -> delivered == 1, 30);

		var grown:Int = link.clientData.congestionWindow;
		Assert.isTrue(grown > SctpDataTransfer.INITIAL_WINDOW,
			"the window never grew past where it started, at " + grown + " bytes, over a path that lost nothing");

		// One loss in the next transfer.
		var dropped:Bool = false;
		var seen:Int = 0;
		link.dropToServer = function(_):Bool {
			seen++;

			if (!dropped && seen == 6) {
				dropped = true;
				return true;
			}

			return false;
		};

		link.clientData.send(0, filled(64 * 1024), SctpDataChunk.PPID_BINARY, true, link.now);
		link.runUntil(() -> delivered == 2, 30);

		Assert.isTrue(dropped, "nothing was lost, so this proves nothing");
		Assert.equals(2, delivered);
		Assert.isTrue(link.clientData.congestionWindow < grown,
			"a loss left the window at " + link.clientData.congestionWindow + " from " + grown);
	}

	/**
		A SACK with thousands of gap blocks costs one pass, not one per block.

		`__onSack` walked every outstanding fragment once per gap block and
		then took each acknowledged one out of the middle of an array: 4,000
		blocks over 8,192 outstanding fragments measured 60 ms for a single
		SACK, and the peer chooses both numbers. One pass costs a few
		thousand steps, which is well under a millisecond compiled; one pass
		per block costs tens of millions. Best of three fresh pairs, so a
		collection landing in one measurement does not decide the result.
	**/
	public function testASackWithManyGapBlocksIsReadInOnePass():Void {
		if (unsupported()) return;

		var outstanding:Int = 8192;
		var blocks:Int = 4000;

		// The interpreter runs everything a hundred times slower, and one pass
		// per block would still be a thousand times past this there.
		var allowed:Float = #if interp 1.0 #else 0.01 #end;
		var best:Float = Math.POSITIVE_INFINITY;

		for (_ in 0...3) {
			var pair = outstandingPair(outstanding);
			Assert.equals(outstanding, pair.clientData.outstandingCount(), "the fragments to acknowledge never went out");

			var sack = gapSack(pair, blocks);
			var start:Float = haxe.Timer.stamp();
			pair.sackToClient(sack);
			var elapsed:Float = haxe.Timer.stamp() - start;

			if (elapsed < best) {
				best = elapsed;
			}

			Assert.equals(blocks, gapAcknowledged(pair.clientData), "the SACK did not acknowledge the fragments its blocks named");
		}

		Assert.isTrue(best < allowed,
			"a SACK with " + blocks + " gap blocks over " + outstanding + " fragments took " + Std.int(best * 1e6) + " us");
	}

	/** A pair with `count` one-byte messages outstanding from the client, none acknowledged. **/
	private function outstandingPair(count:Int):Pair {
		var pair = Pair.open();
		pair.client.onSend = _ -> {};

		// Shut, so the messages queue behind the first and go out bundled once
		// it opens, a packet per message would put thousands of checksums in
		// the setup of a test about something else.
		@:privateAccess pair.clientData.__cwnd = 0;

		for (_ in 0...count) {
			pair.clientData.send(0, filled(1), SctpDataChunk.PPID_BINARY, false, pair.now);
		}

		@:privateAccess pair.clientData.__cwnd = 0x3FFFFFFF;
		@:privateAccess pair.clientData.__peerWindow = 0x3FFFFFFF;

		while (pair.clientData.bufferedAmount > 0) {
			pair.clientData.poll(pair.now);
		}

		return pair;
	}

	/** A SACK acknowledging nothing cumulatively, and every second fragment in `blocks` islands of one. **/
	private function gapSack(pair:Pair, blocks:Int):SctpChunk {
		var first:Int = @:privateAccess pair.clientData.__unacknowledged[0].data.tsn;
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeInt((first - 1) | 0);
		value.writeInt(0x3FFFFFFF);
		value.writeShort(blocks);
		value.writeShort(0);

		for (g in 0...blocks) {
			value.writeShort(2 * g + 2);
			value.writeShort(2 * g + 2);
		}

		value.position = 0;
		return new SctpChunk(SctpPacket.CHUNK_SACK, 0, value);
	}

	private function gapAcknowledged(transfer:SctpDataTransfer):Int {
		var count:Int = 0;
		var all = @:privateAccess transfer.__unacknowledged;

		for (i in (@:privateAccess transfer.__outstandingAt)...all.length) {
			if (all[i].acked) {
				count++;
			}
		}

		return count;
	}


	public function testEverythingIsAcknowledgedInTheEnd():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		pair.serverData.onMessage = (_, _, _) -> {};

		pair.clientData.send(0, text("one"), SctpDataChunk.PPID_STRING, true, pair.now);
		pair.clientData.send(0, text("two"), SctpDataChunk.PPID_STRING, true, pair.now);

		pair.run(() -> pair.clientData.outstandingCount() == 0);

		Assert.equals(0, pair.clientData.outstandingCount(), "fragments were never acknowledged, so they would be retransmitted forever");
	}

	/**
		The receiver does not keep what it has already accepted.

		`__received` is there to spot duplicates and to describe the holes in a
		SACK. Both only ever look at TSNs *above* the cumulative, the gap walk
		starts at `__cumulativeTsn + 1`, and a chunk at or below it is refused on
		the isEarlier test whether or not the map still holds it. So an entry the
		cumulative has passed can never be read again, and nothing removed it:
		an association retained every chunk it had ever received, payload and
		all, for as long as it stayed open. An ordinarily busy data channel was
		enough; no misbehaving peer required.

		Counting the map is the effect here and not a proxy for it, the map is
		the memory that was being retained.
	**/
	public function testAcceptedChunksAreNotRetainedForever():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var delivered:Int = 0;
		pair.serverData.onMessage = (_, _, _) -> delivered++;

		var sent:Int = 40;
		for (i in 0...sent) {
			pair.clientData.send(0, text("message " + i), SctpDataChunk.PPID_STRING, true, pair.now);
			pair.run(() -> delivered > i);
		}

		// Without this the count below means nothing: a receiver that dropped
		// every message would also be holding no chunks.
		Assert.equals(sent, delivered, "not every message arrived");

		var retained:Int = 0;
		for (_ in @:privateAccess pair.serverData.__received.keys()) {
			retained++;
		}

		Assert.equals(0, retained,
			"the receiver kept " + retained + " of " + sent + " chunks it had already delivered");
	}

	/**
		An unfinished message cannot grow without bound.

		`__partial` holds the fragments of a message still being reassembled and
		is trimmed only when one completes. A peer that sends a fragment flagged
		B and then middle fragments forever, never one flagged E, therefore hands
		the receiver bytes it will hold for the life of the association. Every
		fragment is perfectly legal on its own, which is why this needs a bound
		rather than a validity check.

		Fed straight into the receiver rather than over the wire harness, because
		the sender will not produce a message that never ends.
	**/
	public function testAnUnfinishedMessageCannotGrowWithoutBound():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var server = pair.serverData;
		var first:Int = @:privateAccess server.__cumulativeTsn;

		var size:Int = 65536;
		var payload = new ByteArray();
		payload.length = size;

		// Twice the bound, in fragments that each look ordinary.
		var count:Int = 2 * Std.int(SctpDataTransfer.MAX_REASSEMBLY / size);
		for (i in 0...count) {
			var flags:Int = i == 0 ? SctpDataChunk.FLAG_BEGINNING : 0;
			var fragment = new SctpDataChunk((first + 1 + i) | 0, 0, 0, SctpDataChunk.PPID_BINARY, payload, flags);
			@:privateAccess server.__onData(fragment.toChunk());
		}

		var held:Int = 0;
		var partial = @:privateAccess server.__partial;
		for (key in partial.keys()) {
			for (fragment in partial.get(key).fragments) {
				held += fragment.payload.length;
			}
		}

		Assert.isTrue(held <= SctpDataTransfer.MAX_REASSEMBLY,
			"the receiver held " + held + " bytes of a message that never ended, against a bound of "
			+ SctpDataTransfer.MAX_REASSEMBLY);
	}

	/**
		Nor can it be split into pieces without bound.

		Bytes are not the only thing a peer chooses. A megabyte of budget is a
		megabyte of one-byte fragments, and each one costs a walk over what is
		already held to find out whether the run it joined is unbroken, so
		the cost of the next fragment grows with the count, and the count is
		the sender's to pick. Measured before this was bounded, with a version
		that also re-sorted on arrival: four thousand fragments, sixty-eight
		kilobytes on the wire, took sixteen seconds.

		A fragment here carries one byte, so the byte bound is nowhere near
		and the count is the only thing that can stop it.
	**/
	public function testAMessageCannotBeSplitWithoutBound():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var server = pair.serverData;
		var refused:String = null;
		server.onFailure = reason -> refused = reason;

		var first:Int = @:privateAccess server.__cumulativeTsn;
		var payload = new ByteArray();
		payload.writeByte(0);

		for (i in 0...(SctpDataTransfer.MAX_FRAGMENTS + 2)) {
			var flags:Int = i == 0 ? SctpDataChunk.FLAG_BEGINNING : 0;
			var fragment = new SctpDataChunk((first + 1 + i) | 0, 0, 0, SctpDataChunk.PPID_BINARY, payload, flags);
			@:privateAccess server.__onData(fragment.toChunk());
		}

		var held:Int = 0;
		var partial = @:privateAccess server.__partial;

		for (key in partial.keys()) {
			held += partial.get(key).fragments.length;
		}

		Assert.isTrue(held <= SctpDataTransfer.MAX_FRAGMENTS,
			"the receiver held " + held + " fragments of a message that never ended, against a bound of "
			+ SctpDataTransfer.MAX_FRAGMENTS);

		// Which bound stopped it, not merely that something did: the check
		// above reads zero once the partial message is dropped, so it would
		// hold just as well for fragments that never arrived at all. These
		// carry one byte each, so `MAX_REASSEMBLY` is nowhere near and a
		// reason naming bytes would mean this stopped measuring the count.
		Assert.notNull(refused, "the message was dropped without saying why");
		Assert.isTrue(refused != null && refused.indexOf("fragments") >= 0,
			"the message was dropped, but not for the number of pieces it was in: " + refused);
	}

	/**
		A message completed by a fragment landing in the middle of it.

		Completion is looked for around the fragment that just arrived rather
		than from the front of everything held, which is what keeps an arrival
		from costing a walk over the whole stream. The gap closed last here is
		an interior one, so finding the message means walking both ways from
		it, back to the piece flagged B and forward to the one flagged E,
		neither of them adjacent to what arrived.
	**/
	public function testAMessageCompletedFromTheMiddleIsDelivered():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var server = pair.serverData;
		var got:ByteArray = null;
		server.onMessage = (_, payload, _) -> got = payload;

		var first:Int = @:privateAccess server.__cumulativeTsn;
		var flags = [
			SctpDataChunk.FLAG_BEGINNING,
			0,
			0,
			0,
			SctpDataChunk.FLAG_ENDING
		];

		// Every piece but the middle one, outwards from the ends, so the last
		// to arrive has held fragments on both sides and touches neither end.
		for (i in [0, 4, 1, 3, 2]) {
			var payload = new ByteArray();
			payload.writeByte(0x40 + i);
			payload.position = 0;

			var fragment = new SctpDataChunk((first + 1 + i) | 0, 0, 0, SctpDataChunk.PPID_BINARY, payload, flags[i]);
			@:privateAccess server.__onData(fragment.toChunk());

			if (i != 2) {
				Assert.isNull(got, "a message went up while piece 2 of 5 was still missing");
			}
		}

		Assert.notNull(got, "the fragment that closed the last gap did not complete the message");

		if (got == null) {
			return;
		}

		Assert.equals(5, got.length);

		got.position = 0;
		var order = "";

		for (_ in 0...5) {
			order += String.fromCharCode(got.readUnsignedByte());
		}

		// Byte 0x40 + i for piece i: the payload reads as its own TSN order.
		Assert.equals("@ABCD", order, "the pieces were joined in the wrong order");
	}

	/**
		Five pieces, and every order they could possibly arrive in.

		Completion is looked for around the fragment that just arrived, which
		is only sound if nothing whole is ever left behind: a run that became
		complete and was not noticed would stay held, and the piece that would
		have found it has already been and gone. Reasoning says that cannot
		happen. A hundred and twenty orderings say so too, and they would
		still say so if the reasoning were wrong.
	**/
	public function testEveryArrivalOrderAssemblesTheSameMessage():Void {
		if (unsupported()) return;

		var flags = [
			SctpDataChunk.FLAG_BEGINNING,
			0,
			0,
			0,
			SctpDataChunk.FLAG_ENDING
		];

		var wrong:String = null;

		for (k in 0...120) {
			// k in the factorial number system is one of the 120 orderings.
			var pool = [0, 1, 2, 3, 4];
			var order:Array<Int> = [];
			var rest:Int = k;
			var divisor:Int = 24;

			while (pool.length > 0) {
				order.push(pool.splice(Std.int(rest / divisor), 1)[0]);
				rest = rest % divisor;
				divisor = pool.length > 0 ? Std.int(divisor / pool.length) : 1;
			}

			var transfer = new SctpDataTransfer(new SctpAssociation());
			var first:Int = @:privateAccess transfer.__cumulativeTsn;
			var delivered:Int = 0;
			var got:ByteArray = null;

			transfer.onMessage = function(_, payload, _):Void {
				delivered++;
				got = payload;
			};

			for (i in order) {
				var payload = new ByteArray();
				payload.writeByte(0x40 + i);
				payload.position = 0;

				@:privateAccess transfer.__reassemble(new SctpDataChunk((first + 1 + i) | 0, 0, 0,
					SctpDataChunk.PPID_BINARY, payload, flags[i]));
			}

			var text:String = null;

			if (got != null) {
				got.position = 0;
				text = "";

				for (_ in 0...got.length) {
					text += String.fromCharCode(got.readUnsignedByte());
				}
			}

			if (delivered != 1 || text != "@ABCD") {
				wrong = "arriving as " + order.join(",") + " the message went up " + delivered + " times as " + text;
				break;
			}
		}

		Assert.isNull(wrong, wrong);
	}

	/**
		The window offered in a SACK is the window that is actually left.

		It used to be the constant `RECEIVE_WINDOW`, written into every SACK
		however much had piled up behind it, so the peer was told the whole
		window was free right up to the point where none of it was. Flow
		control that reports a fixed number is not flow control.
	**/
	public function testTheWindowOfferedIsWhatIsActuallyLeft():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var tsn:Int = (@:privateAccess transfer.__cumulativeTsn) + 1;

		Assert.equals(SctpAssociation.RECEIVE_WINDOW, advertised(transfer),
			"a receiver holding nothing should offer the whole window");

		// Begun and not ended, so it stays held rather than going up.
		var size:Int = 4096;

		@:privateAccess transfer.__onData(new SctpDataChunk(tsn, 1, 0, SctpDataChunk.PPID_BINARY, filled(size),
			SctpDataChunk.FLAG_BEGINNING).toChunk());

		Assert.equals(SctpAssociation.RECEIVE_WINDOW - size, advertised(transfer),
			"the window should have shrunk by what is being held");

		// Ending it hands the message up, which gives the bytes back.
		@:privateAccess transfer.__onData(new SctpDataChunk((tsn + 1) | 0, 1, 0, SctpDataChunk.PPID_BINARY, filled(size),
			SctpDataChunk.FLAG_ENDING).toChunk());

		Assert.equals(SctpAssociation.RECEIVE_WINDOW, advertised(transfer),
			"the window should be whole again once the message went up");
	}

	/**
		The largest message this end accepts fits the window it offers.

		Three constants have to agree or a peer is trapped by obeying us: it
		reads the window, sends a message of the largest size we accept,
		watches the figure reach zero partway through, and stops, holding
		something that can now never complete. A stream may also have a full
		queue waiting its turn, so both have to fit at once.
	**/
	public function testTheLargestMessageFitsTheWindowOffered():Void {
		if (unsupported()) return;

		Assert.isTrue(SctpDataTransfer.MAX_REASSEMBLY + SctpDataTransfer.MAX_HELD <= SctpAssociation.RECEIVE_WINDOW,
			"a message of " + SctpDataTransfer.MAX_REASSEMBLY + " bytes and a queue of " + SctpDataTransfer.MAX_HELD
			+ " do not both fit in the " + SctpAssociation.RECEIVE_WINDOW + " this end offers");

		// And in practice, not only in arithmetic.
		var transfer = new SctpDataTransfer(new SctpAssociation());
		var tsn:Int = (@:privateAccess transfer.__cumulativeTsn) + 1;
		var got:Int = -1;
		transfer.onMessage = (_, payload, _) -> got = payload.length;

		var piece:Int = SctpDataTransfer.MAX_PAYLOAD;
		var pieces:Int = Std.int(SctpDataTransfer.MAX_REASSEMBLY / piece);

		for (i in 0...pieces) {
			var flags:Int = i == 0 ? SctpDataChunk.FLAG_BEGINNING : (i == pieces - 1 ? SctpDataChunk.FLAG_ENDING : 0);
			@:privateAccess transfer.__onData(new SctpDataChunk(tsn, 1, 0, SctpDataChunk.PPID_BINARY, filled(piece),
				flags).toChunk());
			tsn = (tsn + 1) | 0;
		}

		Assert.equals(SctpDataTransfer.MAX_REASSEMBLY, got,
			"a message of exactly the size this end accepts did not arrive whole");
		Assert.equals(0, @:privateAccess transfer.__buffered, "the receiver is still holding the message it delivered");
	}

	/**
		What a peer can make this end hold, added up over every stream.

		The per-stream bounds are per stream, and we offer all 65535 of them
		because browsers ask for the range. So they bounded nothing in
		aggregate: a megabyte of reassembly and a megabyte held, on each of
		65536 streams, is a ceiling of 128 GB reached by a peer doing nothing
		but sending. The association now gives some back rather than taking
		more than it offered to hold, which is what the per-stream bounds
		already do one stream at a time.

		Refusing the chunk instead would have been the deadlock: what is held
		is unfinished, so the chunks turned away include the ones that would
		finish a message and free it.
	**/
	public function testWhatIsHeldIsBoundedAcrossEveryStream():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var tsn:Int = (@:privateAccess transfer.__cumulativeTsn) + 1;
		var size:Int = 4096;
		var sent:Int = 0;
		var peak:Int = 0;

		// Well past the window: begun and never ended, a different stream
		// each time so no per-stream bound is ever the thing that stops it.
		for (i in 0...(4 * Std.int(SctpAssociation.RECEIVE_WINDOW / size))) {
			@:privateAccess transfer.__onData(new SctpDataChunk(tsn, i & 0xFFFF, 0, SctpDataChunk.PPID_BINARY,
				filled(size), SctpDataChunk.FLAG_BEGINNING).toChunk());
			tsn = (tsn + 1) | 0;
			sent += size;

			var now:Int = @:privateAccess transfer.__buffered;

			if (now > peak) {
				peak = now;
			}
		}

		Assert.isTrue(sent >= 4 * SctpAssociation.RECEIVE_WINDOW, "the peer did not send enough to test the bound");
		Assert.isTrue(peak <= SctpAssociation.RECEIVE_WINDOW,
			"the receiver held " + peak + " bytes at once, against the " + SctpAssociation.RECEIVE_WINDOW
			+ " it offered, out of " + sent + " sent");

		// And the figure the window is derived from is the truth, not a
		// count that drifted away from what is really there.
		Assert.equals(walked(transfer), @:privateAccess transfer.__buffered);
	}

	/**
		The sender stops at the window the peer said it had.

		`peerReceiveWindow` was read off the INIT and never consulted, and the
		a_rwnd field of an arriving SACK was read past and dropped, so this end
		put everything it was handed straight on the wire at whatever rate it
		was handed it. The receiver's bound then had to absorb the difference.
	**/
	public function testTheSenderStopsAtTheWindowThePeerAdvertised():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var transfer = pair.clientData;
		var chunks:Int = 0;
		pair.client.onSend = _ -> chunks++;

		// Room for four fragments, and no more.
		var room:Int = 4 * SctpDataTransfer.MAX_PAYLOAD;
		pair.sackToClient(sack(@:privateAccess transfer.__nextTsn - 1, room));
		chunks = 0;

		var message:Int = 64 * SctpDataTransfer.MAX_PAYLOAD;
		transfer.send(0, filled(message), SctpDataChunk.PPID_BINARY, true, 1.0);

		Assert.equals(4, chunks, "the sender put " + chunks + " fragments on a wire with room for four");
		Assert.equals(message - room, transfer.bufferedAmount);

		// What the window is compared against has to be what is really out
		// there, and it is carried rather than summed, so it can drift.
		Assert.equals(inFlight(transfer), @:privateAccess transfer.__inFlight);
	}

	/**
		A window with no room in it still gets one fragment, and recovers.

		This is the part that cannot be left out. A closed window reopens, and
		the only way this end hears about it is a SACK, and a SACK only comes
		back for something sent, so a sender that waited for room while
		sending nothing would be waiting for a message that its own silence
		prevents. RFC 4960 allows the one probe for exactly that reason.

		The second half is the one worth watching: the acknowledgement of the
		probe carries the reopened window, and what was queued behind it moves
		at once, a few packets at a time rather than the whole queue in one
		burst, since the path it is about to cross has not been heard from
		for as long as the window was shut.
	**/
	public function testAClosedWindowGetsAProbeAndThenRecovers():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var transfer = pair.clientData;
		var chunks:Int = 0;
		var watching:ByteArray->Void = _ -> chunks++;
		pair.watchClient(watching);

		var first:Int = @:privateAccess transfer.__nextTsn;
		pair.sackToClient(sack((first - 1) | 0, 0));
		chunks = 0;

		var pieces:Int = 8;
		transfer.send(0, filled(pieces * SctpDataTransfer.MAX_PAYLOAD), SctpDataChunk.PPID_BINARY, true, 1.0);

		Assert.equals(1, chunks, "a closed window sent " + chunks + " fragments; one is the probe and more is ignoring it");
		Assert.equals((pieces - 1) * SctpDataTransfer.MAX_PAYLOAD, transfer.bufferedAmount);

		// The peer takes the probe and says it has room again.
		pair.sackToClient(sack(first, 1024 * 1024));

		Assert.isTrue(chunks > 1, "the queue did not move when the window reopened");
		Assert.isTrue(chunks <= 1 + SctpDataTransfer.MAX_BURST,
			"the reopened window was spent in one burst of " + (chunks - 1) + " packets");

		// And everything goes, as the acknowledgements come back.
		pair.run(() -> transfer.bufferedAmount == 0 && transfer.outstandingCount() == 0);
		Assert.equals(0, transfer.bufferedAmount, "something stayed queued against a window with room for it");
	}

	/**
		Waiting for the window is not an excuse to keep everything.

		Flow control means a message handed over is not a message sent, and
		what is not sent is held. That queue is the application's own doing,
		so it is told rather than quietly grown: `bufferedAmount` says how far
		behind it is, and past `MAX_BUFFERED` handing over more throws instead
		of taking the process down with it.
	**/
	public function testTheSendQueueDoesNotGrowWithoutBound():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var transfer = pair.clientData;
		pair.client.onSend = _ -> {};

		@:privateAccess transfer.__onSack(sack(@:privateAccess transfer.__nextTsn - 1, 0));

		var refused:Bool = false;
		var each:Int = 512 * 1024;

		try {
			// Twice the bound, in messages that each look ordinary.
			for (_ in 0...(2 * Std.int(SctpDataTransfer.MAX_BUFFERED / each))) {
				transfer.send(0, filled(each), SctpDataChunk.PPID_BINARY, true, 1.0);
			}
		} catch (e:Dynamic) {
			refused = true;
		}

		Assert.isTrue(refused, "the queue grew past " + SctpDataTransfer.MAX_BUFFERED + " without a word");
		Assert.isTrue(transfer.bufferedAmount <= SctpDataTransfer.MAX_BUFFERED,
			"the queue reached " + transfer.bufferedAmount + " against a bound of " + SctpDataTransfer.MAX_BUFFERED);
	}

	/**
		Releasing a stream that waited does not cost what it waited for.

		Messages that arrive early are held until the one before them does,
		and a peer chooses how many that is by withholding one sequence and
		sending the rest. They used to be a list searched from the front for
		whichever came next and then taken out of the middle, so releasing
		the stream cost a pass over everything queued for each message
		released. Measured before this changed: 4000 held took 30ms on eval
		to release, doubling per message as the count grew, and `MAX_HELD` at
		one byte a message allows a million of them.

		Asked for by sequence now, which is also what stops the count from
		running away, the field is sixteen bits, so a map keyed by it holds
		65536 at the outside whatever the peer does.
	**/
	public function testEverythingHeldGoesUpInOrderWhenTheBlockerArrives():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var order:Array<Int> = [];
		transfer.onMessage = function(_, payload, _):Void {
			payload.position = 0;
			order.push(payload.readUnsignedShort());
		};

		var count:Int = 200;

		// Every sequence but the first, and not in sequence order either.
		for (i in 0...count) {
			var sequence:Int = count - i;
			@:privateAccess transfer.__deliverOrHold(1, sequence, SctpDataChunk.PPID_BINARY, numbered(sequence), false);
		}

		Assert.equals(0, order.length, "something went up while sequence 0 was still missing");
		Assert.equals(count, @:privateAccess transfer.__held.get(1).count);

		// A sequence already waiting is the peer sending one twice, and the
		// second must not be counted as another message held.
		@:privateAccess transfer.__deliverOrHold(1, 5, SctpDataChunk.PPID_BINARY, numbered(5), false);
		Assert.equals(count, @:privateAccess transfer.__held.get(1).count, "a repeated sequence was held a second time");

		// The one they were all waiting for.
		@:privateAccess transfer.__deliverOrHold(1, 0, SctpDataChunk.PPID_BINARY, numbered(0), false);

		Assert.equals(count + 1, order.length, "the stream did not empty when the blocker arrived");

		var ordered:Bool = true;

		for (i in 0...order.length) {
			if (order[i] != i) {
				ordered = false;
				break;
			}
		}

		Assert.isTrue(ordered, "they went up as " + order.slice(0, 12).join(",") + "... rather than in sequence");
		Assert.equals(0, @:privateAccess transfer.__buffered, "the stream emptied and is still counted as holding");
	}

	/**
		A stream cannot hold without bound for a sequence that never comes.

		An ordered message arriving early is held until its turn rather than
		dropped, which is right, the one before it is usually still in flight.
		But nothing bounded the queue, so a peer that sends sequence 1 and never
		sequence 0 leaves everything behind it held for the life of the
		association. These are whole reassembled messages, not fragments, so it
		is the more expensive of the two hold queues in this class.
	**/
	public function testAStreamWaitingOnASequenceThatNeverComesIsBounded():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var server = pair.serverData;

		var size:Int = 65536;
		var payload = new ByteArray();
		payload.length = size;

		// The stream expects sequence 0, so every one of these is early.
		var allowed:Int = Std.int(SctpDataTransfer.MAX_HELD / size);
		for (i in 0...2 * allowed) {
			@:privateAccess server.__deliverOrHold(0, i + 1, SctpDataChunk.PPID_BINARY, payload, false);
		}

		var bytes:Int = 0;
		var queues = @:privateAccess server.__held;
		for (key in queues.keys()) {
			bytes += queues.get(key).bytes;
		}

		Assert.isTrue(bytes <= SctpDataTransfer.MAX_HELD,
			"the stream held " + bytes + " bytes waiting for a sequence that never arrived, against a bound of "
			+ SctpDataTransfer.MAX_HELD);
	}

	/**
		Sequence numbers wrap, and comparison has to survive it.

		A subtraction works for hours and then reorders every message the moment
		the counter rolls over, which is the sort of fault that reaches
		production because nothing short of a long run finds it.
	**/
	public function testSequenceComparisonSurvivesWrapping():Void {
		Assert.isTrue(SctpDataChunk.isEarlier(1, 2));
		Assert.isFalse(SctpDataChunk.isEarlier(2, 1));
		Assert.isFalse(SctpDataChunk.isEarlier(5, 5));

		// Across the top of the range: the largest value comes before zero.
		Assert.isTrue(SctpDataChunk.isEarlier(0xFFFFFFFF, 0), "the comparison broke at the wrap");
		Assert.isTrue(SctpDataChunk.isEarlier(0xFFFFFFF0, 5));
		Assert.isFalse(SctpDataChunk.isEarlier(0, 0xFFFFFFFF));

		// And across the *signed* boundary, which is the pair a plain `a < b`
		// gets wrong. The three above do not catch it: 0xFFFFFFFF is -1 as a
		// thirty-two bit Int, so comparing it against 0 happens to give the
		// right answer for the wrong reason. These two are adjacent, one step
		// apart in the sequence, and sit at opposite ends of the signed range.
		Assert.isTrue(SctpDataChunk.isEarlier(0x7FFFFFFF, 0x80000000),
			"two adjacent values either side of the signed boundary compared as though the sequence ran in a straight line");
		Assert.isFalse(SctpDataChunk.isEarlier(0x80000000, 0x7FFFFFFF));
	}

	private static function text(value:String):ByteArray {
		var out = new ByteArray();
		out.writeUTFBytes(value);
		out.position = 0;
		return out;
	}
}

/** Two associations with data transfer on top, and a wire that can misbehave. **/
private class Pair {
	public var client:SctpAssociation;
	public var server:SctpAssociation;
	public var clientData:SctpDataTransfer;
	public var serverData:SctpDataTransfer;
	public var now:Float = 0;

	/** Swallow this many of the next packets bound for the server. **/
	public var dropNextToServer:Int = 0;

	/** Deliver the next two packets bound for the server back to front. **/
	public var reorderNextToServer:Bool = false;

	/** Drop everything bound for the server, for as long as this is set. **/
	public var cutToServer:Bool = false;

	private var toServer:Array<ByteArray> = [];
	private var toClient:Array<ByteArray> = [];

	public static function open():Pair {
		var pair = new Pair();
		pair.client = new SctpAssociation();
		pair.server = new SctpAssociation();

		pair.client.onSend = payload -> pair.toServer.push(payload);
		pair.server.onSend = payload -> pair.toClient.push(payload);

		pair.server.listen();
		pair.client.associate(0);

		// Run the handshake to completion before the data layer attaches, since
		// it needs the TSNs the handshake exchanged.
		for (_ in 0...50) {
			pair.deliver();

			if (pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED) {
				break;
			}
		}

		pair.clientData = new SctpDataTransfer(pair.client);
		pair.serverData = new SctpDataTransfer(pair.server);
		return pair;
	}

	private function new() {}

	/** One hop, and a quarter of a second. **/
	public function step():Void {
		deliver();
	}

	/**
		Hands the client a SACK as though the server had sent it, the way a
		real one arrives: in a packet, read to the end, so whatever it makes
		room for is sent before this returns.
	**/
	public function sackToClient(chunk:SctpChunk):Void {
		client.receive(server.packetFor([chunk]), now);
	}

	/** Sees every packet the client sends, which still goes on to the server. **/
	public function watchClient(watch:ByteArray->Void):Void {
		client.onSend = function(payload:ByteArray):Void {
			watch(payload);
			toServer.push(payload);
		};
	}

	private function deliver():Void {
		var outbound = toServer;
		var inbound = toClient;
		toServer = [];
		toClient = [];

		if (cutToServer) {
			outbound = [];
		}

		if (dropNextToServer > 0 && outbound.length > 0) {
			var drop:Int = dropNextToServer < outbound.length ? dropNextToServer : outbound.length;
			outbound = outbound.slice(drop);
			dropNextToServer -= drop;
		}

		if (reorderNextToServer && outbound.length >= 2) {
			reorderNextToServer = false;
			var swapped = outbound.copy();
			var first = swapped[0];
			swapped[0] = swapped[1];
			swapped[1] = first;
			outbound = swapped;
		}

		for (payload in outbound) {
			server.receive(payload, now);
		}

		for (payload in inbound) {
			client.receive(payload, now);
		}

		now += 0.25;
	}

	public function run(done:Void->Bool):Bool {
		for (_ in 0...200) {
			if (clientData != null) {
				clientData.poll(now);
			}

			if (serverData != null) {
				serverData.poll(now);
			}

			deliver();

			if (done()) {
				return true;
			}
		}

		return done();
	}
}

/**
	Two established associations and a path between them that behaves like
	one: it takes time to cross, it has a bottleneck that drains at a fixed
	rate and queues only so much, and it can be told to lose a particular
	packet or everything.

	Congestion control is a response to a path, and a wire that delivers
	everything instantly gives it nothing to respond to. The clock advances in
	small steps, polling both ends each step the way a runtime tick would.
**/
private class Link {
	public var client:SctpAssociation;
	public var server:SctpAssociation;
	public var clientData:SctpDataTransfer;
	public var serverData:SctpDataTransfer;
	public var now:Float = 0;

	/** One way, in seconds. **/
	public var delay:Float = 0.02;

	/** How finely the clock moves. **/
	public var step:Float = 0.002;

	/** Packets a second the bottleneck toward the server drains, or 0 for no bottleneck. **/
	public var rate:Float = 0;

	/** Packets the bottleneck holds waiting; one arriving while it is full is lost. **/
	public var queueLimit:Int = 1000000;

	/** Lose everything toward the server. **/
	public var cut:Bool = false;

	/** Decides whether to lose a packet toward the server, after `sentToServer` counts it. **/
	public var dropToServer:ByteArray->Bool = null;

	/** Sees every packet the client sends, lost or not. **/
	public var watchToServer:ByteArray->Void = null;

	public var sentToServer:Int = 0;
	public var dropped:Int = 0;

	private var toServer:Array<InTransit> = [];
	private var toClient:Array<InTransit> = [];

	/** When the bottleneck finishes with the last packet it accepted. **/
	private var busyUntil:Float = 0;

	public static function open():Link {
		var link = new Link();
		link.client = new SctpAssociation();
		link.server = new SctpAssociation();

		// The handshake crosses instantly; the path only matters for data.
		var handshake:Array<ByteArray> = [];
		var answers:Array<ByteArray> = [];
		link.client.onSend = payload -> handshake.push(payload);
		link.server.onSend = payload -> answers.push(payload);

		link.server.listen();
		link.client.associate(0);

		for (_ in 0...20) {
			var outbound = handshake;
			var inbound = answers;
			handshake = [];
			answers = [];

			for (payload in outbound) {
				link.server.receive(payload, 0);
			}

			for (payload in inbound) {
				link.client.receive(payload, 0);
			}
		}

		link.client.onSend = payload -> link.__sendToServer(payload);
		link.server.onSend = payload -> link.toClient.push(new InTransit(link.now + link.delay, payload));

		link.clientData = new SctpDataTransfer(link.client);
		link.serverData = new SctpDataTransfer(link.server);
		return link;
	}

	private function new() {}

	private function __sendToServer(payload:ByteArray):Void {
		sentToServer++;

		if (watchToServer != null) {
			watchToServer(payload);
		}

		if (cut || (dropToServer != null && dropToServer(payload))) {
			dropped++;
			return;
		}

		var arrives:Float = now + delay;

		if (rate > 0) {
			var start:Float = busyUntil > now ? busyUntil : now;
			var waiting:Float = (start - now) * rate;

			if (waiting >= queueLimit) {
				dropped++;
				return;
			}

			busyUntil = start + 1 / rate;
			arrives = busyUntil + delay;
		}

		toServer.push(new InTransit(arrives, payload));
	}

	/** Moves the clock one step: delivers what has arrived, then polls both ends. **/
	public function tick():Void {
		now += step;

		var due = toServer;
		toServer = [];

		for (packet in due) {
			if (packet.arrives <= now) {
				server.receive(packet.payload, now);
			} else {
				toServer.push(packet);
			}
		}

		due = toClient;
		toClient = [];

		for (packet in due) {
			if (packet.arrives <= now) {
				client.receive(packet.payload, now);
			} else {
				toClient.push(packet);
			}
		}

		clientData.poll(now);
		serverData.poll(now);
	}

	public function runUntil(done:Void->Bool, seconds:Float):Bool {
		var until:Float = now + seconds;

		while (now < until) {
			if (done()) {
				return true;
			}

			tick();
		}

		return done();
	}
}

private class InTransit {
	public var arrives:Float;
	public var payload:ByteArray;

	public function new(arrives:Float, payload:ByteArray) {
		this.arrives = arrives;
		this.payload = payload;
	}
}
