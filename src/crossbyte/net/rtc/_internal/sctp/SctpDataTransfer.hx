package crossbyte.net.rtc._internal.sctp;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;
import haxe.ds.IntMap;

/**
	Messages over an open association: sending them, acknowledging them, putting
	them back in order.

	The association handshake gets two peers talking. This is what they say. It
	attaches to an established `SctpAssociation`, takes the DATA and SACK chunks
	that association hands up, and turns them into whole messages on numbered
	streams.

	## What each guarantee costs

	*Reliable* means a fragment that is not acknowledged is sent again, which
	needs every unacknowledged fragment kept until it is. *Ordered* means a
	message waits for anything ahead of it on its stream, which needs arrivals
	held rather than delivered. Unordered delivery skips the second cost and
	keeps the first: a message still arrives, just not necessarily after the one
	sent before it.

	Both are per stream, which is the whole reason SCTP has streams. A large
	message on one channel blocks nothing on another -- the head-of-line
	blocking that makes a data channel over TCP unattractive.

	## Fragmentation

	A message larger than one packet is cut up, every fragment carrying the same
	stream sequence number, the first flagged B and the last flagged E. The
	receiver holds them until it has both ends. Nothing is delivered half
	finished, which is why an E that never arrives holds one message rather than
	corrupting it.
**/
class SctpDataTransfer {
	/**
		The most payload one DATA chunk carries.

		Chosen so a packet fits inside a DTLS record inside a UDP datagram
		without IP fragmentation -- a fragmented datagram is lost entirely when
		any fragment is, which turns one dropped packet into a whole message
		resent. Browsers settle on about this figure for the same reason.
	**/
	public static inline var MAX_PAYLOAD:Int = 1024;

	/** How long an unacknowledged fragment waits before being sent again. **/
	public static inline var RETRANSMIT_AFTER:Float = 0.5;

	/**
		The most this end will queue for a peer that cannot take it yet.

		Flow control means a message handed over is not necessarily a message
		sent: it waits for room in the window the peer advertised. That queue
		is the application's own doing rather than a peer's, so the bound here
		is generous and is a backstop, not a working limit -- `bufferedAmount`
		is the figure to watch, and an application that watches it never
		arrives here. Past it `send` throws, because the alternative is either
		discarding something the caller was told nothing about or growing
		until the process dies.
	**/
	public static inline var MAX_BUFFERED:Int = 8 * 1024 * 1024;

	/** Attempts before the association is considered broken. **/
	public static inline var MAX_ATTEMPTS:Int = 10;

	/**
		The most one reassembling message may hold before it is abandoned.

		`__partial` is trimmed only when a message completes, so a peer that
		sends fragments flagged B and never one flagged E grows it for as long as
		it cares to. Counted in bytes rather than fragments because the sender
		chooses the fragment size; `MAX_PAYLOAD` bounds only what this end emits.
	**/
	public static inline var MAX_REASSEMBLY:Int = 1024 * 1024;

	/**
		How many pieces one message may be split into before it is abandoned.

		Bytes alone do not bound this. The sender picks the fragment size, so
		a megabyte of budget is a megabyte of one-byte fragments, and what a
		fragment costs on arrival grows with how many are already held --
		confirming a run is unbroken means walking it. Measured against a
		version that also re-sorted on each arrival: four thousand fragments,
		sixty-eight kilobytes on the wire, took sixteen seconds, and the byte
		bound above allows two hundred and fifty times that many.

		Two thousand and forty eight splits the largest message this accepts
		at 512 bytes, which is below any path that carries DTLS. A real one
		gives around 1200, so the largest message a peer could honestly send
		arrives in fewer than nine hundred pieces.

		It is also pinned from below by what this end emits: `send` splits at
		`MAX_PAYLOAD`, so a peer running the same code sends `MAX_REASSEMBLY`
		as exactly 1024 fragments. Halving this would refuse them.
	**/
	public static inline var MAX_FRAGMENTS:Int = 2048;

	/**
		The most one stream may hold waiting for its turn before the queue goes.

		A message that arrives early is held rather than dropped, which is right:
		the one it waits for is usually still in flight. But a peer that sends
		sequence 1 and never sequence 0 leaves everything behind it queued for the
		life of the association, and these are whole reassembled messages.
	**/
	public static inline var MAX_HELD:Int = 1024 * 1024;

	/** The association this runs over. **/
	public var association(default, null):SctpAssociation;

	/** Called with each whole message, once it is complete and in order. **/
	public dynamic function onMessage(streamId:Int, payload:ByteArray, protocolId:Int):Void {}

	/** Called when a fragment could not be delivered after every attempt. **/
	public dynamic function onFailure(reason:String):Void {}

	@:noCompletion private var __nextTsn:Int;
	@:noCompletion private var __outboundSequence:IntMap<Int> = new IntMap();
	@:noCompletion private var __unacknowledged:Array<Outstanding> = [];

	/**
		How much room the peer last said it had.

		Seeded from the INIT and moved by every SACK. It was read off the INIT
		into `SctpAssociation.peerReceiveWindow` and never looked at, and the
		a_rwnd field of an arriving SACK was read past without being kept, so
		this end sent whatever it was handed at whatever rate it was handed it.
	**/
	@:noCompletion private var __peerWindow:Int;

	/** Bytes sent and not yet acknowledged, which is what fills that room. **/
	@:noCompletion private var __inFlight:Int = 0;

	/** Built, given a number, and waiting for the window to open. **/
	@:noCompletion private var __pending:Array<SctpDataChunk> = [];

	/**
		Where `__pending` has been drained to.

		A cursor rather than shifting the front off, which is a pass over
		everything still queued for each chunk that leaves -- and the queue
		runs to `MAX_BUFFERED` over `MAX_PAYLOAD` entries. Compacted once the
		consumed part is the larger half, so it amortises to nothing.
	**/
	@:noCompletion private var __pendingAt:Int = 0;

	@:noCompletion private var __pendingBytes:Int = 0;

	/** When the last probe went out into a window with no room in it. **/
	@:noCompletion private var __probedAt:Float = Math.NEGATIVE_INFINITY;

	/**
		The most recent time this end was told.

		A SACK arrives through `association.onChunk`, which is not given one,
		and the window it opens should be used before the next `poll` rather
		than after it.
	**/
	@:noCompletion private var __lastSeen:Float = 0;

	@:noCompletion private var __cumulativeTsn:Int;
	/**
		Which numbers have arrived above the cumulative acknowledgement.

		A set, and only ever asked whether it contains one -- `__onData` uses
		it to spot a duplicate and `__buildSack` to describe the holes. It
		used to hold the chunk itself, which meant a chunk arriving above a
		gap kept its whole payload alive for a value nothing ever read.
	**/
	@:noCompletion private var __received:IntMap<Bool> = new IntMap();

	/**
		Everything held for the application, across every stream.

		What `RECEIVE_WINDOW` is subtracted from to fill in a SACK, so it has
		to follow every change to `__partial` and `__held` exactly. Too low
		and the peer is invited to send more than this end will keep; too
		high and the window closes on a peer that has done nothing wrong.
		`SctpDataTransferTest` walks the real structures and compares.
	**/
	@:noCompletion private var __buffered:Int = 0;
	@:noCompletion private var __partial:IntMap<Reassembly> = new IntMap();
	@:noCompletion private var __expectedSequence:IntMap<Int> = new IntMap();
	@:noCompletion private var __held:IntMap<Held> = new IntMap();
	@:noCompletion private var __sackNeeded:Bool = false;

	public function new(association:SctpAssociation) {
		if (association == null) {
			throw new ArgumentError("A data transfer needs an association to run over.");
		}

		this.association = association;
		this.__nextTsn = association.localTsn;
		this.__peerWindow = association.peerReceiveWindow;

		// One before the peer's first, so the first fragment it sends advances
		// the cumulative acknowledgement by exactly one.
		this.__cumulativeTsn = association.remoteTsn - 1;

		association.onChunk = function(chunk:SctpChunk, packet:SctpPacket):Void {
			switch (chunk.type) {
				case SctpPacket.CHUNK_DATA:
					__onData(chunk);
				case SctpPacket.CHUNK_SACK:
					__onSack(chunk);
				default:
			}
		};
	}

	/**
		Sends a message, fragmenting it if it will not fit in one packet.

		@param ordered Whether this waits for anything ahead of it on its
		stream. Unordered is not unreliable: it still arrives, and is still
		resent if it does not.
	**/
	public function send(streamId:Int, payload:ByteArray, protocolId:Int, ordered:Bool = true, now:Float = 0):Void {
		if (association.state != SctpAssociationState.ESTABLISHED) {
			throw new ArgumentError("The association is not open, so there is nothing to send over.");
		}

		if (__pendingBytes + (payload == null ? 0 : payload.length) > MAX_BUFFERED) {
			throw new ArgumentError("The peer is not taking data fast enough to queue another "
				+ (payload == null ? 0 : payload.length) + " bytes behind the " + __pendingBytes
				+ " already waiting; watch bufferedAmount.");
		}

		__lastSeen = now;

		var sequence:Int = 0;

		if (ordered) {
			sequence = __outboundSequence.exists(streamId) ? __outboundSequence.get(streamId) : 0;
			__outboundSequence.set(streamId, (sequence + 1) & 0xFFFF);
		}

		var total:Int = payload == null ? 0 : payload.length;
		var offset:Int = 0;
		var first:Bool = true;

		// A zero length message is still a message and still needs one chunk,
		// so this runs at least once.
		do {
			var size:Int = total - offset;

			if (size > MAX_PAYLOAD) {
				size = MAX_PAYLOAD;
			}

			var fragment = new ByteArray();

			if (size > 0) {
				payload.position = offset;
				payload.readBytes(fragment, 0, size);
				fragment.position = 0;
			}

			var last:Bool = offset + size >= total;
			var flags:Int = (first ? SctpDataChunk.FLAG_BEGINNING : 0)
				| (last ? SctpDataChunk.FLAG_ENDING : 0)
				| (ordered ? 0 : SctpDataChunk.FLAG_UNORDERED);

			var data = new SctpDataChunk(__nextTsn, streamId, sequence, protocolId, fragment, flags);
			__nextTsn = (__nextTsn + 1) | 0;

			// Numbered here and sent when there is room for it. The numbers
			// are handed out in the order the caller asked for and the queue
			// drains in that order, so waiting for the window does not
			// reorder anything.
			__pending.push(data);
			__pendingBytes += size;

			offset += size;
			first = false;
		} while (offset < total);

		__flush(now);
	}

	/**
		How much has been handed over and not yet put on the wire.

		Zero when the peer is keeping up, which is the ordinary case. It grows
		when the window the peer advertised has no room left, and an
		application sending faster than the far end reads should watch it
		rather than discover `MAX_BUFFERED` the hard way.
	**/
	public var bufferedAmount(get, never):Int;

	@:noCompletion private function get_bufferedAmount():Int {
		return __pendingBytes;
	}

	/**
		Sends what the peer has room for, and nothing it has not.

		The rule is RFC 4960's: what is outstanding may not exceed the
		receiver's advertised window. The exception is the same one, and it is
		not optional -- a window with no room in it is reported by a SACK, a
		SACK only comes back for something sent, so a sender that waited for
		room while sending nothing would wait for a message that only its own
		sending could provoke. One chunk goes regardless, no more often than a
		retransmission would, and the acknowledgement of it carries the window
		that was reopened.
	**/
	@:noCompletion private function __flush(now:Float):Void {
		while (__pendingAt < __pending.length) {
			var next = __pending[__pendingAt];
			var size:Int = next.payload.length;

			if (__inFlight + size > __peerWindow) {
				if (__inFlight > 0 || now < __probedAt + RETRANSMIT_AFTER) {
					// Stopping short, so the part already drained is dropped
					// off the front rather than left to accumulate across
					// however many times the window closes.
					if (__pendingAt > 64 && __pendingAt * 2 >= __pending.length) {
						__pending = __pending.slice(__pendingAt);
						__pendingAt = 0;
					}

					return;
				}

				__probedAt = now;
			}

			__pendingAt++;
			__pendingBytes -= size;
			__inFlight += size;
			__unacknowledged.push(new Outstanding(next, now));
			association.onSend(association.packetFor([next.toChunk()]));
		}

		__pending = [];
		__pendingAt = 0;
	}

	/**
		Resends what has not been acknowledged, and sends any owed SACK.
	**/
	public function poll(now:Float):Void {
		__lastSeen = now;

		if (__sackNeeded) {
			__sackNeeded = false;
			association.onSend(association.packetFor([__buildSack()]));
		}

		for (outstanding in __unacknowledged) {
			if (now < outstanding.sentAt + RETRANSMIT_AFTER * (outstanding.attempts + 1)) {
				continue;
			}

			if (outstanding.attempts >= MAX_ATTEMPTS) {
				onFailure("A fragment went unacknowledged after " + MAX_ATTEMPTS + " attempts.");
				__inFlight -= outstanding.data.payload.length;
				__unacknowledged.remove(outstanding);
				return;
			}

			outstanding.attempts++;
			outstanding.sentAt = now;
			association.onSend(association.packetFor([outstanding.data.toChunk()]));
		}

		// A window that reopened while nothing was being sent is only heard
		// about here, and anything waiting on it has been waiting since.
		__flush(now);
	}

	/** How many fragments are still waiting to be acknowledged. **/
	public function outstandingCount():Int {
		return __unacknowledged.length;
	}

	// ------------------------------------------------------------------

	@:noCompletion private function __onData(chunk:SctpChunk):Void {
		var data = SctpDataChunk.fromChunk(chunk);

		if (data == null) {
			return;
		}

		// Owed whether or not the fragment is new: a duplicate usually means
		// the previous acknowledgement was the thing that went missing, so
		// staying silent would keep the sender retransmitting forever.
		__sackNeeded = true;

		if (__received.exists(data.tsn) || !SctpDataChunk.isEarlier(__cumulativeTsn, data.tsn)) {
			return;
		}

		__received.set(data.tsn, true);
		__advanceCumulative();
		__reassemble(data);

		if (__buffered > SctpAssociation.RECEIVE_WINDOW) {
			__reclaim();
		}
	}

	/**
		Gives back what this end is holding when it has taken on too much.

		The window is published and, for a peer that reads it, that is the
		end of the matter: the SACK says what is left and a sender that
		respects the figure never brings us here. This is for one that does
		not, and the choice is which way to fail.

		Refusing the chunk is the obvious answer and the wrong one. Nothing
		in this stack reads the peer's window either -- `peerReceiveWindow` is
		recorded on the INIT and never looked at again -- so two CrossByte
		ends would sit retransmitting into a refusal with neither one
		yielding. Worse, what is held is by definition incomplete, so the very
		chunks that would finish a message and free its bytes are among those
		turned away, and a peer holding several part-assembled messages at
		once would have no way back even if it were reading the window.

		Giving some back cannot deadlock, because it always makes room. It is
		also what `MAX_REASSEMBLY` and `MAX_HELD` already do a stream at a
		time -- an unfinished message is dropped and said so -- and this is
		that rule with the association's total in place of one stream's.

		Down to half rather than just under, so that a peer sitting on the
		limit pays for one pass and not one per chunk.

		What this costs, stated plainly: an application with more than
		`RECEIVE_WINDOW` of part-assembled messages in flight at once now
		loses one of them and hears about it on `onFailure`, where before it
		would have been held and completed. Reaching that takes several
		very large messages on different streams at the same time, which is
		not what a data channel is usually carrying. It cannot happen to a
		peer that reads the window, and the way to make it impossible
		between two CrossByte ends is for the sending side to read it too --
		`peerReceiveWindow` is recorded on the INIT and nothing consults it,
		so this end still sends whatever it is handed.
	**/
	@:noCompletion private function __reclaim():Void {
		var target:Int = Std.int(SctpAssociation.RECEIVE_WINDOW / 2);
		var dropped:Int = 0;
		var freed:Int = 0;

		// Taken first and walked after. Removing from a map while iterating
		// its own keys is not something every target defines, and this one
		// removes as it goes by construction.
		var reassembling:Array<Int> = [for (key in __partial.keys()) key];

		for (key in reassembling) {
			if (__buffered <= target) {
				break;
			}

			freed += __partial.get(key).bytes;
			dropped++;
			__forget(key);
		}

		var queued:Array<Int> = [for (streamId in __held.keys()) streamId];

		for (streamId in queued) {
			if (__buffered <= target) {
				break;
			}

			freed += __held.get(streamId).bytes;
			dropped++;
			__release(streamId);
		}

		if (dropped > 0) {
			onFailure("The peer sent more than the " + SctpAssociation.RECEIVE_WINDOW + " bytes this end offered to hold, so "
				+ freed + " bytes of unfinished messages on " + dropped + " streams were given up.");
		}
	}

	/** Walks the cumulative acknowledgement forward over everything contiguous. **/
	@:noCompletion private function __advanceCumulative():Void {
		while (__received.exists((__cumulativeTsn + 1) | 0)) {
			__cumulativeTsn = (__cumulativeTsn + 1) | 0;
			// Nothing reads an entry once the cumulative has passed it: the SACK
			// gap blocks start at __cumulativeTsn + 1, and __onData refuses a
			// chunk at or below the cumulative on the isEarlier test, whether or
			// not the map still holds it. Left in, this retained every chunk that
			// ever arrived -- payload included -- for the life of the
			// association, on ordinary traffic and not merely a hostile peer.
			__received.remove(__cumulativeTsn);
		}
	}

	@:noCompletion private function __reassemble(data:SctpDataChunk):Void {
		// The common case: one fragment carrying a whole message.
		if (data.beginning && data.ending) {
			__deliverOrHold(data.streamId, data.streamSequence, data.protocolId, data.payload, data.unordered);
			return;
		}

		var key:Int = data.streamId;
		var holding:Reassembly = __partial.exists(key) ? __partial.get(key) : new Reassembly();
		var fragments:Array<SctpDataChunk> = holding.fragments;

		// Put in TSN order rather than appended and the whole array re-sorted,
		// which cost a comparison against everything already held on every
		// arrival -- quadratic in a count the peer chooses. Fragments normally
		// arrive in order, which this walks straight past; `__onData` has
		// already refused a TSN seen before, so nothing lands on an equal one.
		var at:Int = fragments.length;

		while (at > 0 && SctpDataChunk.isEarlier(data.tsn, fragments[at - 1].tsn)) {
			at--;
		}

		fragments.insert(at, data);
		holding.bytes += data.payload.length;
		__buffered += data.payload.length;

		if (data.ending) {
			holding.endings++;
		}

		__partial.set(key, holding);

		// Bounded here rather than as each fragment arrives: a fragment is only
		// oversized in the context of the message it is joining. Dropping what
		// has accumulated is the part that matters -- onFailure is raised for
		// symmetry with the send side, though nothing in src/ assigns it yet.
		if (holding.bytes > MAX_REASSEMBLY) {
			__forget(key);
			onFailure("A message on stream " + key + " reached " + holding.bytes + " bytes without completing.");
			return;
		}

		if (fragments.length > MAX_FRAGMENTS) {
			__forget(key);
			onFailure("A message on stream " + key + " reached " + fragments.length + " fragments without completing.");
			return;
		}

		// Nothing held ends a message, so nothing held can complete one. This
		// is the shape `MAX_REASSEMBLY` exists for -- fragments flagged B and
		// never one flagged E -- and it used to have every arrival walk the
		// whole of what the peer had already sent.
		if (holding.endings == 0) {
			return;
		}

		// Only the run through the fragment that just arrived can have become
		// complete: anything else was already whole before it, and would have
		// gone up then. So the ends are found from there rather than from the
		// front of everything held, and either walk stops the moment the TSNs
		// stop being consecutive -- a gap means a fragment is still in flight,
		// and delivering what is here would be delivering part of a message.
		var start:Int = at;

		while (!fragments[start].beginning) {
			if (start == 0 || ((fragments[start - 1].tsn + 1) | 0) != fragments[start].tsn) {
				return;
			}

			start--;
		}

		var end:Int = at;

		while (!fragments[end].ending) {
			if (end + 1 == fragments.length || ((fragments[end].tsn + 1) | 0) != fragments[end + 1].tsn) {
				return;
			}

			end++;
		}

		var whole = new ByteArray();

		for (i in start...end + 1) {
			var fragment = fragments[i].payload;

			if (fragment.length > 0) {
				whole.writeBytes(fragment, 0, fragment.length);
			}
		}

		whole.position = 0;

		var head = fragments[start];

		var before:Int = holding.bytes;

		holding.fragments = fragments.slice(end + 1);
		holding.bytes = 0;
		holding.endings = 0;

		for (fragment in holding.fragments) {
			holding.bytes += fragment.payload.length;

			if (fragment.ending) {
				holding.endings++;
			}
		}

		// What the message took with it. Released before the handover, so a
		// listener that sends from inside it sees the window this end has
		// rather than the one it had a moment ago.
		__buffered -= before - holding.bytes;

		__deliverOrHold(head.streamId, head.streamSequence, head.protocolId, whole, head.unordered);
	}

	/** Drops what a stream was reassembling, and stops counting it. **/
	@:noCompletion private function __forget(key:Int):Void {
		if (__partial.exists(key)) {
			__buffered -= __partial.get(key).bytes;
			__partial.remove(key);
		}
	}

	/**
		Delivers a message, or holds it until its turn on the stream.

		Unordered goes straight up. Ordered waits for the sequence before it,
		and once that arrives everything queued behind it follows in one go --
		which is what a receiver looks like when the fragment that was blocking
		it finally lands.
	**/
	@:noCompletion private function __deliverOrHold(streamId:Int, sequence:Int, protocolId:Int, payload:ByteArray, unordered:Bool):Void {
		if (unordered) {
			onMessage(streamId, payload, protocolId);
			return;
		}

		var expected:Int = __expectedSequence.exists(streamId) ? __expectedSequence.get(streamId) : 0;

		if (sequence != expected) {
			// Out of turn. Held rather than dropped: it is not late, it is
			// early, and the one it is waiting for is still on its way.
			var waiting:Held = __held.exists(streamId) ? __held.get(streamId) : new Held();

			waiting.queue.push(new PendingMessage(sequence, protocolId, payload));
			waiting.bytes += payload.length;
			__buffered += payload.length;
			__held.set(streamId, waiting);

			if (waiting.bytes > MAX_HELD) {
				// The sequence being waited on is not coming, so everything
				// queued behind it is unreachable and only costs memory.
				var dropped:Int = waiting.bytes;
				__release(streamId);
				onFailure("Stream " + streamId + " held " + dropped + " bytes waiting for sequence " + expected + ".");
			}

			return;
		}

		onMessage(streamId, payload, protocolId);
		expected = (expected + 1) & 0xFFFF;
		__expectedSequence.set(streamId, expected);

		__drainHeld(streamId);
	}

	@:noCompletion private function __drainHeld(streamId:Int):Void {
		var waiting:Held = __held.exists(streamId) ? __held.get(streamId) : null;

		if (waiting == null) {
			return;
		}

		var moved:Bool = true;

		while (moved) {
			moved = false;
			var expected:Int = __expectedSequence.get(streamId);

			for (pending in waiting.queue) {
				if (pending.sequence == expected) {
					// Accounted for before it goes up, so a listener that
					// sends from inside the call is working from the window
					// this end has rather than the one it had a moment ago.
					waiting.queue.remove(pending);
					waiting.bytes -= pending.payload.length;
					__buffered -= pending.payload.length;
					__expectedSequence.set(streamId, (expected + 1) & 0xFFFF);
					onMessage(streamId, pending.payload, pending.protocolId);
					moved = true;
					break;
				}
			}
		}

		__held.set(streamId, waiting);
	}

	/** Drops what a stream was holding for its turn, and stops counting it. **/
	@:noCompletion private function __release(streamId:Int):Void {
		if (__held.exists(streamId)) {
			__buffered -= __held.get(streamId).bytes;
			__held.remove(streamId);
		}
	}

	/**
		Builds a SACK: what has arrived contiguously, and the islands beyond it.

		The cumulative number says everything up to here is in. The gap blocks
		describe what arrived after a hole, so the sender resends only what is
		missing rather than everything since.
	**/
	@:noCompletion private function __buildSack():SctpChunk {
		var blocks:Array<{start:Int, end:Int}> = [];
		var offset:Int = 1;
		var maximum:Int = 512;

		while (offset < maximum) {
			var tsn:Int = (__cumulativeTsn + offset) | 0;

			if (__received.exists(tsn)) {
				var startOffset:Int = offset;

				while (offset < maximum && __received.exists((__cumulativeTsn + offset) | 0)) {
					offset++;
				}

				blocks.push({start: startOffset, end: offset - 1});
			} else {
				offset++;
			}
		}

		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		var free:Int = SctpAssociation.RECEIVE_WINDOW - __buffered;

		value.writeInt(__cumulativeTsn);
		value.writeInt(free > 0 ? free : 0);
		value.writeShort(blocks.length);
		value.writeShort(0);

		for (block in blocks) {
			value.writeShort(block.start);
			value.writeShort(block.end);
		}

		value.position = 0;
		return new SctpChunk(SctpPacket.CHUNK_SACK, 0, value);
	}

	@:noCompletion private function __onSack(chunk:SctpChunk):Void {
		if (chunk.value.length < 12) {
			return;
		}

		chunk.value.endian = Endian.BIG_ENDIAN;
		chunk.value.position = 0;

		var cumulative:Int = chunk.value.readInt();

		// What the peer has room for. Read and discarded until now, which is
		// what let this end send at whatever rate it was handed data.
		__peerWindow = chunk.value.readInt();

		var gaps:Int = chunk.value.readUnsignedShort();
		chunk.value.readUnsignedShort();

		var acknowledged:Array<Outstanding> = [];

		for (outstanding in __unacknowledged) {
			if (!SctpDataChunk.isEarlier(cumulative, outstanding.data.tsn)) {
				acknowledged.push(outstanding);
			}
		}

		// The islands past the hole, so a fragment that did arrive is not sent
		// again just because something before it did not.
		for (_ in 0...gaps) {
			if (chunk.value.position + 4 > chunk.value.length) {
				break;
			}

			var start:Int = chunk.value.readUnsignedShort();
			var end:Int = chunk.value.readUnsignedShort();

			for (outstanding in __unacknowledged) {
				var distance:Float = (outstanding.data.tsn - cumulative) & 0xFFFFFFFF;

				if (distance >= start && distance <= end) {
					acknowledged.push(outstanding);
				}
			}
		}

		for (outstanding in acknowledged) {
			if (__unacknowledged.remove(outstanding)) {
				__inFlight -= outstanding.data.payload.length;
			}
		}

		// The room this just freed is the room the next chunk was waiting
		// for, and waiting for the next poll to notice would idle the link
		// for a tick on every acknowledgement.
		__flush(__lastSeen);
	}
}

/**
	What one stream has of a message that is not finished.

	The counts travel with the fragments because deriving them is what made
	reassembly quadratic: both the byte total and whether anything here ends a
	message were recomputed over the whole array on every arrival, and the
	peer chooses how long that array is. `SctpWireFuzzTest` measures the real
	fragments against `MAX_REASSEMBLY` rather than reading `bytes`, so a total
	that drifted below the truth would show there.
**/
private class Reassembly {
	/** In TSN order, kept so by insertion. **/
	public var fragments:Array<SctpDataChunk> = [];

	public var bytes:Int = 0;

	/** How many of them are flagged E. **/
	public var endings:Int = 0;

	public function new() {}
}

/** A fragment that has gone out and not been acknowledged. **/
private class Outstanding {
	public var data:SctpDataChunk;
	public var sentAt:Float;
	public var attempts:Int = 0;

	public function new(data:SctpDataChunk, sentAt:Float) {
		this.data = data;
		this.sentAt = sentAt;
	}
}

/** A complete message waiting for its turn on a stream. **/
/**
	What one stream is holding until the sequence before it arrives.

	The total travels with the queue for the same reason it does in
	`Reassembly`: it was re-summed over the whole queue on every message that
	arrived out of turn, and how many that is belongs to the peer.
**/
private class Held {
	public var queue:Array<PendingMessage> = [];

	public var bytes:Int = 0;

	public function new() {}
}

private class PendingMessage {
	public var sequence:Int;
	public var protocolId:Int;
	public var payload:ByteArray;

	public function new(sequence:Int, protocolId:Int, payload:ByteArray) {
		this.sequence = sequence;
		this.protocolId = protocolId;
		this.payload = payload;
	}
}
