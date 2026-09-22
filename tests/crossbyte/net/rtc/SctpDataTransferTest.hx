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

	The guarantees this layer makes -- reliable, and ordered per stream -- are
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
			for (message in (@:privateAccess transfer.__held).get(streamId).queue) {
				total += message.payload.length;
			}
		}

		return total;
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
		one over as it lands. Unordered is not unreliable -- both still arrive --
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

		A message held up on one stream must not delay a message on another --
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
		SACK. Both only ever look at TSNs *above* the cumulative -- the gap walk
		starts at `__cumulativeTsn + 1`, and a chunk at or below it is refused on
		the isEarlier test whether or not the map still holds it. So an entry the
		cumulative has passed can never be read again, and nothing removed it:
		an association retained every chunk it had ever received, payload and
		all, for as long as it stayed open. An ordinarily busy data channel was
		enough; no misbehaving peer required.

		Counting the map is the effect here and not a proxy for it -- the map is
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
		already held to find out whether the run it joined is unbroken -- so
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
		it -- back to the piece flagged B and forward to the one flagged E,
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
		watches the figure reach zero partway through, and stops -- holding
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
		@:privateAccess transfer.__onSack(sack(@:privateAccess transfer.__nextTsn - 1, room));
		chunks = 0;

		var message:Int = 64 * SctpDataTransfer.MAX_PAYLOAD;
		transfer.send(0, filled(message), SctpDataChunk.PPID_BINARY, true, 1.0);

		Assert.equals(4, chunks, "the sender put " + chunks + " fragments on a wire with room for four");
		Assert.equals(message - room, transfer.bufferedAmount);

		// What the window is compared against has to be what is really out
		// there, and it is carried rather than summed, so it can drift.
		var outstanding:Int = 0;

		for (sent in (@:privateAccess transfer.__unacknowledged)) {
			outstanding += sent.data.payload.length;
		}

		Assert.equals(outstanding, @:privateAccess transfer.__inFlight);
	}

	/**
		A window with no room in it still gets one fragment, and recovers.

		This is the part that cannot be left out. A closed window reopens, and
		the only way this end hears about it is a SACK, and a SACK only comes
		back for something sent -- so a sender that waited for room while
		sending nothing would be waiting for a message that its own silence
		prevents. RFC 4960 allows the one probe for exactly that reason.

		The second half is the one worth watching: the acknowledgement of the
		probe carries the reopened window, and everything queued behind it
		goes at once.
	**/
	public function testAClosedWindowGetsAProbeAndThenRecovers():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var transfer = pair.clientData;
		var chunks:Int = 0;
		pair.client.onSend = _ -> chunks++;

		var first:Int = @:privateAccess transfer.__nextTsn;
		@:privateAccess transfer.__onSack(sack((first - 1) | 0, 0));
		chunks = 0;

		var pieces:Int = 8;
		transfer.send(0, filled(pieces * SctpDataTransfer.MAX_PAYLOAD), SctpDataChunk.PPID_BINARY, true, 1.0);

		Assert.equals(1, chunks, "a closed window sent " + chunks + " fragments; one is the probe and more is ignoring it");
		Assert.equals((pieces - 1) * SctpDataTransfer.MAX_PAYLOAD, transfer.bufferedAmount);

		// The peer takes the probe and says it has room again.
		@:privateAccess transfer.__onSack(sack(first, 1024 * 1024));

		Assert.equals(pieces, chunks, "the queue did not move when the window reopened");
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
		A stream cannot hold without bound for a sequence that never comes.

		An ordered message arriving early is held until its turn rather than
		dropped, which is right -- the one before it is usually still in flight.
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
		// right answer for the wrong reason. These two are adjacent -- one step
		// apart in the sequence -- and sit at opposite ends of the signed range.
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

	private function deliver():Void {
		var outbound = toServer;
		var inbound = toClient;
		toServer = [];
		toClient = [];

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
