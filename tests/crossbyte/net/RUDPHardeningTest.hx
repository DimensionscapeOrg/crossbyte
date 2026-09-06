package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.io.ByteArray;
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
