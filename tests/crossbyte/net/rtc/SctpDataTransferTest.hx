package crossbyte.net.rtc;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.SctpAssociation;
import crossbyte.net.rtc._internal.sctp.SctpAssociationState;
import crossbyte.net.rtc._internal.sctp.SctpDataChunk;
import crossbyte.net.rtc._internal.sctp.SctpDataTransfer;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;
import crossbyte.net.rtc._internal.sctp.SctpParameter;
import utest.Assert;

/**
	Messages over an open association, with a wire that can be told to misbehave.

	The guarantees this layer makes (reliable, and ordered per stream) are
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

	/** Every piece the receiver is holding (fragments and waiting messages), walked rather than trusted. **/
	private function walkedPieces(transfer:SctpDataTransfer):Int {
		var total:Int = 0;

		for (key in (@:privateAccess transfer.__partial).keys()) {
			total += (@:privateAccess transfer.__partial).get(key).fragments.length;
		}

		for (streamId in (@:privateAccess transfer.__held).keys()) {
			for (_ in (@:privateAccess transfer.__held).get(streamId).bySequence) {
				total++;
			}
		}

		return total;
	}

	/**
		The least of three runs of `run`, in seconds: what it costs, with a
		collection landing in one run not deciding the figure.
	**/
	private static function cheapest(run:Void->Void):Float {
		var best:Float = Math.POSITIVE_INFINITY;

		for (_ in 0...3) {
			var start:Float = haxe.Timer.stamp();
			run();
			var elapsed:Float = haxe.Timer.stamp() - start;

			if (elapsed < best) {
				best = elapsed;
			}
		}

		return best;
	}

	/**
		Whether `costs`, the time one packet took at each size of an attack,
		stays flat: the largest size's within twice the smallest's, with
		`slack` seconds besides for a target fast enough that a collection is
		most of a run. The sizes run over a factor of eight, and work that
		grows with the attack grows eight times over them.
	**/
	private static function flat(costs:Array<Float>, slack:Float):Bool {
		return costs[costs.length - 1] <= costs[0] * 2 + slack;
	}

	private static function microseconds(costs:Array<Float>):String {
		return [for (cost in costs) Std.string(Math.round(cost * 1e7) / 10)].join(" / ") + " us";
	}

	/** What is really in the network: sent, and neither acknowledged nor found lost. **/
	private function inFlight(transfer:SctpDataTransfer):Int {
		var total:Int = 0;
		var all = @:privateAccess transfer.__unacknowledged;

		for (i in (@:privateAccess transfer.__outstandingAt)...all.length) {
			var sent = all[i];

			if (!sent.acked && !sent.lost && !sent.abandoned) {
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

	/**
		With a runtime, what a pass sends goes when the pass ends, together:
		ten small messages in one packet, rather than each a packet (and a
		DTLS record and a `sendto`) of its own. Without one, as everywhere
		else here, each goes as it is sent.
	**/
	public function testAPassesMessagesShareAPacket():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var packets:Int = 0;
		pair.watchClient(_ -> packets++);
		var got:Array<Int> = [];
		pair.serverData.onMessage = (_, payload, _) -> {
			payload.position = 0;
			got.push(payload.readShort());
		};

		pair.clientData.runtime = CrossByte.current();
		for (i in 0...10) {
			pair.clientData.send(0, numbered(i), SctpDataChunk.PPID_BINARY, true, pair.now);
		}
		Assert.equals(0, packets, "a message went before the pass ended");
		CrossByte.current().pump(0, 0);
		Assert.equals(1, packets, "ten messages sent in one pass took " + packets + " packets");
		pair.run(() -> got.length == 10);
		Assert.equals("0,1,2,3,4,5,6,7,8,9", got.join(","));

		pair.clientData.runtime = null;
		packets = 0;
		pair.clientData.send(0, numbered(10), SctpDataChunk.PPID_BINARY, true, pair.now);
		Assert.equals(1, packets, "without a runtime a message waited");
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
		one over as it lands. Unordered is not unreliable (both still arrive);
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

		After the last retransmission a fragment cannot simply be dropped with
		the rest carrying on: on an ordered stream that is a hole nothing will
		ever fill, everything behind it stalled for good, later fragments
		resent up to eleven times, and the association reporting itself open
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
		A peer cannot make the receiver track numbers without bound.

		A TSN far past the cumulative acknowledgement is not taken: a peer
		that never sent the next number and sent the ones after it could grow
		the receiver's record of what had arrived for as long as it cared to
		(400,000 entries and 24 MB, on unordered one-byte messages that were
		delivered at once and so never touched the window). Anything more than
		`MAX_TSN_AHEAD` past it is dropped unread.
	**/
	public function testAPeerCannotMakeTheReceiverTrackNumbersWithoutBound():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var delivered:Int = 0;
		transfer.onMessage = (_, _, _) -> delivered++;

		var one = filled(1);
		var tsn:Int = ((@:privateAccess transfer.__cumulativeTsn) + 2) | 0;
		var sent:Int = 50000;

		// The next number never comes; everything after it does.
		for (_ in 0...sent) {
			@:privateAccess transfer.__onData(new SctpDataChunk(tsn, 1, 0, SctpDataChunk.PPID_BINARY, one,
				SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING | SctpDataChunk.FLAG_UNORDERED).toChunk());
			tsn = (tsn + 1) | 0;
		}

		var held:Int = 0;

		for (_ in (@:privateAccess transfer.__received).keys()) {
			held++;
		}

		Assert.isTrue(delivered > 0, "nothing was delivered, so nothing was taken to be held either");
		Assert.isTrue(held <= SctpDataTransfer.MAX_TSN_AHEAD,
			"the receiver holds " + held + " numbers past a hole the peer never filled, against a bound of " + SctpDataTransfer.MAX_TSN_AHEAD);
	}

	/**
		With its window shut, the receiver takes nothing past what has arrived,
		and still takes what fills a hole.

		RFC 4960 section 6.2. The window is published, and a peer is held to
		it rather than the receiver throwing away unfinished messages to make
		room: what lies beyond the highest number already received is dropped,
		with a SACK saying the window is still shut, while a number below it
		(the one a message is waiting on) is taken, since that is what
		completes a message and opens the window again.
	**/
	public function testAShutWindowTakesNothingPastWhatHasArrived():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var delivered:Int = 0;
		transfer.onMessage = (_, _, _) -> delivered++;

		var base:Int = @:privateAccess transfer.__cumulativeTsn;
		var piece:Int = SctpDataTransfer.MAX_PAYLOAD;
		var tsn:Int = (base + 2) | 0;

		// A hole at base + 1, and two unfinished megabytes past it: the window
		// is exactly full.
		for (stream in 1...3) {
			for (i in 0...Std.int(SctpDataTransfer.MAX_REASSEMBLY / piece)) {
				@:privateAccess transfer.__onData(new SctpDataChunk(tsn, stream, 0, SctpDataChunk.PPID_BINARY, filled(piece),
					i == 0 ? SctpDataChunk.FLAG_BEGINNING : 0).toChunk());
				tsn = (tsn + 1) | 0;
			}
		}

		Assert.equals(SctpAssociation.RECEIVE_WINDOW, @:privateAccess transfer.__buffered, "the window was not filled, so this proves nothing");
		Assert.equals(0, advertised(transfer));

		var failures:Int = 0;
		transfer.onFailure = _ -> failures++;

		// Past everything that has arrived: refused.
		@:privateAccess transfer.__onData(new SctpDataChunk(tsn, 3, 0, SctpDataChunk.PPID_BINARY, filled(1),
			SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING | SctpDataChunk.FLAG_UNORDERED).toChunk());

		Assert.equals(0, delivered, "a message past a shut window was taken");
		Assert.equals(0, failures, "a message past a shut window made room by giving up what was held");
		Assert.equals(SctpAssociation.RECEIVE_WINDOW, @:privateAccess transfer.__buffered);

		// The hole below it: taken.
		@:privateAccess transfer.__onData(new SctpDataChunk((base + 1) | 0, 4, 0, SctpDataChunk.PPID_BINARY, filled(1),
			SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING | SctpDataChunk.FLAG_UNORDERED).toChunk());

		Assert.equals(1, delivered, "the number the receiver was waiting on was refused along with the rest");
		Assert.equals(((tsn - 1) | 0), @:privateAccess transfer.__cumulativeTsn, "filling the hole did not carry the acknowledgement past it");
	}

	/**
		The gap blocks describe exactly what arrived past a hole, and follow it
		as the holes fill.
	**/
	public function testGapBlocksDescribeWhatArrivedPastTheHole():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var base:Int = @:privateAccess transfer.__cumulativeTsn;

		function arrive(offset:Int):Void {
			@:privateAccess transfer.__onData(new SctpDataChunk((base + offset) | 0, 1, 0, SctpDataChunk.PPID_BINARY, filled(1),
				SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING | SctpDataChunk.FLAG_UNORDERED).toChunk());
		}

		function blocks():String {
			var sack = @:privateAccess transfer.__buildSack();
			var value = sack.value;
			value.endian = Endian.BIG_ENDIAN;
			value.position = 0;
			var cumulative:Int = (value.readInt() - base) | 0;
			value.readInt();
			var count:Int = value.readUnsignedShort();
			value.readUnsignedShort();
			var out:Array<String> = [];

			for (_ in 0...count) {
				out.push(value.readUnsignedShort() + "-" + value.readUnsignedShort());
			}

			return cumulative + ":" + out.join(",");
		}

		// Offsets from the base; 1 is the hole.
		for (offset in [3, 2, 5, 9, 7, 8]) {
			arrive(offset);
		}

		Assert.equals("0:2-3,5-5,7-9", blocks());

		arrive(4);
		Assert.equals("0:2-5,7-9", blocks(), "a number between two runs did not join them");

		arrive(1);
		Assert.equals("5:2-4", blocks(), "filling the hole did not carry the acknowledgement over the run behind it");

		arrive(6);
		Assert.equals("9:", blocks());

		// Far more islands than a SACK can carry: the lowest go.
		for (i in 0...(SctpDataTransfer.MAX_SACK_BLOCKS * 2)) {
			arrive(11 + 2 * i);
		}

		var sack = @:privateAccess transfer.__buildSack();
		sack.value.position = 8;
		Assert.equals(SctpDataTransfer.MAX_SACK_BLOCKS, sack.value.readUnsignedShort(), "a SACK reported more gap blocks than it may");
		sack.value.position = 12;
		Assert.equals(2, sack.value.readUnsignedShort(), "the first gap block reported is not the lowest");
	}

	/**
		A message that may be sent once and is lost stays lost, and the rest
		flow past it.

		Partial reliability, RFC 3758: what a game's state channel is. The one
		lost is not sent again; a FORWARD TSN moves the peer past it, so its
		acknowledgement does not stop at the hole and nothing piles up behind
		it.
	**/
	public function testAMessageThatMaySendOnceIsNotSentAgain():Void {
		if (unsupported()) return;

		var link = Link.open();
		var dropped:Bool = false;
		link.dropToServer = function(_):Bool {
			if (!dropped && link.sentToServer == 2) {
				dropped = true;
				return true;
			}

			return false;
		};

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

		var delivered:Array<Int> = [];
		link.serverData.onMessage = function(_, payload:ByteArray, _):Void {
			payload.position = 0;
			delivered.push(payload.readUnsignedByte());
		};

		for (i in 0...12) {
			link.clientData.send(0, numberedByte(i), SctpDataChunk.PPID_BINARY, false, link.now, 0);
		}

		link.runUntil(() -> link.clientData.outstandingCount() == 0 && delivered.length >= 11, 20);

		Assert.isTrue(dropped, "nothing was lost, so this proves nothing");
		Assert.equals(11, delivered.length, "delivered " + delivered.join(",") + ": the lost message was sent again or others never came");
		Assert.equals(-1, delivered.indexOf(1), "the message that was lost arrived after all, so it was retransmitted");

		var resent:Int = 0;

		for (tsn in transmissions.keys()) {
			if (transmissions.get(tsn) > 1) {
				resent++;
			}
		}

		Assert.equals(0, resent, "a message that may be sent once was sent again");
		Assert.equals(0, link.clientData.outstandingCount(), "the peer never moved past the message given up on");
		Assert.equals(@:privateAccess link.clientData.__nextTsn - 1, @:privateAccess link.serverData.__cumulativeTsn,
			"the receiver's acknowledgement stopped at the hole");
	}

	/**
		An ordered stream skips a message given up on, and delivers what waited
		behind it in order.

		The FORWARD TSN names the stream and the sequence abandoned on it; the
		receiver hands up what it was holding, which had arrived whole and was
		waiting only on that one.
	**/
	public function testAnOrderedStreamSkipsWhatWasGivenUp():Void {
		if (unsupported()) return;

		var link = Link.open();
		var dropped:Bool = false;
		link.dropToServer = function(_):Bool {
			if (!dropped && link.sentToServer == 3) {
				dropped = true;
				return true;
			}

			return false;
		};

		var delivered:Array<Int> = [];
		link.serverData.onMessage = function(_, payload:ByteArray, _):Void {
			payload.position = 0;
			delivered.push(payload.readUnsignedByte());
		};

		for (i in 0...10) {
			link.clientData.send(4, numberedByte(i), SctpDataChunk.PPID_BINARY, true, link.now, 0);
		}

		link.runUntil(() -> link.clientData.outstandingCount() == 0 && delivered.length >= 9, 20);

		Assert.isTrue(dropped, "nothing was lost, so this proves nothing");
		Assert.equals("0,1,3,4,5,6,7,8,9", delivered.join(","), "the stream did not skip the message given up on and go on in order");
	}

	/**
		A message past its lifetime before it was ever sent is dropped unsent.

		Timed reliability: a message queued behind a closed window is worth
		nothing once its time is up, and costs nothing to drop, since it was
		never given a number the peer would wait on.
	**/
	public function testAMessagePastItsLifetimeIsDroppedUnsent():Void {
		if (unsupported()) return;

		var link = Link.open();
		var delivered:Array<Int> = [];
		link.serverData.onMessage = function(_, payload:ByteArray, _):Void {
			payload.position = 0;
			delivered.push(payload.readUnsignedByte());
		};

		// One message in flight and lost, and the window shut behind it, so
		// the rest wait in the queue.
		link.cut = true;
		@:privateAccess link.clientData.__cwnd = 0;
		link.clientData.send(0, numberedByte(0), SctpDataChunk.PPID_BINARY, false, link.now);

		for (i in 1...6) {
			link.clientData.send(0, numberedByte(i), SctpDataChunk.PPID_BINARY, false, link.now, -1, 0.1);
		}

		var queued:Int = link.clientData.bufferedAmount;
		Assert.isTrue(queued > 0, "nothing was held back, so this proves nothing");

		// Past the lifetime, and then the path and the window open again.
		link.runUntil(() -> false, 0.3);
		link.cut = false;
		@:privateAccess link.clientData.__cwnd = SctpDataTransfer.INITIAL_WINDOW;
		link.clientData.send(0, numberedByte(9), SctpDataChunk.PPID_BINARY, false, link.now);
		link.runUntil(() -> link.clientData.outstandingCount() == 0 && link.clientData.bufferedAmount == 0, 10);

		delivered.sort((a, b) -> a - b);
		Assert.equals("0,9", delivered.join(","), "messages past their lifetime were sent anyway");
		Assert.equals(0, link.clientData.bufferedAmount);
	}

	/**
		A message cut short by its lifetime once part of it has gone is
		skipped whole by the peer, even when all that went was acknowledged.

		The rest, still queued, is dropped unsent. The peer holds what went,
		and on an ordered stream waits for the message's sequence number, so a
		FORWARD TSN has to name it even when nothing of the message is left
		outstanding, or the stream would wait for good. Here the SACK for what
		went arrives after the lifetime ran out with no poll between: the same
		tick, which at a runtime's twelve a second is 83 ms wide.
	**/
	public function testAMessageCutShortAfterWhatWentWasAcknowledgedIsSkipped():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var delivered:Array<Int> = [];
		pair.serverData.onMessage = (_, payload:ByteArray, _) -> delivered.push(payload.length);

		// Shut, so only the first of the message's three fragments goes.
		@:privateAccess pair.clientData.__cwnd = 0;
		pair.clientData.send(4, filled(3 * SctpDataTransfer.MAX_PAYLOAD), SctpDataChunk.PPID_BINARY, true, pair.now, -1, 1.0);
		Assert.equals(2 * SctpDataTransfer.MAX_PAYLOAD, pair.clientData.bufferedAmount, "the fragments were not held back, so this proves nothing");

		// It arrives, and the SACK for it comes back after the message's time
		// is up, so the rest is dropped as the window opens.
		pair.step();
		pair.serverData.poll(pair.now);
		pair.now += 2.0;
		pair.step();

		Assert.equals(0, pair.clientData.bufferedAmount, "the rest of the message was not dropped, so this proves nothing");

		// The next message on the stream has to go up.
		pair.clientData.send(4, filled(5), SctpDataChunk.PPID_BINARY, true, pair.now);
		pair.run(() -> delivered.length > 0 && pair.clientData.outstandingCount() == 0);

		Assert.equals("5", delivered.join(","), "the stream waited for good on a message whose rest was dropped");
		Assert.equals(0, @:privateAccess pair.serverData.__buffered, "what went of the message dropped is still held");
		Assert.equals(walked(pair.serverData), @:privateAccess pair.serverData.__buffered);
		Assert.equals(0, pair.clientData.outstandingCount(), "the peer never moved past the message dropped");
	}

	/**
		The same when what went of it was acknowledged out of order, behind an
		earlier message that was lost, after a timeout, when the one packet
		the window allows is that earlier message going again.
	**/
	public function testAMessageCutShortBehindALossIsSkipped():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var delivered:Array<String> = [];
		pair.serverData.onMessage = (streamId:Int, payload:ByteArray, _) -> delivered.push(streamId + ":" + payload.length);

		// A reliable message on stream 2, which is lost, and the first of three
		// fragments of one with a lifetime on stream 4, which arrives.
		@:privateAccess pair.clientData.__cwnd = 0;
		pair.clientData.send(2, filled(1), SctpDataChunk.PPID_BINARY, true, pair.now);
		pair.clientData.send(4, filled(3 * SctpDataTransfer.MAX_PAYLOAD), SctpDataChunk.PPID_BINARY, true, pair.now, -1, 1.0);
		@:privateAccess pair.clientData.__cwnd = 1000;
		pair.clientData.poll(pair.now);
		@:privateAccess pair.clientData.__cwnd = 1;
		Assert.equals(2 * SctpDataTransfer.MAX_PAYLOAD, pair.clientData.bufferedAmount, "the fragments were not held back, so this proves nothing");

		pair.dropNextToServer = 1;
		pair.step();
		pair.step();
		Assert.equals(1, gapAcknowledged(pair.clientData), "the fragment that went was not acknowledged out of order, so this proves nothing");

		// The timer resends the lost one; the rest of the other is past its
		// time and dropped.
		pair.now += 2.0;
		pair.clientData.poll(pair.now);
		Assert.equals(0, pair.clientData.bufferedAmount, "the rest of the message was not dropped, so this proves nothing");

		pair.clientData.send(4, filled(5), SctpDataChunk.PPID_BINARY, true, pair.now);
		pair.run(() -> delivered.length > 1 && pair.clientData.outstandingCount() == 0);

		Assert.equals("2:1,4:5", delivered.join(","), "the stream waited for good on a message whose rest was dropped");
		Assert.equals(0, @:privateAccess pair.serverData.__buffered, "what went of the message dropped is still held");
		Assert.equals(walked(pair.serverData), @:privateAccess pair.serverData.__buffered);
		Assert.equals(0, pair.clientData.outstandingCount(), "the peer never moved past the message dropped");
	}

	/**
		Without the peer's word that it understands FORWARD TSN, nothing is
		given up on.

		RFC 8831: the channel is then reliable. Abandoning a message the peer
		cannot be told about would stop its acknowledgement at the hole for
		good.
	**/
	public function testWithoutThePeersSupportNothingIsGivenUp():Void {
		if (unsupported()) return;

		var link = Link.open();
		@:privateAccess link.client.peerSupportsForwardTsn = false;

		var dropped:Bool = false;
		link.dropToServer = function(_):Bool {
			if (!dropped && link.sentToServer == 1) {
				dropped = true;
				return true;
			}

			return false;
		};

		var delivered:Int = 0;
		link.serverData.onMessage = (_, _, _) -> delivered++;

		link.clientData.send(0, numberedByte(0), SctpDataChunk.PPID_BINARY, false, link.now, 0);
		link.runUntil(() -> delivered == 1, 20);

		Assert.isTrue(dropped);
		Assert.equals(1, delivered, "a message to a peer that cannot be told it was abandoned was abandoned");
	}

	/**
		The receiver follows a FORWARD TSN: past the hole, over what it held,
		and on along the stream it names.
	**/
	public function testTheReceiverFollowsAForwardTsn():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var base:Int = @:privateAccess transfer.__cumulativeTsn;
		var delivered:Array<Int> = [];

		transfer.onMessage = function(_, payload:ByteArray, _):Void {
			payload.position = 0;
			delivered.push(payload.readUnsignedByte());
		};

		var whole = SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING;

		// Sequence 0 at base + 1 never arrives; 1 and 2 do, and wait for it.
		@:privateAccess transfer.__onData(new SctpDataChunk((base + 2) | 0, 3, 1, SctpDataChunk.PPID_BINARY, numberedByte(1), whole).toChunk());
		@:privateAccess transfer.__onData(new SctpDataChunk((base + 3) | 0, 3, 2, SctpDataChunk.PPID_BINARY, numberedByte(2), whole).toChunk());

		// And the start of a message on another stream, whose rest was abandoned
		// with it.
		@:privateAccess transfer.__onData(new SctpDataChunk((base + 4) | 0, 5, 0, SctpDataChunk.PPID_BINARY, filled(10),
			SctpDataChunk.FLAG_BEGINNING).toChunk());

		Assert.equals(0, delivered.length, "something went up while sequence 0 was still missing");

		// The sender gave up on sequence 0 of stream 3 and on the message on
		// stream 5, through base + 4.
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeInt((base + 4) | 0);
		value.writeShort(3);
		value.writeShort(0);
		value.writeShort(5);
		value.writeShort(0);
		value.position = 0;

		@:privateAccess transfer.__onForwardTsn(new SctpChunk(SctpPacket.CHUNK_FORWARD_TSN, 0, value));

		Assert.equals("1,2", delivered.join(","), "what waited behind the abandoned message did not go up in order");
		Assert.equals((base + 4) | 0, @:privateAccess transfer.__cumulativeTsn, "the acknowledgement did not move past what was abandoned");
		Assert.equals(0, @:privateAccess transfer.__buffered, "the abandoned message's first fragment is still held");
		Assert.equals(walked(transfer), @:privateAccess transfer.__buffered);

		// And the next sequence on stream 3 goes straight up.
		@:privateAccess transfer.__onData(new SctpDataChunk((base + 5) | 0, 3, 3, SctpDataChunk.PPID_BINARY, numberedByte(3), whole).toChunk());
		Assert.equals("1,2,3", delivered.join(","));

		// A FORWARD TSN that is behind changes nothing.
		@:privateAccess transfer.__onForwardTsn(new SctpChunk(SctpPacket.CHUNK_FORWARD_TSN, 0, value));
		Assert.equals((base + 5) | 0, @:privateAccess transfer.__cumulativeTsn);
	}

	/** A FORWARD TSN through `through`, naming each stream and sequence given. **/
	private static function forwardTsn(through:Int, entries:Array<Int>):SctpChunk {
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		value.writeInt(through);

		var i:Int = 0;

		while (i + 1 < entries.length) {
			value.writeShort(entries[i]);
			value.writeShort(entries[i + 1]);
			i += 2;
		}

		value.position = 0;
		return new SctpChunk(SctpPacket.CHUNK_FORWARD_TSN, 0, value);
	}

	/**
		A FORWARD TSN naming a stream many times costs what its entries do,
		whatever the stream holds.

		Each entry moving the stream on by one must not walk everything the
		stream holds: 2,000 entries over 8,000 messages held far ahead would
		cost 1.9 seconds on the interpreter and 73 ms on the jvm, from one 8 KB
		packet, and the same packet would cost more with each message the peer
		had sent before it. A stream costs the smaller of the range an entry
		names and what it holds.

		The first size runs twice and the first run is dropped, here and in
		the cases like it: a target compiling as it goes is slowest the first
		time, which would flatter every size after it.
	**/
	public function testAForwardTsnNamingAStreamManyTimesCostsWhatItsEntriesDo():Void {
		if (unsupported()) return;

		var costs:Array<Float> = [];
		var whole = SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING;
		var entries:Int = 500;

		for (held in [1000, 1000, 2000, 4000, 8000]) {
			var best:Float = Math.POSITIVE_INFINITY;

			for (_ in 0...3) {
				var transfer = new SctpDataTransfer(new SctpAssociation());
				var tsn:Int = (@:privateAccess transfer.__cumulativeTsn) + 1;

				// Messages on stream 1, far ahead of the sequence it waits for.
				for (i in 0...held) {
					@:privateAccess transfer.__onData(new SctpDataChunk(tsn, 1, 20000 + i, SctpDataChunk.PPID_BINARY, new ByteArray(), whole).toChunk());
					tsn = (tsn + 1) | 0;
				}

				var steps:Array<Int> = [];

				for (i in 0...entries) {
					steps.push(1);
					steps.push(i);
				}

				// Only the FORWARD TSN is timed: the arrivals are set-up.
				var chunk = forwardTsn(tsn, steps);
				var start:Float = haxe.Timer.stamp();
				@:privateAccess transfer.__onForwardTsn(chunk);
				var spent:Float = haxe.Timer.stamp() - start;

				if (spent < best) {
					best = spent;
				}

				// The stream moved on through every entry, and what it holds is
				// still ahead of it.
				Assert.equals(entries, (@:privateAccess transfer.__expectedSequence).get(1));
				Assert.equals(held, walkedPieces(transfer));
			}

			costs.push(best);
		}

		costs.shift();
		Assert.isTrue(flat(costs, 0.0005), "a FORWARD TSN of 500 entries cost " + microseconds(costs) + " over 1,000, 2,000, 4,000 and 8,000 messages held");
	}

	/**
		FORWARD TSN chunks over thousands of streams reassembling cost what
		they drop, not a pass over every stream.

		Each chunk asking every stream reassembling whether it held a fragment
		the peer had given up on, 200 chunks over 8,000 streams holding a
		fragment each, far ahead, would cost 1.6 seconds on the interpreter and
		22 ms on the jvm, from one packet of 1,612 bytes.
	**/
	public function testForwardTsnChunksOverManyStreamsCostWhatTheyDrop():Void {
		if (unsupported()) return;

		var costs:Array<Float> = [];

		for (streams in [1000, 1000, 2000, 4000, 8000]) {
			var transfer = new SctpDataTransfer(new SctpAssociation());
			var cumulative:Int = @:privateAccess transfer.__cumulativeTsn;

			// One fragment flagged B on each stream, 8,000 past a hole.
			for (s in 0...streams) {
				@:privateAccess transfer.__onData(new SctpDataChunk((cumulative + 8001 + s) | 0, s, 0, SctpDataChunk.PPID_BINARY, new ByteArray(),
					SctpDataChunk.FLAG_BEGINNING).toChunk());
			}

			// Each moves the acknowledgement on by one, into the hole: nothing
			// held is given up.
			var chunks:Array<SctpChunk> = [for (i in 0...200) forwardTsn((cumulative + 1 + i) | 0, [])];

			var start:Float = haxe.Timer.stamp();

			for (chunk in chunks) {
				@:privateAccess transfer.__onForwardTsn(chunk);
			}

			costs.push(haxe.Timer.stamp() - start);

			Assert.equals(streams, walkedPieces(transfer), "a FORWARD TSN through the hole dropped fragments past it");
		}

		costs.shift();
		Assert.isTrue(flat(costs, 0.001), "200 FORWARD TSN chunks over 1,000, 2,000, 4,000 and 8,000 streams cost " + microseconds(costs));
	}

	/**
		And a FORWARD TSN drops exactly what it gives up on, on whichever
		streams hold it: every fragment at or below its TSN, and any left after
		them that no longer begins a message, found by the TSN each stream
		starts at rather than by asking every stream.
	**/
	public function testAForwardTsnDropsWhatItGivesUpOnAcrossStreams():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var base:Int = @:privateAccess transfer.__cumulativeTsn;
		var B = SctpDataChunk.FLAG_BEGINNING;
		var E = SctpDataChunk.FLAG_ENDING;
		var delivered:Array<String> = [];

		transfer.onMessage = (streamId, payload, _) -> delivered.push(streamId + ":" + payload.length);

		function fragment(offset:Int, stream:Int, flags:Int, size:Int):Void {
			@:privateAccess transfer.__onData(new SctpDataChunk((base + offset) | 0, stream, 0, SctpDataChunk.PPID_BINARY, filled(size), flags).toChunk());
		}

		// Stream 2: a message wholly below the TSN given up through.
		fragment(3, 2, B, 10);
		fragment(4, 2, 0, 10);
		// Stream 3: one straddling it (its tail past it goes too, since it
		// no longer begins anything), and then a message wholly above.
		fragment(8, 3, B, 10);
		fragment(9, 3, 0, 10);
		fragment(12, 3, 0, 10);
		fragment(14, 3, B, 10);
		// Stream 4: wholly above.
		fragment(20, 4, B, 10);
		// Stream 5: arrived out of order, so its first fragment is filed
		// late, below where it began.
		fragment(7, 5, 0, 10);
		fragment(6, 5, B, 10);

		Assert.equals(9, @:privateAccess transfer.__pieces);

		@:privateAccess transfer.__onForwardTsn(forwardTsn((base + 10) | 0, []));

		Assert.isNull((@:privateAccess transfer.__partial).get(2), "a message given up on was kept");
		Assert.isNull((@:privateAccess transfer.__partial).get(5), "a message given up on, which arrived out of order, was kept");
		Assert.equals(1, (@:privateAccess transfer.__partial).get(3).fragments.length, "stream 3 did not keep just the message past what was given up");
		Assert.equals(1, (@:privateAccess transfer.__partial).get(4).fragments.length, "a message past what was given up was dropped");
		Assert.equals(walkedPieces(transfer), @:privateAccess transfer.__pieces);
		Assert.equals(walked(transfer), @:privateAccess transfer.__buffered);
		Assert.equals(2, walkedPieces(transfer));

		// What was kept still completes.
		fragment(15, 3, E, 5);
		fragment(21, 4, E, 5);
		Assert.equals("3:15,4:15", delivered.join(","));
		Assert.equals(0, @:privateAccess transfer.__pieces);
	}

	/**
		What the association holds is bounded in pieces as well as bytes.

		The byte bounds do not count a piece of no bytes, and the peer picks
		the size. Without a bound on pieces, fragments flagged B and never E on
		many streams would hold 20,000 objects with `RECEIVE_WINDOW`
		untouched, and as many more as the peer sent; so would ordered
		messages behind a sequence never sent.
	**/
	public function testWhatIsHeldIsBoundedInPiecesAcrossEveryStream():Void {
		if (unsupported()) return;

		for (shape in ["fragments", "messages"]) {
			var transfer = new SctpDataTransfer(new SctpAssociation());
			var tsn:Int = (@:privateAccess transfer.__cumulativeTsn) + 1;
			var failures:Int = 0;
			var peak:Int = 0;
			transfer.onFailure = _ -> failures++;

			for (i in 0...(2 * SctpDataTransfer.MAX_HELD_PIECES + 1000)) {
				var chunk = shape == "fragments" ? new SctpDataChunk(tsn, i % 400, 0, SctpDataChunk.PPID_BINARY, new ByteArray(), SctpDataChunk.FLAG_BEGINNING)
					: new SctpDataChunk(tsn, 1, (i + 1) & 0xFFFF, SctpDataChunk.PPID_BINARY, new ByteArray(),
						SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING);
				@:privateAccess transfer.__onData(chunk.toChunk());
				tsn = (tsn + 1) | 0;

				var now:Int = @:privateAccess transfer.__pieces;

				if (now > peak) {
					peak = now;
				}
			}

			Assert.isTrue(peak <= SctpDataTransfer.MAX_HELD_PIECES, shape + ": the receiver held " + peak + " pieces at once");
			Assert.isTrue(failures > 0, shape + ": giving pieces back was not reported");
			Assert.equals(walkedPieces(transfer), @:privateAccess transfer.__pieces, shape + ": the count drifted from what is held");
			Assert.equals(0, @:privateAccess transfer.__buffered);
		}

		// The bound clears what an honest peer can make this end hold: every
		// TSN it tracks past the acknowledgement, and one whole message below.
		Assert.equals(SctpDataTransfer.MAX_TSN_AHEAD + SctpDataTransfer.MAX_FRAGMENTS, SctpDataTransfer.MAX_HELD_PIECES);
	}

	/**
		A message missing a piece survives a later message on its stream
		completing first.

		Delivering a message takes only its own fragments, not every fragment
		of the stream before it, or an earlier message still waiting on a
		retransmission would lose what it had, and, ordered, the later message
		would then wait for good on a sequence that could no longer complete.
	**/
	public function testAnEarlierMessageMissingAPieceSurvivesALaterOneCompleting():Void {
		if (unsupported()) return;

		var transfer = new SctpDataTransfer(new SctpAssociation());
		var base:Int = @:privateAccess transfer.__cumulativeTsn;
		var delivered:Array<Int> = [];
		transfer.onMessage = (_, payload, _) -> delivered.push(payload.length);

		function fragment(offset:Int, sequence:Int, flags:Int, size:Int):Void {
			@:privateAccess transfer.__onData(new SctpDataChunk((base + offset) | 0, 7, sequence, SctpDataChunk.PPID_BINARY, filled(size), flags).toChunk());
		}

		// Sequence 0 in three fragments, its middle lost; sequence 1 in two.
		fragment(1, 0, SctpDataChunk.FLAG_BEGINNING, 100);
		fragment(3, 0, SctpDataChunk.FLAG_ENDING, 100);
		fragment(4, 1, SctpDataChunk.FLAG_BEGINNING, 50);
		fragment(5, 1, SctpDataChunk.FLAG_ENDING, 50);

		Assert.equals(0, delivered.length, "sequence 1 went up before sequence 0");
		Assert.equals(walked(transfer), @:privateAccess transfer.__buffered);

		// The retransmission.
		fragment(2, 0, 0, 100);

		Assert.equals("300,100", delivered.join(","), "the two messages did not both go up, in order");
		Assert.equals(0, @:privateAccess transfer.__buffered);
		Assert.equals(0, @:privateAccess transfer.__pieces);
		Assert.equals(0, walkedPieces(transfer));
	}

	private static function numberedByte(value:Int):ByteArray {
		var out = new ByteArray();
		out.writeByte(value);
		out.position = 0;
		return out;
	}

	/**
		A message larger than the peer takes is refused before anything goes.

		RFC 8841: a sender must not exceed the peer's max-message-size.
		Unconsulted, the message would go out, every fragment be acknowledged,
		and the receiver drop it whole: the sender would see it delivered and
		the far application never see it at all.
	**/
	public function testAMessageLargerThanThePeerTakesIsRefused():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var packets:Int = 0;
		pair.watchClient(_ -> packets++);
		pair.clientData.peerMaxMessageSize = 1000;

		Assert.raises(() -> pair.clientData.send(0, filled(1001), SctpDataChunk.PPID_BINARY, true, pair.now), ArgumentError);
		Assert.equals(0, packets, "a message the peer would drop was put on the wire");
		Assert.equals(0, pair.clientData.bufferedAmount, "a refused message was queued");

		var got:Int = -1;
		pair.serverData.onMessage = (_, payload, _) -> got = payload.length;
		pair.clientData.send(0, filled(1000), SctpDataChunk.PPID_BINARY, true, pair.now);
		pair.run(() -> got >= 0);

		Assert.equals(1000, got, "a message exactly the size the peer takes was refused or lost");

		// Zero is RFC 8841's any size at all.
		pair.clientData.peerMaxMessageSize = 0;
		pair.clientData.send(0, filled(64 * 1024), SctpDataChunk.PPID_BINARY, true, pair.now);
	}

	/**
		A peer that shuts down gracefully still gets what this end had
		outstanding, before the answer goes.

		RFC 4960 section 9.2: the shutdown waits on the data. Ignored, the
		SHUTDOWN would be retransmitted until the peer gave up and aborted, and
		whatever was still in flight to it would go with the association.
	**/
	public function testAShutdownWaitsForWhatIsStillOutstanding():Void {
		if (unsupported()) return;

		var link = Link.open();
		var delivered:Int = 0;
		link.serverData.onMessage = (_, _, _) -> delivered++;

		var answered:Int = 0;
		link.watchToServer = function(payload:ByteArray):Void {
			var packet = SctpPacket.decode(payload);

			if (packet != null && packet.chunk(SctpPacket.CHUNK_SHUTDOWN_ACK) != null) {
				answered++;
			}
		};

		// Sent, and lost on the way.
		link.cut = true;
		link.clientData.send(0, filled(100), SctpDataChunk.PPID_BINARY, true, link.now);
		link.runUntil(() -> false, 0.1);

		// The peer asks to shut down, having had nothing from this end.
		var cumulative = new ByteArray();
		cumulative.endian = Endian.BIG_ENDIAN;
		cumulative.writeInt((link.client.localTsn - 1) | 0);
		cumulative.position = 0;
		link.client.receive(link.server.packetFor([new SctpChunk(SctpPacket.CHUNK_SHUTDOWN, 0, cumulative)]), link.now);

		Assert.equals(SctpAssociationState.SHUTDOWN_RECEIVED, link.client.state);
		Assert.equals(0, answered, "the SHUTDOWN was answered with a message still undelivered");
		Assert.raises(() -> link.clientData.send(0, filled(1), SctpDataChunk.PPID_BINARY, true, link.now), ArgumentError);

		// The path comes back; the message is resent, delivered and
		// acknowledged, and only then does the answer go.
		link.cut = false;
		link.runUntil(() -> answered > 0, 30);

		Assert.equals(1, delivered, "the message outstanding when the peer asked to shut down was never delivered");
		Assert.equals(1, answered, "the SHUTDOWN was never answered once the message was acknowledged");
		Assert.equals(SctpAssociationState.SHUTDOWN_ACK_SENT, link.client.state);
	}

	/**
		One send does not put the whole window on the wire at once.

		With the peer's window, two megabytes, as the only limit, a megabyte
		would go out in one call as 1,024 packets, for whatever path lay
		between to take or drop. The congestion window bounds what is in
		flight, and no more than `MAX_BURST` packets leave together.
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
		once, and resent each fragment on a fixed timer, would have most of
		every burst dropped, resend it into the same queue, and give fragments
		up after ten tries: a megabyte would never arrive.
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
		again, a round trip or so after it was lost, rather than waiting for
		its own timer whatever the path was saying.
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

		A fixed half-second retransmission timer, on a path with a round trip
		of a second and a half, would send every fragment three times before
		its acknowledgement could possibly arrive, into whatever congestion
		made the path slow. The timer is measured, and once it has been,
		nothing goes twice that the peer received.
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

		RFC 6298 section 5.5. A schedule that grew by half a second a time
		would resend into a path that had gone at an interval that barely
		moved.
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

		`__onSack` walks the outstanding fragments once, not once per gap
		block, and does not take each acknowledged one out of the middle of an
		array: 4,000 blocks over 8,192 outstanding fragments measured 60 ms
		for a single SACK that way, and the peer chooses both numbers. One
		pass costs a few thousand steps, which is well under a millisecond
		compiled; one pass per block costs tens of millions. Best of three
		fresh pairs, so a collection landing in one measurement does not
		decide the result. The first `MAX_SACK_BLOCKS_READ` blocks are the
		ones read.
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

			Assert.equals(SctpDataTransfer.MAX_SACK_BLOCKS_READ, gapAcknowledged(pair.clientData),
				"the SACK did not acknowledge the fragments its blocks named");
		}

		Assert.isTrue(best < allowed,
			"a SACK with " + blocks + " gap blocks over " + outstanding + " fragments took " + Std.int(best * 1e6) + " us");
	}

	/** A pair with `count` one-byte messages outstanding from the client, none acknowledged. **/
	private function outstandingPair(count:Int):Pair {
		var pair = Pair.open();
		pair.client.onSend = _ -> {};

		// Shut, so the messages queue behind the first and go out bundled once
		// it opens: a packet per message would put thousands of checksums in
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

	/**
		A SACK listing thousands of gap blocks costs no more a block than one
		listing a few hundred: the first `MAX_SACK_BLOCKS_READ` are read.

		The count is the peer's to write, and a 16 KB DTLS record carries
		4,000 blocks. Listed highest first, each one read and moved past every
		one before it to sort them would cost 84 ms for one SACK on the jvm,
		half a second on the interpreter, the cost of each block doubling with
		each doubling of the count. A packet's bytes are decoded and checked
		whatever they say, so the measure is the cost of a block, which stays
		flat when nothing does more than read each one.
	**/
	public function testASackListingThousandsOfGapBlocksCostsWhatAFewHundredDo():Void {
		if (unsupported()) return;

		var outstanding:Int = 8192;
		var costs:Array<Float> = [];

		for (blocks in [500, 500, 1000, 2000, 4000]) {
			var pair = outstandingPair(outstanding);
			var first:Int = @:privateAccess pair.clientData.__unacknowledged[0].data.tsn;

			// Every second fragment, each an island of one, listed highest
			// first, acknowledging nothing cumulatively. Read afresh each run,
			// since a block already read acknowledges nothing new.
			var value = new ByteArray();
			value.endian = Endian.BIG_ENDIAN;
			value.writeInt((first - 1) | 0);
			value.writeInt(0x3FFFFFFF);
			value.writeShort(blocks);
			value.writeShort(0);

			for (g in 0...blocks) {
				var offset:Int = 2 * (blocks - g);
				value.writeShort(offset);
				value.writeShort(offset);
			}

			value.position = 0;
			var sack = new SctpChunk(SctpPacket.CHUNK_SACK, 0, value);

			costs.push(cheapest(() -> pair.sackToClient(sack)) / blocks);

			Assert.equals(SctpDataTransfer.MAX_SACK_BLOCKS_READ, gapAcknowledged(pair.clientData),
				"a SACK of " + blocks + " blocks did not acknowledge the fragments of the blocks read");
		}

		costs.shift();
		Assert.isTrue(flat(costs, 0.000001), "a gap block cost " + microseconds(costs) + " in SACKs of 500, 1,000, 2,000 and 4,000");
	}

	/**
		Only the first SACK in a packet is read. Each walks what is
		outstanding, so a packet of a thousand of them would be a thousand
		walks over thousands of fragments; two in one packet were written at
		the same moment and have nothing to add to each other.
	**/
	public function testOnlyTheFirstSackInAPacketIsRead():Void {
		if (unsupported()) return;

		var pair = outstandingPair(64);
		var first:Int = @:privateAccess pair.clientData.__unacknowledged[0].data.tsn;

		function island(offset:Int):SctpChunk {
			var value = new ByteArray();
			value.endian = Endian.BIG_ENDIAN;
			value.writeInt((first - 1) | 0);
			value.writeInt(0x3FFFFFFF);
			value.writeShort(1);
			value.writeShort(0);
			value.writeShort(offset);
			value.writeShort(offset);
			value.position = 0;
			return new SctpChunk(SctpPacket.CHUNK_SACK, 0, value);
		}

		pair.client.receive(pair.server.packetFor([island(10), island(20), island(30)]), pair.now);
		Assert.equals(1, gapAcknowledged(pair.clientData), "more than one SACK in a packet was read");
		Assert.isTrue(@:privateAccess pair.clientData.__unacknowledged[9].acked, "the first SACK in the packet was not the one read");

		// The next packet's is read.
		pair.sackToClient(island(20));
		Assert.equals(2, gapAcknowledged(pair.clientData), "the SACK in the next packet was not read");

		// And a packet of a thousand costs what a packet of one does.
		var big = outstandingPair(8192);
		var bigFirst:Int = @:privateAccess big.clientData.__unacknowledged[0].data.tsn;
		first = bigFirst;
		var one = big.server.packetFor([island(8000)]);
		var many = big.server.packetFor([for (_ in 0...1000) island(8000)]);
		var costOne:Float = cheapest(() -> big.client.receive(one, big.now));
		var costMany:Float = cheapest(() -> big.client.receive(many, big.now));

		// Reading the packet's thousand chunks, and checking its CRC over
		// 16 KB, is the packet's own cost, whatever the SACKs in it do: on a
		// slow runner it alone can come to 3 ms under Node, so the two
		// packets' costs are not compared directly. What must not grow is the
		// handling: a thousand SACKs cost what decoding them does, plus one
		// SACK's handling, rather than a walk over every outstanding chunk
		// each, which would take half a second for a packet of them.
		var decodeMany:Float = cheapest(() -> {
			many.position = 0;
			SctpPacket.decode(many);
		});

		Assert.isTrue(costMany <= decodeMany + costOne * 2 + 0.002,
			"a packet of a thousand SACKs cost " + microseconds([costMany]) + ", decoding it " + microseconds([decodeMany]) + " and a packet of one "
			+ microseconds([costOne]));
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
		SACK. Both only ever look at TSNs *above* the cumulative (the gap walk
		starts at `__cumulativeTsn + 1`, and a chunk at or below it is refused
		on the isEarlier test whether or not the map still holds it), so an
		entry the cumulative has passed can never be read again, and has to be
		removed: otherwise an association would retain every chunk it had ever
		received, payload and all, for as long as it stayed open. An ordinarily
		busy data channel would be enough; no misbehaving peer required.

		Counting the map is the effect here and not a proxy for it: the map is
		the memory that would be retained.
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
		the sender's to pick. Unbounded, with a version that also re-sorted on
		arrival, four thousand fragments, sixty-eight kilobytes on the wire,
		took sixteen seconds.

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

		A constant `RECEIVE_WINDOW` written into every SACK however much had
		piled up behind it would tell the peer the whole window was free right
		up to the point where none of it was. Flow control that reports a
		fixed number is not flow control.
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
		because browsers ask for the range, so on their own they bound nothing
		in aggregate: a megabyte of reassembly and a megabyte held, on each of
		65536 streams, is a ceiling of 128 GB reached by a peer doing nothing
		but sending. The association gives some back rather than taking more
		than it offered to hold, which is what the per-stream bounds already
		do one stream at a time.

		Refusing the chunk instead would be the deadlock: what is held is
		unfinished, so the chunks turned away would include the ones that
		would finish a message and free it.
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

		`peerReceiveWindow`, read off the INIT, and the a_rwnd field of each
		arriving SACK are what the sender is held to: otherwise this end would
		put everything it was handed straight on the wire at whatever rate it
		was handed it, and the receiver's bound would have to absorb the
		difference.
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
		sending the rest. Held in a list searched from the front for whichever
		came next and then taken out of the middle, releasing the stream would
		cost a pass over everything queued for each message released: 4000
		held took 30ms on eval to release that way, doubling per message as
		the count grew, and `MAX_HELD` at one byte a message allows a million
		of them.

		They are asked for by sequence, which is also what stops the count
		from running away: the field is sixteen bits, so a map keyed by it
		holds 65536 at the outside whatever the peer does.
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
		dropped, which is right: the one before it is usually still in flight.
		But the queue needs a bound, or a peer that sends sequence 1 and never
		sequence 0 leaves everything behind it held for the life of the
		association. These are whole reassembled messages, not fragments, so
		it is the more expensive of the two hold queues in this class.
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
	// ------------------------------------------------------------------
	// Stream reset, RFC 6525
	// ------------------------------------------------------------------

	/** A RE-CONFIG chunk carrying one parameter. **/
	private function reconfig(type:Int, fields:Array<Int>, streams:Array<Int>):SctpChunk {
		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;

		for (field in fields) {
			value.writeInt(field);
		}

		for (streamId in streams) {
			value.writeShort(streamId);
		}

		value.position = 0;

		var parameter = new ByteArray();
		SctpParameter.writeAll(parameter, [new SctpParameter(type, value)]);
		parameter.position = 0;
		return new SctpChunk(SctpPacket.CHUNK_RECONFIG, 0, parameter);
	}

	/** Every RE-CONFIG parameter in a packet, as its type and its fields read as 32-bit numbers. **/
	private function reconfigIn(packet:ByteArray):Array<{type:Int, fields:Array<Int>, streams:Array<Int>}> {
		var found = [];
		var decoded = SctpPacket.decode(packet, false);

		if (decoded == null) {
			return found;
		}

		for (chunk in decoded.chunks) {
			if (chunk.type != SctpPacket.CHUNK_RECONFIG) {
				continue;
			}

			for (parameter in SctpParameter.readAll(chunk.value, 0, chunk.value.length)) {
				var value = parameter.value;
				value.endian = Endian.BIG_ENDIAN;
				value.position = 0;

				var fixed:Int = switch (parameter.type) {
					case SctpParameter.OUTGOING_SSN_RESET: 3;
					case SctpParameter.INCOMING_SSN_RESET: 1;
					default: Std.int(value.length / 4);
				}

				var fields:Array<Int> = [for (_ in 0...fixed) value.readInt()];
				var streams:Array<Int> = [];

				while (value.position + 2 <= value.length) {
					streams.push(value.readUnsignedShort());
				}

				found.push({type: parameter.type, fields: fields, streams: streams});
			}
		}

		return found;
	}

	/**
		A stream reset goes out in RFC 6525's form: an Outgoing SSN Reset
		Request numbered from this end's initial TSN, answering the last
		request the peer would have made, naming the last TSN assigned and
		the stream.

		And both ends say in their INIT and INIT ACK that they understand
		RE-CONFIG, which a browser looks for before it will reset anything
		toward this end, or accept a reset from it.
	**/
	public function testAStreamResetIsAskedForInRfc6525sForm():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		Assert.isTrue(pair.client.peerSupportsReconfig && pair.server.peerSupportsReconfig, "the INIT exchange did not say RE-CONFIG is understood");

		var asked:Array<{type:Int, fields:Array<Int>, streams:Array<Int>}> = [];
		pair.watchClient(packet -> for (found in reconfigIn(packet)) asked.push(found));

		pair.clientData.send(3, text("before"), SctpDataChunk.PPID_STRING, true, pair.now);
		var lastTsn:Int = (@:privateAccess pair.clientData.__nextTsn - 1) | 0;
		Assert.isTrue(pair.clientData.resetStreams([3], pair.now), "the reset was not asked for");

		Assert.equals(1, asked.length, "the request did not go at once");

		if (asked.length == 1) {
			Assert.equals(SctpParameter.OUTGOING_SSN_RESET, asked[0].type);
			Assert.equals(pair.client.localTsn, asked[0].fields[0], "the request is not numbered from the initial TSN");
			Assert.equals((pair.server.localTsn - 1) | 0, asked[0].fields[1], "the request does not answer the peer's last request");
			Assert.equals(lastTsn, asked[0].fields[2], "the request does not name the last TSN assigned");
			Assert.equals("3", asked[0].streams.join(","));
		}
	}

	/**
		A peer's reset is performed only once everything it sent before has
		arrived, and answered In progress until then.

		Here the message ahead of it is lost and the request overtakes it, as
		it can over UDP. The receiver answers In progress, the sender asks
		again, the message is resent and delivered, and only then is the
		stream reset and the far end told.
	**/
	public function testAResetWaitsForWhatWasSentBeforeIt():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var events:Array<String> = [];
		var answers:Array<Int> = [];

		pair.serverData.onMessage = (_, payload, _) -> {
			payload.position = 0;
			events.push(payload.readUTFBytes(payload.length));
		};
		pair.serverData.onStreamsReset = streams -> events.push("reset " + streams.join(","));
		pair.watchServer(packet -> for (found in reconfigIn(packet)) if (found.type == SctpParameter.RECONFIG_RESPONSE) answers.push(found.fields[1]));

		pair.dropNextToServer = 1;
		pair.clientData.send(3, text("ahead of the reset"), SctpDataChunk.PPID_STRING, true, pair.now);
		pair.clientData.resetStreams([3], pair.now);

		Assert.isTrue(pair.run(() -> events.length >= 2 && @:privateAccess pair.clientData.__resetRequest == null), "the reset never completed");
		Assert.equals("ahead of the reset,reset 3", events.join(","), "the stream was reset before what was sent ahead of it arrived");
		Assert.equals(6, answers[0], "the first answer was not In progress");
		Assert.equals(1, answers[answers.length - 1], "the last answer was not Performed");
	}

	/**
		A request repeated is answered as it stands now, and one out of
		sequence is refused as such (RFC 6525 section 5.2.1).
	**/
	public function testAResetRequestIsAnsweredBySequence():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var answers:Array<String> = [];
		pair.watchServer(packet -> for (found in reconfigIn(packet)) if (found.type == SctpParameter.RECONFIG_RESPONSE) answers.push(found.fields[0] + ":" + found.fields[1]));

		var first:Int = pair.client.localTsn;
		var lastTsn:Int = (pair.client.localTsn - 1) | 0;
		var request = reconfig(SctpParameter.OUTGOING_SSN_RESET, [first, (pair.server.localTsn - 1) | 0, lastTsn], [3]);

		pair.chunksToServer([request]);
		pair.chunksToServer([request]);
		pair.chunksToServer([reconfig(SctpParameter.OUTGOING_SSN_RESET, [(first + 5) | 0, 0, lastTsn], [3])]);

		Assert.equals(first + ":1," + first + ":1," + ((first + 5) | 0) + ":5", answers.join(","),
			"a request, its repeat and one out of sequence were answered " + answers.join(","));
	}

	/**
		A packet of hundreds of reset requests is answered with a packet's
		worth, and the connection stays up.

		Answering every request, all in one packet, 800 of them would build a
		25,612-byte answer, past the largest datagram DTLS sends, which would
		throw on the way out and end the connection. Past eight answers owed
		the rest go as if lost, and the one request in sequence is still acted
		on when the peer repeats it.
	**/
	public function testAPacketOfManyResetRequestsIsAnsweredWithinADatagram():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var largest:Int = 0;
		var answers:Int = 0;
		pair.watchServer(function(packet:ByteArray):Void {
			if (packet.length > largest) {
				largest = packet.length;
			}

			for (found in reconfigIn(packet)) {
				if (found.type == SctpParameter.RECONFIG_RESPONSE) {
					answers++;
				}
			}
		});

		var first:Int = pair.client.localTsn;
		var lastTsn:Int = (pair.client.localTsn - 1) | 0;

		// Out of sequence, all but the last: each draws a Bad Sequence answer.
		var requests:Array<SctpChunk> = [for (i in 0...800) reconfig(SctpParameter.OUTGOING_SSN_RESET, [(first + 100 + i) | 0, 0, lastTsn], [3])];
		requests.push(reconfig(SctpParameter.OUTGOING_SSN_RESET, [first, (pair.server.localTsn - 1) | 0, lastTsn], [3]));

		try {
			pair.chunksToServer(requests);
		} catch (e:Dynamic) {
			Assert.fail("the answers to a packet of requests threw: " + Std.string(e));
		}

		Assert.equals(SctpAssociationState.ESTABLISHED, pair.server.state, "the requests ended the association");
		Assert.isTrue(largest <= crossbyte.net.rtc.DtlsTransport.MAX_DATAGRAM, "the answers took a packet of " + largest + " bytes");
		Assert.equals(8, answers, "a packet of 801 requests drew " + answers + " answers");

		// The request in sequence, crowded out, is acted on when repeated.
		var reset:Array<Int> = [];
		pair.serverData.onStreamsReset = streams -> if (streams != null) for (s in streams) reset.push(s);
		pair.chunksToServer([requests[800]]);
		Assert.equals("3", reset.join(","), "the request in sequence was never acted on");
	}

	/**
		A peer that acknowledges everything but the first fragment cannot make
		this end keep everything it sends after.

		Neither window counts what gap blocks acknowledged, and it is kept
		until the cumulative acknowledgement passes it, so a peer that held
		that back could have this end keep every fragment the application sent
		(5,000 fragments of a kilobyte, with `bufferedAmount` at 0 throughout,
		so the application had nothing telling it to stop). No more than
		`MAX_TSN_AHEAD` go past the peer's cumulative acknowledgement, and the
		rest wait where `bufferedAmount` counts them.
	**/
	public function testAPeerHoldingBackItsAcknowledgementCannotMakeThisEndKeepEverything():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var transfer = pair.clientData;
		var highest:Int = -1;
		var first:Int = -1;

		pair.client.onSend = function(payload:ByteArray):Void {
			var packet = SctpPacket.decode(payload, false);

			for (chunk in packet.chunks) {
				if (chunk.type == SctpPacket.CHUNK_DATA) {
					chunk.value.endian = Endian.BIG_ENDIAN;
					chunk.value.position = 0;
					var tsn:Int = chunk.value.readInt();

					if (first < 0) {
						first = tsn;
					}

					if (tsn - first > highest) {
						highest = tsn - first;
					}
				}
			}
		};

		@:privateAccess transfer.__peerWindow = 0x3FFFFFFF;

		for (round in 0...60) {
			for (_ in 0...500) {
				transfer.send(0, filled(1), SctpDataChunk.PPID_BINARY, false, pair.now);
			}

			// Everything after the first fragment, gap-acknowledged; the first
			// never.
			if (highest >= 1) {
				var value = new ByteArray();
				value.endian = Endian.BIG_ENDIAN;
				value.writeInt((first - 1) | 0);
				value.writeInt(0x3FFFFFFF);
				value.writeShort(1);
				value.writeShort(0);
				value.writeShort(2);
				value.writeShort(highest + 1);
				value.position = 0;
				pair.sackToClient(new SctpChunk(SctpPacket.CHUNK_SACK, 0, value));
			}

			pair.now += 0.01;
			transfer.poll(pair.now);
		}

		Assert.isTrue(transfer.outstandingCount() <= SctpDataTransfer.MAX_TSN_AHEAD,
			"this end kept " + transfer.outstandingCount() + " fragments past a cumulative acknowledgement the peer held back");
		Assert.isTrue(transfer.bufferedAmount > 0, "what could not be sent was not counted in bufferedAmount");
	}

	/**
		After a peer resets a stream, its next message on it is sequence zero,
		and is delivered.

		What a browser does: its stream sequence numbers start again when it
		resets a stream, and a channel it opens on that number afterwards
		begins at zero. With the reset unread, this end would go on expecting
		the old stream's next number and hold the new channel's messages for
		one that would never come.
	**/
	public function testAfterAPeersResetAStreamStartsAgainFromZero():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var heard:Array<String> = [];
		pair.serverData.onMessage = (_, payload, _) -> {
			payload.position = 0;
			heard.push(payload.readUTFBytes(payload.length));
		};

		pair.clientData.send(5, text("one"), SctpDataChunk.PPID_STRING, true, pair.now);
		pair.clientData.send(5, text("two"), SctpDataChunk.PPID_STRING, true, pair.now);
		Assert.isTrue(pair.run(() -> heard.length == 2), "the first two never arrived");

		// The peer resets stream 5 and starts again on it, as a browser does,
		// with the next TSN it has.
		var tsn:Int = @:privateAccess pair.clientData.__nextTsn;
		pair.chunksToServer([
			reconfig(SctpParameter.OUTGOING_SSN_RESET, [pair.client.localTsn, (pair.server.localTsn - 1) | 0, (tsn - 1) | 0], [5]),
			new SctpDataChunk(tsn, 5, 0, SctpDataChunk.PPID_STRING, text("again"), SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING).toChunk()
		]);

		Assert.equals("one,two,again", heard.join(","), "the first message after the peer's reset was held for a sequence that will never come");
	}

	/**
		A peer that did not say it understands RE-CONFIG is asked nothing: a
		CrossByte peer from before 1.0.
	**/
	public function testAPeerWithoutReconfigIsAskedNothing():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var asked:Int = 0;
		pair.watchClient(packet -> asked += reconfigIn(packet).length);
		@:privateAccess pair.client.peerSupportsReconfig = false;

		Assert.isFalse(pair.clientData.resetStreams([3], pair.now), "a reset was promised to a peer that cannot do one");
		pair.run(() -> false);
		Assert.equals(0, asked, "a RE-CONFIG went to a peer that never said it understands one");
	}

	/**
		A peer asking this end to reset its streams is answered by the reset
		itself, which names the request it answers (RFC 6525 section 5.2.3);
		one asking for streams nothing here sends on is told there was nothing
		to do.
	**/
	public function testAnIncomingResetRequestIsAnsweredByTheReset():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var said:Array<{type:Int, fields:Array<Int>, streams:Array<Int>}> = [];
		pair.watchServer(packet -> for (found in reconfigIn(packet)) said.push(found));

		// Stands in for the data channels: what the peer asks to close, closes.
		var sending:Array<Int> = [7];
		pair.serverData.onStreamsReset = function(streams:Null<Array<Int>>):Void {
			pair.serverData.resetStreams([for (streamId in streams) if (sending.indexOf(streamId) >= 0) streamId], pair.now);
		};

		var first:Int = pair.client.localTsn;
		pair.chunksToServer([reconfig(SctpParameter.INCOMING_SSN_RESET, [first], [7])]);

		Assert.equals(1, said.length, "the request was not answered");

		if (said.length == 1) {
			Assert.equals(SctpParameter.OUTGOING_SSN_RESET, said[0].type, "the answer was not the reset");
			Assert.equals(first, said[0].fields[1], "the reset does not name the request it answers");
			Assert.equals("7", said[0].streams.join(","));
		}

		pair.chunksToServer([reconfig(SctpParameter.INCOMING_SSN_RESET, [(first + 1) | 0], [9])]);

		Assert.equals(2, said.length, "a request for streams nothing sends on was not answered");

		if (said.length == 2) {
			Assert.equals(SctpParameter.RECONFIG_RESPONSE, said[1].type);
			Assert.equals(0, said[1].fields[1], "it was not answered Success - Nothing to do");
		}
	}

	/**
		A reset nobody answers is asked again on a backed-off timer until it
		is, and each unanswered ask counts against the association like a data
		timeout: a wait that ends.
	**/
	public function testAnUnansweredResetIsAskedAgain():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var asked:Int = 0;
		pair.watchClient(packet -> asked += reconfigIn(packet).length);

		pair.cutToServer = true;
		pair.clientData.resetStreams([3], pair.now);

		for (_ in 0...30) {
			pair.clientData.poll(pair.now);
			pair.step();
		}

		Assert.isTrue(asked >= 3, "an unanswered reset was asked " + asked + " times in seven seconds");
		Assert.isTrue(@:privateAccess pair.clientData.__errorCount > 0, "unanswered resets did not count against the association");

		pair.cutToServer = false;
		Assert.isTrue(pair.run(() -> @:privateAccess pair.clientData.__resetRequest == null), "the reset was never answered once the path came back");
	}

	/**
		Once the peer has asked to shut down, no reset is asked for: a request
		waiting, or one the peer never answered, is dropped rather than sent
		into a shutdown, where RFC 6525 has none made.
	**/
	public function testNoResetIsAskedForOnceThePeerShutsDown():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var asked:Int = 0;
		pair.watchClient(packet -> for (found in reconfigIn(packet)) if (found.type == SctpParameter.OUTGOING_SSN_RESET) asked++);

		// One in flight, never answered, and another waiting behind it.
		pair.cutToServer = true;
		pair.clientData.resetStreams([3], pair.now);
		pair.clientData.resetStreams([5], pair.now);
		Assert.equals(1, asked, "the first request did not go");

		// The peer asks to shut down, everything sent having been acknowledged.
		var shutdown = new ByteArray();
		shutdown.endian = Endian.BIG_ENDIAN;
		shutdown.writeInt((@:privateAccess pair.clientData.__nextTsn - 1) | 0);
		shutdown.position = 0;
		pair.sackToClient(new SctpChunk(SctpPacket.CHUNK_SHUTDOWN, 0, shutdown));

		for (_ in 0...30) {
			pair.clientData.poll(pair.now);
			pair.now += 0.25;
		}

		Assert.equals(1, asked, "a reset was asked for " + (asked - 1) + " more times during the shutdown");
	}

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
		// right answer for the wrong reason. These two are adjacent (one step
		// apart in the sequence) and sit at opposite ends of the signed range.
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

	/** Sees every packet the server sends, which still goes on to the client. **/
	public function watchServer(watch:ByteArray->Void):Void {
		server.onSend = function(payload:ByteArray):Void {
			watch(payload);
			toClient.push(payload);
		};
	}

	/** Hands the server chunks as though the client had sent them, in one packet. **/
	public function chunksToServer(chunks:Array<SctpChunk>):Void {
		server.receive(client.packetFor(chunks), now);
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
