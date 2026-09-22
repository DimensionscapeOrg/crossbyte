package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.OutstandingFrame;
import haxe.ds.IntMap;
import utest.Assert;

/**
	Exercises the pure out-of-order delivery-window logic added to
	`ReliableDatagramSocket` as part of the RUDP hardening pass. These cases
	drive the buffering decision and the cache cap directly, without any live
	socket I/O, so they run under the eval/interp target.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
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

		// Seeds must be well-distributed across the full unsigned 32-bit space.
		// Verify that repeated seeds are not all clustered in the low 31 bits,
		// which was the defect with the old Std.random(MAX_INT_32) seeding.
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
		The timeout is measured, where it used to be assumed.

		`RETRANSMIT_INTERVAL` was a flat 3 seconds, which is wrong in both
		directions. On a local path it made a lost frame wait three seconds
		for nothing; on a path slower than three seconds it declared loss that
		had not happened and sent the frame again, which is how a congested
		link is made worse by the thing meant to be reliable over it.
	**/
	public function testTheRetransmitTimeoutIsMeasuredNotAssumed():Void {
		var socket = makeSender();

		// A fast path: the timeout should come down near the round trip,
		// nowhere near the three seconds it used to be.
		for (_ in 0...20) {
			socket.__sampleRoundTrip(0.010);
		}

		Assert.isTrue(socket.__rto < 0.5, "a 10ms path still waits " + socket.__rto + "s before resending");
		Assert.isTrue(socket.__rto >= ReliableDatagramSocket.MIN_RTO, "the timeout went below its floor: " + socket.__rto);

		// A slow path: it should go up, rather than resending into it.
		var slow = makeSender();

		for (_ in 0...20) {
			slow.__sampleRoundTrip(1.2);
		}

		Assert.isTrue(slow.__rto > 1.0, "a 1.2s path resends after only " + slow.__rto + "s");
		Assert.isTrue(slow.__rto <= ReliableDatagramSocket.MAX_RTO, "the timeout went past its ceiling: " + slow.__rto);
	}

	/**
		The window opens on delivery and halves on loss.

		It was a constant 500 frames that took no notice of whether any of it
		was arriving. A sender that keeps 500 frames in flight down a path
		already dropping them makes the drops worse and does not stop, which
		is how one bad path costs a server the bandwidth of many good ones.
	**/
	public function testTheWindowOpensOnDeliveryAndHalvesOnLoss():Void {
		var socket = makeSender();
		var start:Float = socket.__congestionWindow;

		socket.__openWindow();
		Assert.isTrue(socket.__congestionWindow > start, "an acknowledged frame did not open the window");

		var open:Float = socket.__congestionWindow;
		var timeout:Float = socket.__rto;
		socket.__closeWindow();

		Assert.isTrue(socket.__congestionWindow <= open / 2 + 0.001,
			"loss left the window at " + socket.__congestionWindow + " against " + open);
		Assert.isTrue(socket.__rto > timeout, "loss did not back the timeout off: still " + socket.__rto);

		// And it never collapses to nothing, or the session cannot recover.
		for (_ in 0...40) {
			socket.__closeWindow();
		}

		Assert.isTrue(socket.__congestionWindow >= ReliableDatagramSocket.MIN_WINDOW,
			"repeated loss closed the window to " + socket.__congestionWindow);
	}

	/**
		The window is what bounds what is in flight, not a constant.

		`__windowExceeded` used to compare against `DELIVERY_WINDOW`, so the
		send side was bounded by the receiver's buffer and by nothing about
		the path between them.
	**/
	public function testWhatIsInFlightIsBoundedByTheWindow():Void {
		var socket = makeSender();
		socket.__congestionWindow = 4;
		socket.__windowBase = 100;
		socket.__outSequence = 103;

		Assert.isFalse(socket.__windowExceeded(), "three frames in flight against a window of four is not full");

		socket.__outSequence = 104;
		Assert.isTrue(socket.__windowExceeded(), "four frames in flight against a window of four is full");
	}

	/**
		What waits for the window is bounded and says so.

		Before the window could close this queue could not grow, because the
		window never closed. Now that it does, an application writing faster
		than the path will carry has to be told rather than have the queue
		grow until the process dies. Same bound and policies as `Socket`.
	**/
	public function testTheSendQueueIsBounded():Void {
		var socket = makeSender();
		// Nothing may go out, so everything written waits.
		socket.__congestionWindow = 0;
		socket.maxOutputBufferSize = 4096;
		socket.outputOverflowPolicy = THROW;

		var refused:Bool = false;

		try {
			for (_ in 0...64) {
				socket.__queuePacket(payloadOf(oneKilobyte()));
			}
		} catch (e:Dynamic) {
			refused = true;
		}

		Assert.isTrue(refused, "the queue passed " + socket.maxOutputBufferSize + " bytes without a word");
		Assert.isTrue(socket.bufferedAmount > 0, "nothing was reported as waiting");
	}

	/**
		Only the oldest frame is resent, and only once its own time is up.

		There was no test for retransmission of a data frame at all, which is
		how the old shape kept a repeating timer per packet without anyone
		noticing what that costs a server. What replaced it is one clock for
		the session comparing against each frame's deadline, so the deadline
		is what needs to be right.
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
		socket.__outFrameCache = new IntMap();
		socket.__outgoingQueue = [];
		socket.__queueAt = 0;
		socket.__queuedBytes = 0;
		socket.__outSequence = 0;
		socket.__windowBase = 0;
		socket.__congestionWindow = ReliableDatagramSocket.INITIAL_WINDOW;
		socket.__slowStartThreshold = ReliableDatagramSocket.DELIVERY_WINDOW;
		socket.__smoothedRtt = -1;
		socket.__rttVariation = 0;
		socket.__rto = ReliableDatagramSocket.INITIAL_RTO;
		socket.maxOutputBufferSize = 0;
		socket.outputOverflowPolicy = CLOSE;
		return socket;
	}

	private static function makeSocket():ReliableDatagramSocket {
		var socket:ReliableDatagramSocket = Type.createEmptyInstance(ReliableDatagramSocket);
		socket.__inFrameCache = new IntMap();
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
}
