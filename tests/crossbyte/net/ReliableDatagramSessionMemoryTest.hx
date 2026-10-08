package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.io.Bytes;
import utest.Assert;

/**
	What a reliable UDP session holds while it is idle, and what it makes
	only when it needs it: the ring that holds frames arriving past a gap,
	made small on the first such frame, grown as far as the frames reach and
	let go once the session is quiet and holds none; and the buffer it
	writes what it sends into, grown to what it sends. Memory per idle
	session is what a server with ten thousand players holds for them all.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramSessionMemoryTest extends utest.Test {
	public function testAnIdleSessionHoldsNoRingAndASmallBuffer():Void {
		var session = MemoryWire.make();
		if (session == null) return;
		Assert.isNull(session.__inFrameCache, "a session that has lost nothing made a ring for frames past a gap");
		Assert.isNull(session.__scratch, "a session that has sent nothing made a buffer to send from");
		// A keepalive and an acknowledgement: a small buffer.
		session.__sendHandshake();
		session.__acceptFrame(packet(1000, "a"));
		session.flush();
		Assert.notNull(session.__scratch);
		Assert.isTrue(session.__scratch.length <= 128, 'a session sending only small frames holds ${session.__scratch.length} bytes to send from');
		Assert.isNull(session.__inFrameCache, "frames arriving in order made a ring");
		session.abort();
	}

	public function testTheRingIsMadeSmallAndGrowsAsFarAsTheFramesReach():Void {
		var session = MemoryWire.make();
		if (session == null) return;
		// 1000 is missing: two past it, held.
		session.__acceptFrame(packet(1001, "b"));
		session.__acceptFrame(packet(1003, "d"));
		var ring = session.__inFrameCache;
		Assert.notNull(ring);
		// Sixteen slots, where every session held 512.
		Assert.equals(16, ring.capacity);

		// One 300 past the gap: the ring grows to reach it, the two held
		// frames moved over, and the map names all three.
		session.__acceptFrame(packet(1300, "far"));
		Assert.equals(512, session.__inFrameCache.capacity);
		Assert.equals(3, session.__inFrameCacheSize);
		var frames = session.take();
		var map = frames[frames.length - 1].payload;
		Assert.equals(ReliableDatagramFrameType.ACK, frames[frames.length - 1].type);
		Assert.isTrue(bit(map, 0) && bit(map, 2) && bit(map, 299), "the map lost a frame the ring held before it grew");

		// The gap fills: all four delivered, in order.
		session.__acceptFrame(packet(1000, "a"));
		Assert.same(["a", "b"], [for (d in session.delivered) d]);
		Assert.equals(2, session.__inFrameCacheSize);
		session.abort();
	}

	public function testAQuietSessionLetsAnEmptyRingGo():Void {
		var session = MemoryWire.make();
		if (session == null) return;
		session.__acceptFrame(packet(1001, "b"));
		Assert.notNull(session.__inFrameCache);
		// Still holding: kept.
		session.__onKeepAlive();
		Assert.notNull(session.__inFrameCache, "a ring holding a frame was let go");
		session.__acceptFrame(packet(1000, "a"));
		Assert.equals(0, session.__inFrameCacheSize);
		session.__onKeepAlive();
		Assert.isNull(session.__inFrameCache, "a quiet session kept an empty ring");
		// And made again when a frame next arrives past a gap.
		session.__acceptFrame(packet(1003, "d"));
		Assert.notNull(session.__inFrameCache);
		Assert.equals(1, session.__inFrameCacheSize);
		session.abort();
	}

	public function testTheBufferGrowsToTheLargestBundleAndKeepsWhatItHolds():Void {
		var session = MemoryWire.make();
		if (session == null) return;
		session.__peerTakesBundles = true;
		var small = new ByteArray();
		small.length = 40;
		session.send(small);
		var before:Int = session.__scratch.length;
		// A large one in the same pass: the buffer grows under the bundle.
		var big = new ByteArray();
		big.length = 1000;
		for (i in 0...1000) {
			(big : Bytes).set(i, i & 0xFF);
		}
		session.send(big);
		Assert.isTrue(session.__scratch.length > before);
		var sent = session.takeDatagrams();
		Assert.equals(1, sent.length, "the two did not go as one bundle");
		Assert.isTrue(ReliableDatagramProtocol.isBundle(sent[0]));
		session.abort();
	}

	/**
		A session that sent a large bundle once and has been quiet since,
		nothing sent for a whole keepalive period, lets the buffer it grew
		for it go; the keepalive it then sends makes a small one.
	**/
	public function testAQuietSessionLetsAGrownBufferGo():Void {
		var session = MemoryWire.make();
		if (session == null) return;
		var big = new ByteArray();
		big.length = 1000;
		session.send(big);
		session.takeDatagrams();
		Assert.isTrue(session.__scratch.length > 1000);

		// A check after the send: it was not quiet.
		session.__onKeepAlive();
		Assert.isTrue(session.__scratch.length > 1000, "a session that had just sent let its buffer go");
		// A whole period with nothing sent.
		session.__onKeepAlive();
		Assert.notNull(session.__scratch, "the keepalive made no buffer to send from");
		Assert.isTrue(session.__scratch.length <= 128, 'a quiet session kept ${session.__scratch.length} bytes to send from');
		session.abort();
	}

	// ------------------------------------------------------------- helpers

	private static function packet(sequence:Int, value:String):ReliableDatagramFrame {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return new ReliableDatagramFrame(PACKET, sequence, bytes, false, 7000);
	}

	private static function bit(map:ByteArray, index:Int):Bool {
		var at = index >> 3;
		return at < map.length && ((map : Bytes).get(at) & (1 << (index & 7))) != 0;
	}
}

/** A connected session whose datagrams are recorded instead of sent; sequences pinned at 1000. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class MemoryWire extends ReliableDatagramSocket {
	public var delivered:Array<String> = [];

	private var __datagrams:Array<ByteArray> = [];

	public static function make():MemoryWire {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new MemoryWire();
		socket.__connected = true;
		socket.__peerConfirmed = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		socket.__outSequence = 1000;
		socket.__windowBase = 1000;
		socket.__firstSequence = 1000;
		socket.__inSequence = 1000;
		socket.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, e -> socket.delivered.push(e.data.toString()));
		return socket;
	}

	public function new() {
		super();
	}

	/** The frames of every datagram sent since the last call, and what the pass owes. **/
	public function take():Array<ReliableDatagramFrame> {
		var frames:Array<ReliableDatagramFrame> = [];
		for (datagram in takeDatagrams()) {
			if (ReliableDatagramProtocol.isBundle(datagram)) {
				var at = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
				while (true) {
					var length = ReliableDatagramProtocol.bundleEntryLength(datagram, at);
					if (length < 0) {
						break;
					}
					frames.push(ReliableDatagramProtocol.decodeRange(datagram, at + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE, length));
					at += ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE + length;
				}
			} else {
				frames.push(ReliableDatagramProtocol.decode(datagram));
			}
		}
		return frames;
	}

	public function takeDatagrams():Array<ByteArray> {
		__sendBundle();
		var sent = __datagrams;
		__datagrams = [];
		return sent;
	}

	override private function __sendDatagram(offset:Int, length:Int):Bool {
		// As a datagram sent through the transport says.
		__sentSinceKeepAlive = true;
		var copy = new ByteArray();
		copy.length = length;
		(copy : Bytes).blit(0, __scratch, offset, length);
		__datagrams.push(copy);
		return true;
	}
}
