package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.OutstandingFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.ds.SequenceRing;
import crossbyte.net._internal.reliable.FrameWindow;
import utest.Assert;

/**
	Exercises the pure out-of-order delivery-window logic of
	`ReliableDatagramSocket`. These cases drive the buffering decision and
	the cache cap directly, without any live socket I/O, so they run under
	the eval/interp target.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.CongestionControl)
class RUDPHardeningTest extends utest.Test {
	public function testInOrderSequenceIsNeverBuffered():Void {
		var socket = makeSocket();
		socket.__inSequence = 100;

		// The next expected sequence is delivered immediately, not buffered.
		Assert.isFalse(socket.__shouldBufferPacket(100));
	}

	public function testSequenceJustAheadIsBuffered():Void {
		var socket = makeSocket();
		socket.__inSequence = 100;

		Assert.isTrue(socket.__shouldBufferPacket(101));
		Assert.isTrue(socket.__shouldBufferPacket(200));
	}

	public function testSequenceAtWindowEdgeIsBuffered():Void {
		var socket = makeSocket();
		socket.__inSequence = 100;

		var edge:Seq32 = (100 : Seq32) + ReliableDatagramSocket.DELIVERY_WINDOW;
		Assert.isTrue(socket.__shouldBufferPacket(edge));
	}

	public function testSequenceBeyondWindowIsRejected():Void {
		var socket = makeSocket();
		socket.__inSequence = 100;

		var beyond:Seq32 = (100 : Seq32) + ReliableDatagramSocket.DELIVERY_WINDOW + 1;
		Assert.isFalse(socket.__shouldBufferPacket(beyond));

		var farBeyond:Seq32 = (100 : Seq32) + 1000000;
		Assert.isFalse(socket.__shouldBufferPacket(farBeyond));
	}

	public function testStaleSequenceBehindCursorIsRejected():Void {
		var socket = makeSocket();
		socket.__inSequence = 100;

		Assert.isFalse(socket.__shouldBufferPacket(50));
		Assert.isFalse(socket.__shouldBufferPacket(99));
	}

	public function testWindowEdgeWrapsCorrectlyAcrossBoundary():Void {
		var socket = makeSocket();
		// Choose a cursor near the top of the 32-bit space so the window ceiling
		// wraps past zero. The RFC-1982 ordering on Seq32 must keep this correct.
		var cursor:Seq32 = (0xFFFFFFFA : Seq32); // top of the 32-bit space, -6 in Int terms
		socket.__inSequence = cursor;

		// A sequence a few slots ahead wraps past 0 and must still be inside the
		// window.
		var wrapped:Seq32 = cursor + 10; // wraps to 0x00000004
		Assert.isTrue(socket.__shouldBufferPacket(wrapped));

		// A sequence beyond the window (also on the far side of the wrap) is
		// rejected.
		var wrappedBeyond:Seq32 = cursor + ReliableDatagramSocket.DELIVERY_WINDOW + 10;
		Assert.isFalse(socket.__shouldBufferPacket(wrappedBeyond));
	}

	public function testCacheIsBoundedByDeliveryWindow():Void {
		var socket = makeSocket();
		socket.__inSequence = 0;

		// Fill the out-of-order cache to its cap with distinct in-window
		// sequences (skip sequence 0, which is the in-order one).
		var seq:Int = 1;
		while (socket.__inFrameCacheCount() < ReliableDatagramSocket.DELIVERY_WINDOW) {
			if (socket.__shouldBufferPacket(seq)) {
				socket.__cacheFrame(seq, payloadOf("x"));
			}
			seq++;
		}

		Assert.equals(ReliableDatagramSocket.DELIVERY_WINDOW, socket.__inFrameCacheCount());

		// Once the cap is reached, further in-window sequences are refused so the
		// cache cannot grow without bound.
		Assert.isFalse(socket.__shouldBufferPacket(seq));
		Assert.equals(ReliableDatagramSocket.DELIVERY_WINDOW, socket.__inFrameCacheCount());
	}

	public function testAlreadyCachedSequenceIsNotRebuffered():Void {
		var socket = makeSocket();
		socket.__inSequence = 0;
		socket.__cacheFrame(5, payloadOf("y"));

		Assert.isFalse(socket.__shouldBufferPacket(5));
	}

	public function testRandomSequenceSeedSpansFull32BitRange():Void {
		var socket = makeSocket();

		// Seeds must be well-distributed across the full unsigned 32-bit space,
		// not all clustered in the low 31 bits, as Std.random(MAX_INT_32) would
		// seed them.
		var sawHighBit:Bool = false;
		// Float is not a valid Map key, so key the distinctness set by the seed's
		// decimal string form. This still proves the generator is not a constant.
		var distinct = new Map<String, Bool>();
		for (i in 0...256) {
			var seed:Seq32 = socket.__randomSequenceSeed();
			var seedFloat:Float = seed;
			distinct.set(Std.string(seedFloat), true);
			// The unsigned 32-bit value clears 0x7FFFFFFF only when its top bit is
			// set; checking against 2^31 avoids any UInt->Seq32 coercion in the test.
			if (seedFloat >= 2147483648.0) {
				sawHighBit = true;
			}
		}

		// The seed source produces varied values (not a constant).
		var count:Int = 0;
		for (_ in distinct.keys()) {
			count++;
		}
		Assert.isTrue(count > 1);
		// Across 256 draws the top bit should be set at least once, proving the
		// generator reaches above 0x7FFFFFFF.
		Assert.isTrue(sawHighBit);
	}

	// The public constructor opens a real UdpSocket, which throws under the
	// eval/interp target (no UDP backend). Build a bare instance instead so the
	// pure sequence-window logic can be exercised everywhere. createEmptyInstance
	// skips field initializers, so the fields these tests touch are seeded
	// defensively here rather than relying on the constructor.
	/**
		The timeout is measured, not assumed.

		A flat retransmit interval of 3 seconds would be wrong in both
		directions: on a local path a lost frame would wait three seconds for
		nothing; on a path slower than three seconds it would declare loss that
		had not happened and send the frame again, which is how a congested link
		is made worse by the thing meant to be reliable over it.
	**/
	public function testTheRetransmitTimeoutIsMeasuredNotAssumed():Void {
		var socket = makeSender();

		// A fast path: the timeout should come down near the round trip,
		// nowhere near three seconds.
		for (_ in 0...20) {
			socket.__sampleRoundTrip(0.010, 0);
		}

		Assert.isTrue(socket.__rto < 0.5, "a 10ms path still waits " + socket.__rto + "s before resending");
		Assert.isTrue(socket.__rto >= ReliableDatagramSocket.MIN_RTO, "the timeout went below its floor: " + socket.__rto);

		// A slow path: it should go up, rather than resending into it.
		var slow = makeSender();

		for (_ in 0...20) {
			slow.__sampleRoundTrip(1.2, 0);
		}

		Assert.isTrue(slow.__rto > 1.0, "a 1.2s path resends after only " + slow.__rto + "s");
		Assert.isTrue(slow.__rto <= ReliableDatagramSocket.MAX_RTO, "the timeout went past its ceiling: " + slow.__rto);
	}

	/**
		The window opens on delivery and halves on loss.

		A constant window that took no notice of whether any of it was
		arriving would keep frames in flight down a path already dropping them,
		making the drops worse without stopping, which is how one bad path
		costs a server the bandwidth of many good ones.
	**/
	public function testTheWindowOpensOnDeliveryAndHalvesOnLoss():Void {
		var socket = makeSender();
		var control = socket.congestionControl;
		var start:Float = control.window;

		control.onAcknowledged(socket, 1, 0);
		Assert.isTrue(control.window > start, "an acknowledged frame did not open the window");

		var open:Float = control.window;
		control.onTimeout(socket, 0);

		Assert.isTrue(control.window <= open / 2 + 0.001, "loss left the window at " + control.window + " against " + open);

		// And it never collapses to nothing, or the session cannot recover.
		for (_ in 0...40) {
			control.onTimeout(socket, 0);
		}

		Assert.isTrue(control.window >= CongestionControl.MIN_WINDOW, "repeated loss closed the window to " + control.window);
	}

	/**
		The window is what bounds what is in flight, not a constant.

		`__windowExceeded` compares against the congestion window, not
		`DELIVERY_WINDOW`, which would bound the send side by the receiver's
		buffer and by nothing about the path between them.
	**/
	public function testWhatIsInFlightIsBoundedByTheWindow():Void {
		var socket = makeSender();
		socket.__congestion.window = 4;
		socket.__windowBase = 100;
		socket.__outSequence = 103;

		Assert.isFalse(socket.__windowExceeded(), "three frames in flight against a window of four is not full");

		socket.__outSequence = 104;
		Assert.isTrue(socket.__windowExceeded(), "four frames in flight against a window of four is full");
	}

	/**
		What waits for the window is bounded and says so.

		The window can close, so an application writing faster than the path
		will carry has to be told rather than have the queue grow until the
		process dies. Same bound and policies as `Socket`.
	**/
	public function testTheSendQueueIsBounded():Void {
		var socket = makeSender();
		// Nothing may go out, so everything written waits.
		socket.__congestion.window = 0;
		socket.maxOutputBufferSize = 4096;
		socket.outputOverflowPolicy = THROW;

		var refused:Bool = false;

		try {
			for (_ in 0...64) {
				var message = payloadOf(oneKilobyte());
				socket.__queueBytes(message, 0, message.length);
			}
		} catch (e:Dynamic) {
			refused = true;
		}

		Assert.isTrue(refused, "the queue passed " + socket.maxOutputBufferSize + " bytes without a word");
		Assert.isTrue(socket.bufferedAmount > 0, "nothing was reported as waiting");
	}

	/**
		Only the oldest frame is resent, and only once its own time is up.

		One clock for the session compares against each frame's deadline,
		rather than a repeating timer per packet, which costs a server more than
		anyone notices; so the deadline is what needs to be right.
	**/
	public function testOnlyTheOldestOverdueFrameIsResent():Void {
		var socket = makeSender();
		socket.__windowBase = 10;
		socket.__outSequence = 13;

		// Three in flight. The oldest is not due yet; the others are, but
		// nothing behind the oldest can be acknowledged before it anyway.
		socket.__outFrameCache.set(10, makeFrame(100.0, 100.5));
		socket.__outFrameCache.set(11, makeFrame(100.0, 99.0));
		socket.__outFrameCache.set(12, makeFrame(100.0, 99.0));

		Assert.isNull(socket.__overdueFrame(100.2), "a frame was resent before its deadline");

		// Once the oldest is past its deadline, it is the one that goes.
		var due = socket.__overdueFrame(100.6);
		Assert.notNull(due, "the oldest frame passed its deadline and was not picked up");

		if (due != null) {
			Assert.equals(100.5, due.deadline, "a frame other than the oldest was chosen");
		}
	}

	/**
		The retransmission clock stops when there is nothing to retransmit.

		One timer for the session is only an improvement if it is given back.
		A session that fell silent with the clock still armed would wake every
		tick for the life of the process.
	**/
	public function testTheRetransmitClockStopsWhenNothingIsOutstanding():Void {
		var socket = makeSender();
		socket.__connected = true;
		socket.__closed = false;
		socket.__retransmitHandle = 4242;

		socket.__checkRetransmits();

		Assert.equals(-1, socket.__retransmitHandle, "the clock stayed armed with nothing in flight");
	}

	private static function makeFrame(sentAt:Float, deadline:Float):OutstandingFrame {
		return new OutstandingFrame(payloadOf("x"), sentAt, deadline);
	}

	private static function oneKilobyte():String {
		var out = new StringBuf();

		for (_ in 0...1024) {
			out.add("x");
		}

		return out.toString();
	}

	/** An empty socket with the send-side state a live one starts with. **/
	private static function makeSender():ReliableDatagramSocket {
		var socket:ReliableDatagramSocket = Type.createEmptyInstance(ReliableDatagramSocket);
		// createEmptyInstance does not run field initialisers, so the values
		// a real socket starts with are set here rather than inherited.
		socket.__outFrameCache = new FrameWindow();
		socket.__outgoingQueue = [];
		socket.__queueAt = 0;
		socket.__queuedBytes = 0;
		socket.__outSequence = 0;
		socket.__windowBase = 0;
		socket.__congestion = new CongestionControl();
		socket.__smoothedRtt = -1;
		socket.__rttVariation = 0;
		socket.__rto = ReliableDatagramSocket.INITIAL_RTO;
		socket.__sackedCount = 0;
		socket.__inRecovery = false;
		socket.__dupAcks = 0;
		socket.__peerSacks = false;
		socket.__rackSentAt = -1;
		socket.__rackRtt = 0;
		socket.__minRtt = -1;
		socket.__answerRtt = -1;
		socket.__answerVariation = 0;
		socket.__peerAckDelay = -1;
		socket.__ackDelay = ReliableDatagramSocket.DEFAULT_ACK_DELAY;
		socket.__ackHeld = false;
		socket.__unacknowledged = 0;
		socket.__newestArrivalAt = -1;
		socket.__ackTimer = -1;
		socket.__reorderingSeen = false;
		socket.__lastTransmitAt = 0;
		socket.__lastDeliveryAt = 0;
		socket.__probed = false;
		socket.__fastResends = 0;
		socket.__probes = 0;
		socket.__timeoutResends = 0;
		socket.__closing = false;
		socket.maxOutputBufferSize = 0;
		socket.outputOverflowPolicy = CLOSE;
		return socket;
	}

	private static function makeSocket():ReliableDatagramSocket {
		var socket:ReliableDatagramSocket = Type.createEmptyInstance(ReliableDatagramSocket);
		socket.__inFrameCache = new SequenceRing(ReliableDatagramSocket.IN_FRAME_SLOTS);
		socket.__inFrameCacheSize = 0;
		socket.__inSequence = 0;
		return socket;
	}

	private static function payloadOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	/**
		An ACK's map of the frames held past a gap is read from a ring of bits
		kept beside the cache, not built by walking the cache's keys. It names
		exactly what the walk would name (frames held, by their offset past the
		next expected) for any next expected, the 32-bit wrap included, and as
		frames are delivered and the cache drains.
	**/
	public function testTheAckMapNamesExactlyTheFramesHeld():Void {
		var seed:Int = 12345;
		function next(bound:Int):Int {
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
			return seed % bound;
		}
		for (start in [0, 1000, 0x7FFFFF00, 0x7FFFFFFF, -300, -1, -600]) {
			for (trial in 0...12) {
				var socket = makeSocket();
				socket.__inSequence = start;
				var held:Array<Int> = [];
				for (_ in 0...(1 + next(80))) {
					// Taken into an Int first: a local function is called through
					// Dynamic natively, and `| 0` on what it returns does not compile.
					var offset:Int = next(499);
					var sequence:Seq32 = ((start : Int) + 1 + offset) | 0;
					if (socket.__shouldBufferPacket(sequence)) {
						socket.__cacheFrame(sequence, new ByteArray());
						held.push(sequence);
					}
				}
				Assert.equals(held.length, socket.__inFrameCacheSize);
				Assert.same(heldMap(socket, held), ackMap(socket), 'the map at $start, trial $trial');

				// What arrives in order, and the held frames it lets through,
				// leave the cache as __drainBufferedPackets takes them.
				for (_ in 0...(1 + next(40))) {
					socket.__inSequence++;
					while (socket.__inFrameCache.has(socket.__inSequence)) {
						Assert.isTrue(socket.__inFrameCache.remove(socket.__inSequence));
						held.remove(socket.__inSequence);
						socket.__inFrameCacheSize--;
						socket.__inSequence++;
					}
				}
				Assert.same(heldMap(socket, held), ackMap(socket), 'the map at $start, trial $trial, after delivery');
			}
		}
	}

	/**
		A frame left in the cache behind the next expected (which delivery
		keeps from happening, but an in-order FIN moves on without draining)
		shares a slot of the ring with the frame 511 ahead, and must not make
		the ACK say that one arrived: the peer would give up sending it.
	**/
	public function testAStaleFrameNeverClaimsAnotherArrived():Void {
		var socket = makeSocket();
		socket.__inSequence = 4096;
		socket.__cacheFrame(4096, new ByteArray());
		socket.__cacheFrame(4100, new ByteArray());

		var map = ackMap(socket);
		Assert.same(heldMap(socket, [4096, 4100]), map);
		Assert.equals(1, map.length, "the map ran to the slot the stale frame shares");
	}

	/**
		The receive ring's window moves only as frames are held, so after more
		than 2^31 frames in order with none held, the next held past a gap
		would read as older than the window, and be refused: counted as held,
		never kept. The ring starts again whenever nothing is held.
	**/
	public function testAFrameHeldAfterALongCleanStretchIsKept():Void {
		var socket = makeSocket();
		socket.__cacheFrame(5, new ByteArray());
		Assert.isTrue(socket.__inFrameCache.remove(5));
		socket.__inFrameCacheSize--;

		// 2^31 + 204 frames past 5, wrapped: written out, since a constant
		// that overflows folds to a Float natively.
		socket.__inSequence = -2147483444;
		var sequence:Seq32 = ((socket.__inSequence : Int) + 3) | 0;
		Assert.isTrue(socket.__shouldBufferPacket(sequence));
		socket.__cacheFrame(sequence, new ByteArray());

		Assert.equals(1, socket.__inFrameCacheSize);
		Assert.isTrue(socket.__inFrameCache.has(sequence), "the frame was counted and not kept");
		Assert.same(heldMap(socket, [sequence]), ackMap(socket));
	}

	/** What `__writeAckPayload` wrote, without a delay. **/
	private static function ackMap(socket:ReliableDatagramSocket):Array<Int> {
		var length:Int = socket.__writeAckPayload(false);
		var bytes:haxe.io.Bytes = socket.__sackScratch;
		return [for (i in 0...length) bytes.get(i)];
	}

	/** The map as the walk would build it: from the frames held, as the cache's keys are walked. **/
	private static function heldMap(socket:ReliableDatagramSocket, held:Array<Int>):Array<Int> {
		var map:Array<Int> = [for (_ in 0...ReliableDatagramProtocol.SACK_BYTES) 0];
		var base:Int = ((socket.__inSequence : Int) + 1) | 0;
		var used:Int = 0;
		for (sequence in held) {
			var offset:Int = (sequence - base) | 0;
			if (offset < 0 || offset >= ReliableDatagramProtocol.SACK_BITS) {
				continue;
			}
			map[offset >> 3] |= 1 << (offset & 7);
			if ((offset >> 3) + 1 > used) {
				used = (offset >> 3) + 1;
			}
		}
		return map.slice(0, used);
	}

	/**
		Sessions are filed by host, and a host's entry goes once its last
		session does: counted, rather than asking the host's map whether it is
		empty, which would copy the whole of it on every close.
	**/
	public function testAHostIsForgottenWithItsLastSession():Void {
		if (!ReliableDatagramServerSocket.isSupported) {
			Assert.isFalse(ReliableDatagramServerSocket.isSupported);
			return;
		}
		var server = new ReliableDatagramServerSocket();
		@:privateAccess {
			var session = () -> Type.createEmptyInstance(ReliableDatagramSocket);
			server.__file("10.0.0.1", 1001, session());
			server.__file("10.0.0.1", 1002, session());
			server.__file("10.0.0.1", 1002, session());
			server.__file("10.0.0.2", 2001, session());

			server.__unfile("10.0.0.1", 1001);
			Assert.notNull(server.__sessionAt("10.0.0.1", 1002), "the host's other session went with the first");
			server.__unfile("10.0.0.1", 1002);
			Assert.isNull(server.__sessionAt("10.0.0.1", 1002));
			Assert.isFalse(server.__byHost.exists("10.0.0.1"), "the host outlived its last session");
			Assert.isFalse(server.__byHostCount.exists("10.0.0.1"));
			Assert.notNull(server.__sessionAt("10.0.0.2", 2001), "another host's session went too");

			// Unfiling what is not there changes nothing.
			server.__unfile("10.0.0.1", 1002);
			server.__unfile("10.0.0.2", 9999);
			Assert.notNull(server.__sessionAt("10.0.0.2", 2001));

			// The sessions here were never made, only filed: close would close
			// them, so they go first.
			server.__unfile("10.0.0.2", 2001);
			Assert.isFalse(server.__byHost.exists("10.0.0.2"));
		}
		server.close();
	}
}
