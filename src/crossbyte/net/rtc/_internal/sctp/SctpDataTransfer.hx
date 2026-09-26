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
	message on one channel blocks nothing on another, the head-of-line
	blocking that makes a data channel over TCP unattractive.

	## Fragmentation

	A message larger than one packet is cut up, every fragment carrying the same
	stream sequence number, the first flagged B and the last flagged E. The
	receiver holds them until it has both ends. Nothing is delivered half
	finished, which is why an E that never arrives holds one message rather than
	corrupting it.

	## How fast: RFC 4960 section 7

	Two windows decide what may be in the network at once, and the smaller one
	wins. The peer's says how much it can hold. The congestion window says how
	much the path between can carry, and nothing else can tell: a sender that
	knew only the peer's window put a megabyte on the wire in one call,
	1,024 packets at once, into a path that dropped all but a handful, then
	retransmitted each fragment on its own fixed timer.

	The congestion window starts at ten packets and doubles each round trip
	while everything arrives (slow start). Past the first loss it grows by one
	packet a round trip instead. A loss found from what arrived after it, a
	fragment three SACKs have reported missing, is sent again at once and
	halves the window (fast retransmit). A fragment nothing ever acknowledges
	waits out the retransmission timeout, which then doubles, and the window
	drops to one packet. The timeout is measured from real round trips (RFC
	6298, as RFC 4960 section 6.3.1 has it) rather than fixed, so a slow path
	is not flooded with copies and a fast one does not wait on a guess.

	No more than `MAX_BURST` packets leave at any one opportunity, whatever the
	windows allow: an acknowledgement that frees a large part of the window at
	once lets the next packets out a few at a time, spaced by the
	acknowledgements that follow, rather than as one burst into a path that
	may just have dropped the last one.

	Ten timeouts in a row with nothing acknowledged between them, and the peer
	is unreachable: the association ends with an ABORT.
**/
class SctpDataTransfer {
	/**
		The most payload one DATA chunk carries.

		Chosen so a packet fits inside a DTLS record inside a UDP datagram
		without IP fragmentation, a fragmented datagram is lost entirely when
		any fragment is, which turns one dropped packet into a whole message
		resent. Browsers settle on about this figure for the same reason.
	**/
	public static inline var MAX_PAYLOAD:Int = 1024;

	/** What a DATA chunk adds to its payload: four bytes of chunk header and twelve of DATA. **/
	public static inline var DATA_CHUNK_HEADER:Int = 16;

	/**
		The most chunks one packet carries, in bytes: one full fragment.

		Small messages waiting together go out together up to this, and a SACK
		owed rides in front of them. A full fragment still goes alone, so no
		packet is larger than one fragment always made it.
	**/
	public static inline var MAX_BUNDLE:Int = MAX_PAYLOAD + DATA_CHUNK_HEADER;

	/**
		The most this end will queue for a peer that cannot take it yet.

		Flow control means a message handed over is not necessarily a message
		sent: it waits for room in the window the peer advertised. That queue
		is the application's own doing rather than a peer's, so the bound here
		is generous and is a backstop, not a working limit, `bufferedAmount`
		is the figure to watch, and an application that watches it never
		arrives here. Past it `send` throws, because the alternative is either
		discarding something the caller was told nothing about or growing
		until the process dies.
	**/
	public static inline var MAX_BUFFERED:Int = 8 * 1024 * 1024;

	/**
		Retransmission timeouts in a row, with nothing acknowledged between
		them, before the peer is taken to be unreachable: RFC 4960's
		Association.Max.Retrans.
	**/
	public static inline var MAX_ATTEMPTS:Int = 10;

	/** The unit the congestion window moves by: one full packet. **/
	public static inline var MTU:Int = MAX_BUNDLE;

	/**
		The congestion window a transfer starts with: ten packets, as RFC 6928
		gives TCP and as browsers' SCTP stacks use.
	**/
	public static inline var INITIAL_WINDOW:Int = 10 * MTU;

	/** The least the window is halved to, RFC 4960's 4 * MTU. **/
	public static inline var MIN_WINDOW:Int = 4 * MTU;

	/**
		Packets sent at any one opportunity, whatever the windows allow: RFC
		4960's Max.Burst.
	**/
	public static inline var MAX_BURST:Int = 4;

	/** SACKs reporting a fragment missing before it is sent again without waiting (RFC 9260). **/
	public static inline var FAST_RETRANSMIT_AFTER:Int = 3;

	/** The retransmission timeout before any round trip has been measured, RFC 6298's. **/
	public static inline var INITIAL_RTO:Float = 1.0;

	/**
		The least a retransmission timeout can be.

		Above the 200 ms a peer may hold a SACK back for, so a lone message
		that is merely being acknowledged late is not sent again.
	**/
	public static inline var MIN_RTO:Float = 0.4;

	/** The most a timeout doubles to. **/
	public static inline var MAX_RTO:Float = 10.0;

	/** A SACK with no gap blocks: the chunk header and twelve bytes. **/
	private static inline var SACK_MIN_SIZE:Int = 16;

	/**
		How far past the cumulative acknowledgement a TSN is taken at all.

		Anything further is dropped unread, as RFC 4960 leaves a receiver free
		to do with what it cannot track. A peer reading this end's window never
		comes near it: sixteen thousand fragments outstanding past one lost one
		is sixteen megabytes of full-sized ones. And it is what bounds what a
		peer that never sends the next number can make this end hold.
	**/
	public static inline var MAX_TSN_AHEAD:Int = 16384;

	/**
		Gap blocks one SACK reports, at most: the lowest ones, which are what
		the sender needs first. The rest follow in later SACKs as the holes
		below them fill.
	**/
	public static inline var MAX_SACK_BLOCKS:Int = 128;

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
		fragment costs on arrival grows with how many are already held,
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

	/**
		Called when a message arriving here had to be given up: one that grew
		past `MAX_REASSEMBLY` or `MAX_FRAGMENTS`, a stream held past
		`MAX_HELD`, or more held than the window offered.

		Data this end sends that the peer never acknowledges is not reported
		here. That ends the association, through `SctpAssociation.onClose`.
	**/
	public dynamic function onFailure(reason:String):Void {}

	// ------------------------------------------------------------------
	// Sending
	// ------------------------------------------------------------------

	/** The TSN the next fragment put on the wire will carry. **/
	@:noCompletion private var __nextTsn:Int;

	@:noCompletion private var __outboundSequence:IntMap<Int> = new IntMap();

	/** The stream sequence number the message being sent right now was given. **/
	@:noCompletion private var __messageSequence:Int = 0;

	/**
		Everything sent and not yet covered by the peer's cumulative
		acknowledgement, in TSN order from `__outstandingAt`.

		In order because they are sent in order and a retransmission keeps its
		place, which is what lets a SACK be read in one pass: its cumulative
		acknowledgement takes a run off the front, and its gap blocks, sorted
		the same way, are matched against the rest walking forward once. It was
		a list searched once per gap block and then removed from one element at
		a time, so a SACK with 4,000 gap blocks over 8,192 fragments cost 60 ms.

		Fragments a gap block covered stay until the cumulative acknowledgement
		passes them. A receiver may take back what it reported holding (RFC
		4960 section 6.2), and one that has cannot be answered from nothing.
	**/
	@:noCompletion private var __unacknowledged:Array<Outstanding> = [];

	/** Where the live part of `__unacknowledged` starts. **/
	@:noCompletion private var __outstandingAt:Int = 0;

	/**
		How much room the peer last said it had.

		Seeded from the INIT and moved by every SACK. It was read off the INIT
		into `SctpAssociation.peerReceiveWindow` and never looked at, and the
		a_rwnd field of an arriving SACK was read past without being kept, so
		this end sent whatever it was handed at whatever rate it was handed it.
	**/
	@:noCompletion private var __peerWindow:Int;

	/**
		Payload bytes in the network: sent, and neither acknowledged nor found
		lost. What fills the peer's window, which RFC 4960 counts in user data.
	**/
	@:noCompletion private var __inFlight:Int = 0;

	/** The same, counted as chunks on the wire, which is what fills the congestion window. **/
	@:noCompletion private var __flightSize:Int = 0;

	@:noCompletion private var __cwnd:Int = INITIAL_WINDOW;
	@:noCompletion private var __ssthresh:Int;
	@:noCompletion private var __partialBytesAcked:Int = 0;
	@:noCompletion private var __inFastRecovery:Bool = false;

	/** The highest TSN outstanding when fast recovery began; it ends once that is acknowledged. **/
	@:noCompletion private var __fastRecoveryExit:Int = 0;

	/** The highest cumulative acknowledgement the peer has sent. An older SACK is stale. **/
	@:noCompletion private var __cumulativeAcked:Int;

	/** Fragments found lost and waiting to be sent again. **/
	@:noCompletion private var __lostCount:Int = 0;

	/** RFC 6298's SRTT and RTTVAR, in seconds. SRTT is negative until the first sample. **/
	@:noCompletion private var __srtt:Float = -1;

	@:noCompletion private var __rttvar:Float = 0;
	@:noCompletion private var __rto:Float = INITIAL_RTO;

	/** The retransmission timer, RFC 4960's T3-rtx: one for the association, since it has one path. **/
	@:noCompletion private var __timerRunning:Bool = false;

	@:noCompletion private var __timerAt:Float = 0;

	/** Timeouts in a row with nothing acknowledged between them. **/
	@:noCompletion private var __errorCount:Int = 0;

	/** Whether a SACK arrived since the last timeout, which a probe into a closed window is excused by. **/
	@:noCompletion private var __heardSinceTimeout:Bool = false;

	/** When data last left, so a window unused for a timeout can decay (RFC 4960 section 7.2.1). **/
	@:noCompletion private var __lastSentAt:Float = 0;

	/** Queued, not yet numbered, waiting for the windows to open. **/
	@:noCompletion private var __pending:Array<Queued> = [];

	/**
		Where `__pending` has been drained to.

		A cursor rather than shifting the front off, which is a pass over
		everything still queued for each chunk that leaves, and the queue
		runs to `MAX_BUFFERED` over `MAX_PAYLOAD` entries. Compacted once the
		consumed part is the larger half, so it amortises to nothing.
	**/
	@:noCompletion private var __pendingAt:Int = 0;

	@:noCompletion private var __pendingBytes:Int = 0;

	/** The chunks of the packet being assembled, reused from one packet to the next. **/
	@:noCompletion private var __bundle:Array<SctpChunk> = [];

	@:noCompletion private var __bundleBytes:Int = 0;

	/** Packets sent since the current opportunity to send began. **/
	@:noCompletion private var __burst:Int = 0;

	/** Something arrived that may have opened a window; the packet it came in is still being read. **/
	@:noCompletion private var __flushOwed:Bool = false;

	/** Whether the next packet may go past the congestion window, as a fast retransmission's first does. **/
	@:noCompletion private var __forceNext:Bool = false;

	// ------------------------------------------------------------------
	// Receiving
	// ------------------------------------------------------------------

	@:noCompletion private var __cumulativeTsn:Int;

	/**
		Which numbers have arrived above the cumulative acknowledgement, kept
		as runs.

		Asked whether it holds one, `__onData` uses it to spot a duplicate,
		and read out whole by `__buildSack`, whose gap blocks are exactly these
		runs. It was a map of single numbers, which the SACK builder probed at
		each of 511 offsets for every SACK sent, holes or none; and which took
		any number up to 2^31 ahead, so a peer that never sent the next one
		could make it hold as many as it liked, 400,000 entries, 24 MB, in
		the auditor's run.
	**/
	@:noCompletion private var __received:TsnRuns = new TsnRuns();

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

	/** A SACK is owed. **/
	@:noCompletion private var __sackNeeded:Bool = false;

	/**
		A SACK is owed now rather than at the next poll: a gap, a duplicate, or
		a second packet of DATA since the last one (RFC 4960 section 6.2).

		SACKs used to go only from `poll`, once a tick. At the default twelve
		ticks a second that held every acknowledgement up to 83 ms, and one
		SACK then answered however many packets had come in, which leaves a
		sender nothing to pace itself by.
	**/
	@:noCompletion private var __sackNow:Bool = false;

	@:noCompletion private var __dataPacketsSinceSack:Int = 0;
	@:noCompletion private var __packetHadData:Bool = false;

	public function new(association:SctpAssociation) {
		if (association == null) {
			throw new ArgumentError("A data transfer needs an association to run over.");
		}

		this.association = association;
		this.__nextTsn = association.localTsn;
		this.__cumulativeAcked = (association.localTsn - 1) | 0;
		this.__peerWindow = association.peerReceiveWindow;

		// RFC 4960 section 7.2.1: as high as the peer's window, so slow start
		// runs until the first loss says where the path's limit is.
		this.__ssthresh = association.peerReceiveWindow > MIN_WINDOW ? association.peerReceiveWindow : MIN_WINDOW;

		// One before the peer's first, so the first fragment it sends advances
		// the cumulative acknowledgement by exactly one.
		this.__cumulativeTsn = association.remoteTsn - 1;

		association.onChunk = function(chunk:SctpChunk, packet:SctpPacket):Void {
			switch (chunk.type) {
				case SctpPacket.CHUNK_DATA:
					__onData(chunk);
				case SctpPacket.CHUNK_SACK:
					__onSack(chunk);
				case SctpPacket.CHUNK_SHUTDOWN:
					__onShutdown(chunk);
				default:
			}
		};

		association.onPacketEnd = __afterPacket;

		// A shutdown the peer asks for waits on this: everything queued sent,
		// and everything sent acknowledged.
		association.drained = function():Bool {
			return __pendingAt == __pending.length && __outstandingAt == __unacknowledged.length;
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
			if (association.state == SctpAssociationState.SHUTDOWN_RECEIVED
				|| association.state == SctpAssociationState.SHUTDOWN_ACK_SENT) {
				throw new ArgumentError("The peer is shutting the association down, so nothing new can be sent over it.");
			}

			throw new ArgumentError("The association is not open, so there is nothing to send over.");
		}

		if (__pendingBytes + (payload == null ? 0 : payload.length) > MAX_BUFFERED) {
			throw new ArgumentError("The peer is not taking data fast enough to queue another "
				+ (payload == null ? 0 : payload.length) + " bytes behind the " + __pendingBytes
				+ " already waiting; watch bufferedAmount.");
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

			// Queued without a number. TSNs and stream sequence numbers are
			// handed out as fragments go on the wire, in the order they were
			// queued, so waiting for the window reorders nothing, and a
			// message's fragments, queued together, are numbered together.
			__pending.push(new Queued(streamId, protocolId, fragment, flags));
			__pendingBytes += size;

			offset += size;
			first = false;
		} while (offset < total);

		__beginOpportunity();
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
		Resends what has timed out, sends any SACK still owed, and sends what
		the windows now allow.
	**/
	public function poll(now:Float):Void {
		// An association that has ended has nobody to resend to, and its
		// onSend leads into a session that is closing too.
		if (association.state == SctpAssociationState.CLOSED) {
			return;
		}

		if (__timerRunning && now >= __timerAt) {
			__onTimeout(now);

			if (association.state == SctpAssociationState.CLOSED) {
				return;
			}
		}

		// RFC 4960 section 7.2.1: a window nobody has used for a timeout is a
		// measurement of a path that may have changed since, so it decays
		// rather than being spent at once when sending resumes.
		if (__flightSize == 0 && __cwnd > MIN_WINDOW && __nextTsn != association.localTsn && now - __lastSentAt > __rto) {
			__cwnd = (__cwnd >> 1) > MIN_WINDOW ? (__cwnd >> 1) : MIN_WINDOW;
			__lastSentAt = now;
		}

		// Each tick is an opportunity of its own: a window that reopened while
		// nothing was being sent is only noticed here, and a SACK held back
		// for company goes now.
		__beginOpportunity();

		if (__lostCount > 0 || __pendingAt < __pending.length || __sackNeeded) {
			__flush(now, __sackNeeded);
		}
	}

	/** How many fragments are still waiting for the peer's cumulative acknowledgement. **/
	public function outstandingCount():Int {
		return __unacknowledged.length - __outstandingAt;
	}

	/** The congestion window, in bytes of chunks. **/
	public var congestionWindow(get, never):Int;

	@:noCompletion private function get_congestionWindow():Int {
		return __cwnd;
	}

	/** The current retransmission timeout, in seconds. **/
	public var retransmissionTimeout(get, never):Float;

	@:noCompletion private function get_retransmissionTimeout():Float {
		return __rto;
	}

	// ------------------------------------------------------------------
	// Transmission
	// ------------------------------------------------------------------

	@:noCompletion private inline function __beginOpportunity():Void {
		__burst = 0;
	}

	/**
		Puts on the wire what the windows allow: fragments found lost first,
		oldest first, then new ones in the order they were queued.

		@param sackAlone Whether a SACK owed goes out even with no data to
		carry it.
	**/
	@:noCompletion private function __flush(now:Float, sackAlone:Bool = false):Void {
		// And while a shutdown the peer asked for is waiting on what this end
		// still has to deliver: RFC 4960 section 9.2 has it retransmitted as
		// usual, and what was queued before the SHUTDOWN still goes.
		if (association.state != SctpAssociationState.ESTABLISHED && association.state != SctpAssociationState.SHUTDOWN_RECEIVED) {
			return;
		}

		if (__lostCount > 0) {
			__resendLost(now);
		}

		__sendQueued(now);

		if (__bundle.length > 0) {
			__emit();
		}

		// A SACK owed now that found no data to ride with, or data too large
		// to share a packet with, goes on its own.
		if (__sackNeeded && (sackAlone || __sackNow)) {
			__bundle.push(__buildSack());
			__sackSent();
			__emit();
		}

		// Compacted in place once the part already sent is the larger half.
		if (__pendingAt == __pending.length) {
			if (__pendingAt > 0) {
				__pending.resize(0);
				__pendingAt = 0;
			}
		} else if (__pendingAt > 64 && __pendingAt * 2 >= __pending.length) {
			__pending.splice(0, __pendingAt);
			__pendingAt = 0;
		}
	}

	@:noCompletion private function __resendLost(now:Float):Void {
		var at:Int = __outstandingAt;

		while (at < __unacknowledged.length && __lostCount > 0) {
			var outstanding = __unacknowledged[at];
			at++;

			if (!outstanding.lost) {
				continue;
			}

			// The window binds retransmissions as it does new data, except for
			// the first packet after a loss is found: RFC 4960 section 7.2.4
			// sends that one regardless, since waiting would cost a timeout.
			if (!__forceNext && __flightSize >= __cwnd) {
				return;
			}

			if (!__room(outstanding.size)) {
				return;
			}

			outstanding.lost = false;
			outstanding.transmissions++;
			outstanding.sentAt = now;
			__lostCount--;
			__flightSize += outstanding.size;
			__inFlight += outstanding.data.payload.length;
			__add(outstanding.chunk, outstanding.size);
			__armTimer(now);
			__lastSentAt = now;
		}
	}

	@:noCompletion private function __sendQueued(now:Float):Void {
		while (__pendingAt < __pending.length) {
			var next = __pending[__pendingAt];
			var length:Int = next.payload.length;
			var size:Int = __chunkSize(length);

			// The peer's window. One fragment may always be in flight, however
			// closed the window is: a SACK is the only thing that says it has
			// reopened, and a SACK only answers something sent (RFC 4960
			// section 6.1).
			if (__inFlight > 0 && __inFlight + length > __peerWindow) {
				return;
			}

			// The path's. Filled to the packet that crosses it and no further,
			// as RFC 4960 section 6.1 allows.
			if (__flightSize > 0 && __flightSize >= __cwnd) {
				return;
			}

			if (!__room(size)) {
				return;
			}

			var sequence:Int = 0;

			if ((next.flags & SctpDataChunk.FLAG_UNORDERED) == 0) {
				if ((next.flags & SctpDataChunk.FLAG_BEGINNING) != 0) {
					__messageSequence = __outboundSequence.exists(next.streamId) ? __outboundSequence.get(next.streamId) : 0;
					__outboundSequence.set(next.streamId, (__messageSequence + 1) & 0xFFFF);
				}

				sequence = __messageSequence;
			}

			var data = new SctpDataChunk(__nextTsn, next.streamId, sequence, next.protocolId, next.payload, next.flags);
			__nextTsn = (__nextTsn + 1) | 0;

			var outstanding = new Outstanding(data, size, now);
			__unacknowledged.push(outstanding);

			__pendingAt++;
			__pendingBytes -= length;
			__flightSize += size;
			__inFlight += length;
			__add(outstanding.chunk, size);
			__armTimer(now);
			__lastSentAt = now;
		}
	}

	/**
		Whether a chunk of `size` fits in the packet being assembled, sending
		that packet and starting another when it does not. False once this
		opportunity has sent all it may.
	**/
	@:noCompletion private function __room(size:Int):Bool {
		if (__bundle.length == 0) {
			if (__burst >= MAX_BURST) {
				return false;
			}

			// A SACK owed rides in front, and costs nothing extra to send. A
			// SACK is sixteen bytes at the least, so beside a full fragment it
			// is not even built.
			if (__sackNeeded && size + SACK_MIN_SIZE <= MAX_BUNDLE) {
				var sack = __buildSack();

				if (sack.value.length + SctpChunk.HEADER_LENGTH + size <= MAX_BUNDLE) {
					__bundle.push(sack);
					__bundleBytes = sack.value.length + SctpChunk.HEADER_LENGTH;
					__sackSent();
				}
			}

			return true;
		}

		if (__bundleBytes + size <= MAX_BUNDLE) {
			return true;
		}

		__emit();

		if (__burst >= MAX_BURST) {
			return false;
		}

		return true;
	}

	@:noCompletion private inline function __add(chunk:SctpChunk, size:Int):Void {
		__bundle.push(chunk);
		__bundleBytes += size;
	}

	@:noCompletion private function __emit():Void {
		association.onSend(association.packetFor(__bundle));
		__bundle.resize(0);
		__bundleBytes = 0;
		__burst++;
		__forceNext = false;
	}

	@:noCompletion private inline function __sackSent():Void {
		__sackNeeded = false;
		__sackNow = false;
		__dataPacketsSinceSack = 0;
	}

	@:noCompletion private inline function __armTimer(now:Float):Void {
		if (!__timerRunning) {
			__timerRunning = true;
			__timerAt = now + __rto;
		}
	}

	/** A DATA chunk's size on the wire, padding included. **/
	@:noCompletion private static inline function __chunkSize(payload:Int):Int {
		return DATA_CHUNK_HEADER + ((payload + 3) & ~3);
	}

	/**
		The retransmission timer ran out: RFC 4960 section 6.3.3.

		Everything still in flight is taken to be lost, the timeout doubles,
		and the congestion window drops to one packet, a timeout means
		nothing came back for a whole timeout, which is the path saying it
		cannot carry what was sent. The oldest go again first.
	**/
	@:noCompletion private function __onTimeout(now:Float):Void {
		__timerRunning = false;

		// A peer whose window is closed may keep it closed as long as it likes,
		// and the probes this end sends meanwhile are not answered by data. So
		// long as it is still sending SACKs, that is a busy peer rather than a
		// missing one (RFC 9260 section 6.1).
		if (!(__peerWindow <= 0 && __heardSinceTimeout)) {
			__errorCount++;
		}

		__heardSinceTimeout = false;

		if (__errorCount > MAX_ATTEMPTS) {
			// RFC 4960 section 8.1: past the limit the peer is unreachable and
			// the association is over. Dropping just the fragment, which is
			// what happened once, left a reliable ordered stream a hole that
			// nothing would ever fill.
			association.__end("The peer stopped acknowledging data: nothing was acknowledged through " + MAX_ATTEMPTS
				+ " retransmission timeouts in a row.", true);
			return;
		}

		__rto = __rto * 2 > MAX_RTO ? MAX_RTO : __rto * 2;
		__ssthresh = (__cwnd >> 1) > MIN_WINDOW ? (__cwnd >> 1) : MIN_WINDOW;
		__cwnd = MTU;
		__partialBytesAcked = 0;
		__inFastRecovery = false;

		// A receiver may take back what a gap block reported (RFC 4960
		// section 6.2): the fragment at the cumulative point can only read as
		// held if it was. Everything it said it held goes again, since
		// otherwise nothing would ever send the fragment it is waiting for.
		var reneged:Bool = __outstandingAt < __unacknowledged.length && __unacknowledged[__outstandingAt].acked;

		for (at in __outstandingAt...__unacknowledged.length) {
			var outstanding = __unacknowledged[at];

			if (outstanding.acked) {
				if (!reneged) {
					continue;
				}

				outstanding.acked = false;
			} else if (outstanding.lost) {
				continue;
			} else {
				__flightSize -= outstanding.size;
				__inFlight -= outstanding.data.payload.length;
			}

			outstanding.lost = true;
			__lostCount++;
		}

		__beginOpportunity();
		__forceNext = true;
		__flush(now);
	}

	// ------------------------------------------------------------------
	// Acknowledgements
	// ------------------------------------------------------------------

	@:noCompletion private function __onSack(chunk:SctpChunk):Void {
		if (chunk.value.length < 12) {
			return;
		}

		var value = chunk.value;
		value.endian = Endian.BIG_ENDIAN;
		value.position = 0;

		var cumulative:Int = value.readInt();
		var window:Int = value.readInt();
		var gaps:Int = value.readUnsignedShort();
		value.readUnsignedShort();

		__acknowledge(cumulative, window, value, gaps);
	}

	/**
		A SHUTDOWN carries the peer's cumulative acknowledgement and nothing
		else (RFC 4960 section 9.2), and is read like a SACK with no gaps whose
		window is the one already known.
	**/
	@:noCompletion private function __onShutdown(chunk:SctpChunk):Void {
		if (chunk.value.length < 4) {
			return;
		}

		chunk.value.endian = Endian.BIG_ENDIAN;
		chunk.value.position = 0;

		__acknowledge(chunk.value.readInt(), __peerWindow, null, 0);
	}

	/**
		What an acknowledgement says: everything up to `cumulative`, the gap
		blocks after it, and the room the peer has.
	**/
	@:noCompletion private function __acknowledge(cumulative:Int, window:Int, value:Null<ByteArray>, gaps:Int):Void {
		var now:Float = association.clock;

		// Older than one already read, which reordering produces: what it
		// says has been superseded (RFC 4960 section 6.2.1).
		if (SctpDataChunk.isEarlier(cumulative, __cumulativeAcked)) {
			return;
		}

		// Acknowledging a TSN never sent is not an acknowledgement of anything.
		if (SctpDataChunk.isEarlier((__nextTsn - 1) | 0, cumulative)) {
			return;
		}

		__heardSinceTimeout = true;

		var flightBefore:Int = __flightSize;
		var acked:Int = 0;
		var newestSample:Float = Math.NEGATIVE_INFINITY;
		var advanced:Bool = cumulative != __cumulativeAcked;

		// The run the cumulative acknowledgement covers, off the front.
		while (__outstandingAt < __unacknowledged.length) {
			var outstanding = __unacknowledged[__outstandingAt];

			if (SctpDataChunk.isEarlier(cumulative, outstanding.data.tsn)) {
				break;
			}

			__outstandingAt++;

			if (!outstanding.acked) {
				acked += outstanding.size;

				if (outstanding.lost) {
					outstanding.lost = false;
					__lostCount--;
				} else {
					__flightSize -= outstanding.size;
					__inFlight -= outstanding.data.payload.length;
				}

				// Karn's rule: a fragment sent more than once cannot say which
				// copy is being answered.
				if (outstanding.transmissions == 1 && outstanding.sentAt > newestSample) {
					newestSample = outstanding.sentAt;
				}
			}
		}

		__cumulativeAcked = cumulative;

		// The gap blocks, read once and matched against what is outstanding
		// in a single walk forward.
		var blocks:Int = value == null ? 0 : __readGapBlocks(value, gaps);
		var highestNewlyAcked:Int = -1;

		if (blocks > 0) {
			var block:Int = 0;
			var at:Int = __outstandingAt;

			while (at < __unacknowledged.length && block < blocks) {
				var outstanding = __unacknowledged[at];
				var offset:Int = (outstanding.data.tsn - cumulative) | 0;

				if (offset > __gapEnds[block]) {
					block++;
					continue;
				}

				if (offset >= __gapStarts[block] && !outstanding.acked) {
					outstanding.acked = true;
					acked += outstanding.size;
					highestNewlyAcked = at;

					if (outstanding.lost) {
						outstanding.lost = false;
						__lostCount--;
					} else {
						__flightSize -= outstanding.size;
						__inFlight -= outstanding.data.payload.length;
					}

					if (outstanding.transmissions == 1 && outstanding.sentAt > newestSample) {
						newestSample = outstanding.sentAt;
					}
				}

				at++;
			}
		}

		// Miss indications, RFC 9260 section 7.2.4: a fragment still missing
		// below the highest one this SACK newly reported is one more report
		// that it did not arrive. Three, and it is sent again without waiting
		// out the timeout.
		var fastRetransmit:Bool = false;

		for (at in __outstandingAt...(highestNewlyAcked + 1)) {
			var outstanding = __unacknowledged[at];

			if (outstanding.acked || outstanding.lost || outstanding.fastRetransmitted) {
				continue;
			}

			outstanding.misses++;

			if (outstanding.misses >= FAST_RETRANSMIT_AFTER) {
				outstanding.fastRetransmitted = true;
				outstanding.lost = true;
				__lostCount++;
				__flightSize -= outstanding.size;
				__inFlight -= outstanding.data.payload.length;
				fastRetransmit = true;
			}
		}

		if (acked > 0) {
			__errorCount = 0;
		}

		if (newestSample != Math.NEGATIVE_INFINITY) {
			__sampleRoundTrip(now - newestSample);
		}

		// The congestion window, which moves only on a SACK that moved the
		// cumulative acknowledgement (RFC 4960 section 7.2.1 and 7.2.2).
		if (advanced && acked > 0) {
			// Grown only when it was full. A sender that is not using its
			// window learns nothing from acknowledgements about how much more
			// the path could carry.
			var full:Bool = flightBefore + MTU > __cwnd;

			if (__cwnd <= __ssthresh) {
				if (full && !__inFastRecovery) {
					__cwnd += acked < 2 * MTU ? acked : 2 * MTU;
				}
			} else {
				__partialBytesAcked += acked;

				if (__partialBytesAcked >= __cwnd) {
					if (flightBefore >= __cwnd) {
						__partialBytesAcked -= __cwnd;
						__cwnd += MTU;
					} else {
						__partialBytesAcked = __cwnd;
					}
				}
			}

			if (__inFastRecovery && !SctpDataChunk.isEarlier(cumulative, __fastRecoveryExit)) {
				__inFastRecovery = false;
			}
		}

		if (fastRetransmit && !__inFastRecovery) {
			// Once per loss event, not per fragment found missing: everything
			// outstanding when it began is one event (RFC 4960 section 7.2.4).
			__inFastRecovery = true;
			__fastRecoveryExit = (__nextTsn - 1) | 0;
			__ssthresh = (__cwnd >> 1) > MIN_WINDOW ? (__cwnd >> 1) : MIN_WINDOW;
			__cwnd = __ssthresh;
			__partialBytesAcked = 0;
		}

		if (fastRetransmit) {
			__forceNext = true;
		}

		// What the peer has room for, less what is still on its way to it
		// (RFC 4960 section 6.2.1).
		__peerWindow = window;

		// The timer follows the oldest fragment: restarted when the
		// cumulative acknowledgement moves, stopped when nothing is left.
		if (__outstandingAt == __unacknowledged.length) {
			__timerRunning = false;
			__partialBytesAcked = 0;
		} else if (advanced) {
			__timerRunning = true;
			__timerAt = now + __rto;
		}

		// Compacted in place once the acknowledged part is the larger half.
		if (__outstandingAt == __unacknowledged.length) {
			__unacknowledged.resize(0);
			__outstandingAt = 0;
		} else if (__outstandingAt > 64 && __outstandingAt * 2 >= __unacknowledged.length) {
			__unacknowledged.splice(0, __outstandingAt);
			__outstandingAt = 0;
		}

		// The room this freed is sent into once the packet it arrived in has
		// been read, so a SACK owed for DATA in the same packet rides along.
		__flushOwed = true;
	}

	/** Gap block bounds, reused from one SACK to the next. **/
	@:noCompletion private var __gapStarts:Array<Int> = [];

	@:noCompletion private var __gapEnds:Array<Int> = [];

	/**
		Reads a SACK's gap blocks into `__gapStarts` and `__gapEnds`, in
		order, and says how many there are.

		A peer should send them in order and not overlapping. One that did not
		would have its blocks sorted here rather than trusted, since the walk
		that uses them only goes forward.
	**/
	@:noCompletion private function __readGapBlocks(value:ByteArray, gaps:Int):Int {
		var count:Int = 0;
		var sorted:Bool = true;

		for (_ in 0...gaps) {
			if (value.position + 4 > value.length) {
				break;
			}

			var start:Int = value.readUnsignedShort();
			var end:Int = value.readUnsignedShort();

			// Offset zero is the cumulative acknowledgement itself, which no
			// gap can start at, and a block that ends before it starts
			// describes nothing.
			if (start == 0 || end < start) {
				continue;
			}

			if (count > 0 && start <= __gapEnds[count - 1]) {
				sorted = false;
			}

			__gapStarts[count] = start;
			__gapEnds[count] = end;
			count++;
		}

		if (!sorted) {
			// Insertion sort: nearly always nothing to move, and bounded by
			// what fits in one chunk when there is.
			for (i in 1...count) {
				var start:Int = __gapStarts[i];
				var end:Int = __gapEnds[i];
				var j:Int = i - 1;

				while (j >= 0 && __gapStarts[j] > start) {
					__gapStarts[j + 1] = __gapStarts[j];
					__gapEnds[j + 1] = __gapEnds[j];
					j--;
				}

				__gapStarts[j + 1] = start;
				__gapEnds[j + 1] = end;
			}
		}

		return count;
	}

	/**
		Folds one round trip into the retransmission timeout: RFC 6298 section
		2, which RFC 4960 section 6.3.1 adopts.

		A fixed half second, which is what this was, was wrong both ways. A
		path slower than that had every fragment sent again before its
		acknowledgement could arrive, several times over, into the congestion
		it was already causing; a faster one waited on a figure that had
		nothing to do with it.
	**/
	@:noCompletion private function __sampleRoundTrip(sample:Float):Void {
		// Two clocks mixed, or a clock that went backwards: a sample that says
		// nothing about the path.
		if (sample < 0 || sample > 60) {
			return;
		}

		if (__srtt < 0) {
			__srtt = sample;
			__rttvar = sample / 2;
		} else {
			var difference:Float = __srtt - sample;

			if (difference < 0) {
				difference = -difference;
			}

			__rttvar = 0.75 * __rttvar + 0.25 * difference;
			__srtt = 0.875 * __srtt + 0.125 * sample;
		}

		var rto:Float = __srtt + 4 * __rttvar;
		__rto = rto < MIN_RTO ? MIN_RTO : (rto > MAX_RTO ? MAX_RTO : rto);
	}

	/**
		Whatever the packet just read asked for, sent once it has all been read.
	**/
	@:noCompletion private function __afterPacket():Void {
		if (association.state == SctpAssociationState.CLOSED) {
			return;
		}

		// RFC 4960 section 6.2: a SACK for at least every second packet that
		// carried DATA, rather than one a tick for all of them.
		if (__packetHadData) {
			__packetHadData = false;
			__dataPacketsSinceSack++;

			if (__dataPacketsSinceSack >= 2) {
				__sackNow = true;
			}
		}

		if (__flushOwed || __sackNow) {
			__flushOwed = false;
			__beginOpportunity();
			__flush(association.clock);
		}
	}

	// ------------------------------------------------------------------
	// Receiving
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
		__packetHadData = true;

		var distance:Int = (data.tsn - __cumulativeTsn) | 0;

		if (distance <= 0 || __received.contains(data.tsn, __cumulativeTsn)) {
			// And owed at once (RFC 4960 section 6.2): the sender is repeating
			// itself because it has not heard.
			__sackNow = true;
			return;
		}

		// Further ahead than anything this end tracks.
		if (distance > MAX_TSN_AHEAD) {
			__sackNow = true;
			return;
		}

		// RFC 4960 section 6.2: with the window shut, nothing past what has
		// already arrived is taken. What fills a hole below it still is,
		// since that is what completes a message and opens the window again.
		// Dropped with a SACK at once, which is how the sender learns the
		// window is still shut.
		if (SctpAssociation.RECEIVE_WINDOW - __buffered <= 0 && distance > __received.highest(__cumulativeTsn)) {
			__sackNow = true;
			return;
		}

		// Out of order, or filling a hole: either way the sender's picture of
		// what arrived is wrong and the next SACK is what corrects it.
		if (distance != 1 || __received.runs > 0) {
			__sackNow = true;
		}

		if (distance == 1) {
			// Next in line, and it may join the run that was waiting on it.
			__cumulativeTsn = __received.advance(data.tsn);
		} else {
			__received.add(data.tsn, __cumulativeTsn);
		}

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

		Refusing the chunk is the obvious answer and the wrong one. What is
		held is by definition incomplete, so the very chunks that would finish
		a message and free its bytes are among those turned away, and a peer
		holding several part-assembled messages at once would have no way back
		even if it were reading the window.

		Giving some back cannot deadlock, because it always makes room. It is
		also what `MAX_REASSEMBLY` and `MAX_HELD` already do a stream at a
		time, an unfinished message is dropped and said so, and this is
		that rule with the association's total in place of one stream's.

		Down to half rather than just under, so that a peer sitting on the
		limit pays for one pass and not one per chunk.

		What this costs, stated plainly: an application with more than
		`RECEIVE_WINDOW` of part-assembled messages in flight at once now
		loses one of them and hears about it on `onFailure`, where before it
		would have been held and completed. Reaching that takes several
		very large messages on different streams at the same time, which is
		not what a data channel is usually carrying, and it cannot happen to
		a peer that reads the window, which this end's own sender now does.
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
		// arrival, quadratic in a count the peer chooses. Fragments normally
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
		// has accumulated is the part that matters, onFailure is raised for
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
		// is the shape `MAX_REASSEMBLY` exists for, fragments flagged B and
		// never one flagged E, and it used to have every arrival walk the
		// whole of what the peer had already sent.
		if (holding.endings == 0) {
			return;
		}

		// Only the run through the fragment that just arrived can have become
		// complete: anything else was already whole before it, and would have
		// gone up then. So the ends are found from there rather than from the
		// front of everything held, and either walk stops the moment the TSNs
		// stop being consecutive, a gap means a fragment is still in flight,
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
		and once that arrives everything queued behind it follows in one go,
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

			// A sequence already waiting is one the peer has sent twice under
			// different numbers, which `__onData` cannot tell apart from two
			// messages. The first is the one that was held.
			if (waiting.bySequence.exists(sequence)) {
				return;
			}

			waiting.bySequence.set(sequence, new PendingMessage(sequence, protocolId, payload));
			waiting.count++;
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

		// Asked for by number rather than searched for. Held messages used to
		// be a list scanned from the front for whichever one came next, and
		// then taken out of the middle of it, so releasing a stream that had
		// been waiting cost a pass over everything queued for each message
		// released, quadratic in a count the peer chooses by withholding
		// one sequence and sending the rest.
		var expected:Int = __expectedSequence.get(streamId);

		while (waiting.bySequence.exists(expected)) {
			var pending = waiting.bySequence.get(expected);

			// Accounted for before it goes up, so a listener that sends from
			// inside the call is working from the window this end has rather
			// than the one it had a moment ago.
			waiting.bySequence.remove(expected);
			waiting.count--;
			waiting.bytes -= pending.payload.length;
			__buffered -= pending.payload.length;

			expected = (expected + 1) & 0xFFFF;
			__expectedSequence.set(streamId, expected);
			onMessage(streamId, pending.payload, pending.protocolId);
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
		// The runs are the gap blocks, so there is nothing to search: an
		// association with no holes, nearly every SACK ever sent, writes
		// sixteen bytes and is done.
		var blocks:Int = __received.runs < MAX_SACK_BLOCKS ? __received.runs : MAX_SACK_BLOCKS;

		var value = new ByteArray();
		value.endian = Endian.BIG_ENDIAN;
		var free:Int = SctpAssociation.RECEIVE_WINDOW - __buffered;

		value.writeInt(__cumulativeTsn);
		value.writeInt(free > 0 ? free : 0);
		value.writeShort(blocks);
		value.writeShort(0);

		for (i in 0...blocks) {
			var at:Int = __received.head + i;

			// Offsets from the cumulative acknowledgement, which MAX_TSN_AHEAD
			// keeps within the sixteen bits the field has.
			value.writeShort((__received.starts[at] - __cumulativeTsn) | 0);
			value.writeShort((__received.ends[at] - __cumulativeTsn) | 0);
		}

		value.position = 0;
		return new SctpChunk(SctpPacket.CHUNK_SACK, 0, value);
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

/**
	The TSNs a receiver holds above its cumulative acknowledgement, as runs of
	consecutive numbers in order.

	Numbers wrap, so every comparison is by distance from the cumulative
	acknowledgement, which the caller passes, everything here is at most
	`SctpDataTransfer.MAX_TSN_AHEAD` past it, so a distance is always a small
	positive number. Runs come off the front as the acknowledgement passes
	them, through a cursor compacted once the passed part is the larger half.
**/
private class TsnRuns {
	public var starts:Array<Int> = [];
	public var ends:Array<Int> = [];

	/** Where the live runs start. **/
	public var head:Int = 0;

	/** How many runs are held, which is how many gap blocks describe them. **/
	public var runs(get, never):Int;

	/** How many TSNs are held. **/
	public var size(default, null):Int = 0;

	public function new() {}

	private inline function get_runs():Int {
		return ends.length - head;
	}

	/** The first run from `head` whose end is at or past `distance`, or the end of the list. **/
	private function search(distance:Int, cumulative:Int):Int {
		var low:Int = head;
		var high:Int = ends.length;

		while (low < high) {
			var middle:Int = (low + high) >> 1;

			if (((ends[middle] - cumulative) | 0) < distance) {
				low = middle + 1;
			} else {
				high = middle;
			}
		}

		return low;
	}

	public function contains(tsn:Int, cumulative:Int):Bool {
		var distance:Int = (tsn - cumulative) | 0;
		var at:Int = search(distance, cumulative);
		return at < ends.length && ((starts[at] - cumulative) | 0) <= distance;
	}

	/** The distance past `cumulative` of the highest TSN held, or 0 with none. **/
	public function highest(cumulative:Int):Int {
		return ends.length > head ? ((ends[ends.length - 1] - cumulative) | 0) : 0;
	}

	/** Adds a TSN past `cumulative + 1` that is not already held. **/
	public function add(tsn:Int, cumulative:Int):Void {
		var at:Int = search((tsn - cumulative) | 0, cumulative);
		var joinsBefore:Bool = at > head && ((ends[at - 1] + 1) | 0) == tsn;
		var joinsAfter:Bool = at < ends.length && ((tsn + 1) | 0) == starts[at];

		if (joinsBefore && joinsAfter) {
			// It was the one number between two runs, which are now one.
			ends[at - 1] = ends[at];
			starts.splice(at, 1);
			ends.splice(at, 1);
		} else if (joinsBefore) {
			ends[at - 1] = tsn;
		} else if (joinsAfter) {
			starts[at] = tsn;
		} else {
			starts.insert(at, tsn);
			ends.insert(at, tsn);
		}

		size++;
	}

	/**
		The cumulative acknowledgement after `cumulative` has just arrived: the
		first run joins it when that run begins right after.
	**/
	public function advance(cumulative:Int):Int {
		if (ends.length > head && starts[head] == ((cumulative + 1) | 0)) {
			var end:Int = ends[head];
			size -= ((end - starts[head]) | 0) + 1;
			head++;

			if (head == ends.length) {
				starts.resize(0);
				ends.resize(0);
				head = 0;
			} else if (head > 32 && head * 2 >= ends.length) {
				starts.splice(0, head);
				ends.splice(0, head);
				head = 0;
			}

			return end;
		}

		return cumulative;
	}

	/** Every TSN held, in order. For inspection; nothing on the data path walks it. **/
	public function keys():Iterator<Int> {
		var all:Array<Int> = [];

		for (at in head...ends.length) {
			var tsn:Int = starts[at];

			while (true) {
				all.push(tsn);

				if (tsn == ends[at]) {
					break;
				}

				tsn = (tsn + 1) | 0;
			}
		}

		return all.iterator();
	}
}

/** A fragment handed to `send` and not yet on the wire. It has no TSN until it goes. **/
private class Queued {
	public var streamId:Int;
	public var protocolId:Int;
	public var payload:ByteArray;
	public var flags:Int;

	public function new(streamId:Int, protocolId:Int, payload:ByteArray, flags:Int) {
		this.streamId = streamId;
		this.protocolId = protocolId;
		this.payload = payload;
		this.flags = flags;
	}
}

/** A fragment that has gone out and not been acknowledged. **/
private class Outstanding {
	public var data:SctpDataChunk;

	/** Encoded once, when first sent, and the same bytes resent. **/
	public var chunk:SctpChunk;

	/** Its size on the wire, which is what it takes of the congestion window. **/
	public var size:Int;

	public var sentAt:Float;
	public var transmissions:Int = 1;

	/** Reported held by a gap block, and so not in flight. **/
	public var acked:Bool = false;

	/** Found lost and waiting to go again, and so not in flight either. **/
	public var lost:Bool = false;

	/** SACKs that have reported it missing. **/
	public var misses:Int = 0;

	/** Sent again by fast retransmit, which happens once; after that only the timer resends it. **/
	public var fastRetransmitted:Bool = false;

	public function new(data:SctpDataChunk, size:Int, sentAt:Float) {
		this.data = data;
		this.chunk = data.toChunk();
		this.size = size;
		this.sentAt = sentAt;
	}
}

/**
	What one stream is holding until the sequence before it arrives.

	The total travels with the queue for the same reason it does in
	`Reassembly`: it was re-summed over the whole queue on every message that
	arrived out of turn, and how many that is belongs to the peer.
**/
private class Held {
	/**
		By stream sequence, which is what decides when one may go up.

		A map rather than a list because the question asked of it is always
		"is the next one here", never "what is in here", and because the
		sequence is sixteen bits on the wire, so keying by it caps how many
		can be waiting at 65536 without a bound having to say so.
	**/
	public var bySequence:IntMap<PendingMessage> = new IntMap();

	public var count:Int = 0;

	public var bytes:Int = 0;

	public function new() {}
}

/** A complete message waiting for its turn on a stream. **/
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
