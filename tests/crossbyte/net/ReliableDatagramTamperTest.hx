package crossbyte.net;

import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.SessionCipher;
import haxe.io.Bytes;
import utest.Assert;

/**
	An encrypted session attacked through what it is sent: two real
	sessions whose sealed datagrams go through memory, so a case can change,
	repeat, hold back or forge any of them: every byte position of a
	session's datagram, header and body, changed; replays; datagrams older
	than the window; truncated ones, ones sealed under another session's
	keys, and frames in the clear. Each is dropped, counted, and leaves the
	session as it was.

	No network, so it runs on Node too, where Node's `crypto` opens the
	large datagrams and this package's ChaCha20-Poly1305 the small ones.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.DatagramSocket)
class ReliableDatagramTamperTest extends utest.Test {
	/**
		Messages of every kind, both ways, delivered out of order, each
		datagram twice, and one lost and sent again: every message arrives
		once and in order, and only the repeated copies are counted, as
		replays.
	**/
	public function testASealedLinkCarriesEverythingOnceAndInOrder():Void {
		var link = SealedLink.make();
		if (link == null) return;
		// Within the first congestion window, ten frames.
		for (i in 0...6) {
			link.a.send(text("m" + i));
		}
		link.a.send(numbered(3000));
		link.a.send(text("loose"), 0, 0, DeliveryMode.UNRELIABLE);
		var sent = link.a.take();
		Assert.isTrue(sent.length > 1, "it all went in " + sent.length + " datagrams");
		// The first lost; the rest reversed, each twice.
		var lost = sent.shift();
		sent.reverse();
		for (d in sent) {
			link.toB(d);
			link.toB(d);
		}
		Assert.same([], link.bTexts().filter(m -> m.charAt(0) == "m"), "delivered past the lost datagram");
		// The loss is noticed and the datagram sent again; it is sealed under
		// a packet number of its own.
		link.toA(link.b.take());
		link.a.__outFrameCache.get(link.a.__windowBase).deadline = 0;
		link.a.__checkRetransmits();
		var again = link.a.take();
		Assert.isTrue(again.length > 0, "nothing was sent again");
		for (d in again) {
			Assert.notEquals(lost.toHex(), d.toHex(), "a frame sent again went in the same datagram, under the same nonce");
			link.toB(d);
		}
		var expected = [for (i in 0...6) "m" + i];
		expected.push("numbered:3000");
		Assert.same(expected, link.bTexts().filter(m -> m != "loose"));
		Assert.equals(1, link.bTexts().filter(m -> m == "loose").length, "the unreliable message, sent once, arrived " + link.bTexts().length);
		Assert.equals(sent.length * 1.0, link.b.replayedDatagrams, "each repeated copy should be one replay");
		Assert.equals(0.0, link.b.unauthenticatedDatagrams);

		// And back the other way, large enough for Node to use its crypto.
		link.b.send(numbered(1100));
		for (d in link.b.take()) {
			link.toA(d);
		}
		Assert.same(["numbered:1100"], link.aTexts());
		link.close();
	}

	/**
		Every byte of a session's sealed datagram changed in turn, two ways
		(the type byte and the packet number, which are authenticated as
		associated data, and every byte of ciphertext and tag): nothing is
		delivered, every copy is dropped and counted, and the original still
		opens after, once.
	**/
	public function testEveryBytePositionIsAuthenticated():Void {
		var link = SealedLink.make();
		if (link == null) return;
		link.a.send(text("the message being tampered with"), 0, 0, DeliveryMode.UNRELIABLE);
		link.a.send(text("and a reliable one"));
		var datagrams = link.a.take();
		Assert.equals(1, datagrams.length, "bundled into one datagram");
		var original = datagrams[0];
		var tries:Int = 0;
		for (at in 0...original.length) {
			for (bit in [0x01, 0x80]) {
				var copy = Bytes.alloc(original.length);
				copy.blit(0, original, 0, original.length);
				copy.set(at, copy.get(at) ^ bit);
				link.toB(copy);
				tries++;
			}
		}
		Assert.same([], link.bTexts(), "a changed datagram was delivered");
		Assert.equals(tries * 1.0, link.b.unauthenticatedDatagrams + link.b.lateDatagrams + link.b.replayedDatagrams,
			"a changed datagram was neither dropped nor counted");
		Assert.isTrue(link.b.connected, "the session ended");
		link.toB(original);
		Assert.same(["the message being tampered with", "and a reliable one"], link.bTexts());

		// An acknowledgement changed in each byte releases nothing.
		var acks = link.b.take();
		Assert.isTrue(acks.length > 0);
		var outstanding:Int = link.a.__outSequence - link.a.__windowBase;
		Assert.isTrue(outstanding > 0);
		for (at in 0...acks[0].length) {
			var copy = Bytes.alloc(acks[0].length);
			copy.blit(0, acks[0], 0, acks[0].length);
			copy.set(at, copy.get(at) ^ 0x10);
			link.toA(copy);
		}
		Assert.equals(outstanding, link.a.__outSequence - link.a.__windowBase, "a changed acknowledgement released a frame");
		link.toA(acks[0]);
		Assert.equals(0, link.a.__outSequence - link.a.__windowBase, "the real acknowledgement released nothing");
		link.close();
	}

	/**
		A datagram sent again by someone who recorded it: dropped and counted
		as a replay while its packet number is in the window, and as late
		once the window has passed it, delivered once either way.
	**/
	public function testReplaysAreDroppedAndCounted():Void {
		var link = SealedLink.make();
		if (link == null) return;
		link.a.send(text("once"), 0, 0, DeliveryMode.UNRELIABLE);
		var recorded = link.a.take()[0];
		link.toB(recorded);
		link.toB(recorded);
		link.toB(recorded);
		Assert.same(["once"], link.bTexts());
		Assert.equals(2.0, link.b.replayedDatagrams);

		// 1,100 more, and the recorded one is older than the window.
		for (i in 0...1100) {
			link.a.send(text("x"), 0, 0, DeliveryMode.UNRELIABLE);
			link.a.flush();
		}
		var later = link.a.take();
		link.toB(later[later.length - 1]);
		link.toB(recorded);
		Assert.equals(1.0, link.b.lateDatagrams, "a datagram older than the window was not counted late");
		Assert.equals(2, link.bTexts().length, "a replay was delivered");
		// One within the window, never seen, still opens.
		link.toB(later[later.length - 500]);
		Assert.equals(3, link.bTexts().length);
		link.close();
	}

	/**
		What is not a sealed datagram of this session's (one cut short, one
		sealed under another session's keys, a hello with another random, and
		frames in the clear) is dropped and counted, nothing is delivered, and
		the session goes on.
	**/
	public function testWhatIsNotThisSessionsIsDropped():Void {
		var link = SealedLink.make();
		var other = SealedLink.make(77);
		if (link == null || other == null) return;
		link.a.send(text("real"), 0, 0, DeliveryMode.UNRELIABLE);
		var real = link.a.take()[0];

		link.toB(real.sub(0, 10));
		link.toB(real.sub(0, SessionCipher.OVERHEAD));
		other.a.send(text("someone else's"), 0, 0, DeliveryMode.UNRELIABLE);
		link.toB(other.a.take()[0]);
		other.a.__peerHasKeys = false;
		other.a.send(text("a hello of someone else's"), 0, 0, DeliveryMode.UNRELIABLE);
		link.toB(other.a.take()[0]);
		var clear = ReliableDatagramProtocol.encode(UNRELIABLE, 0, text("in the clear"));
		var clearBytes = Bytes.alloc(clear.length);
		clearBytes.blit(0, clear, 0, clear.length);
		link.toB(clearBytes);
		var plainBundle = Bytes.alloc(4);
		plainBundle.set(0, 0xCB);
		plainBundle.set(1, 0xDB);
		link.toB(plainBundle);

		Assert.same([], link.bTexts());
		Assert.equals(6.0, link.b.unauthenticatedDatagrams);
		link.toB(real);
		Assert.same(["real"], link.bTexts());
		Assert.isTrue(link.b.connected);
		link.close();
		other.close();
	}

	static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	static function numbered(length:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		for (i in 0...length) {
			(bytes : Bytes).set(i, i & 255);
		}
		bytes.position = 0;
		return bytes;
	}
}

/** A session whose datagrams are recorded, sealed, as they leave, instead of sent. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class SealedEnd extends ReliableDatagramSocket {
	var __sent:Array<Bytes> = [];

	public var got:Array<String> = [];

	public function new() {
		super();
		addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var data = e.data;
			var whole:Bool = data.length > 100;
			if (whole) {
				for (i in 0...data.length) {
					if ((data : Bytes).get(i) != (i & 255)) {
						whole = false;
						break;
					}
				}
				got.push(whole ? "numbered:" + data.length : "garbled:" + data.length);
			} else {
				got.push(data.readUTFBytes(data.length));
			}
		});
	}

	public function take():Array<Bytes> {
		__sendBundle();
		var sent = __sent;
		__sent = [];
		return sent;
	}

	override private function __sendBytes(buffer:ByteArray, offset:Int, length:Int):Bool {
		var copy = Bytes.alloc(length);
		copy.blit(0, buffer, offset, length);
		__sent.push(copy);
		__sentSinceKeepAlive = true;
		return true;
	}
}

/**
	Two encrypted sessions that believe they are connected to each other at
	127.0.0.1:9, with keys derived as a handshake would have left them;
	each datagram is handed to the other through its transport's own
	delivery, in the socket's own payload.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.DatagramSocket)
private class SealedLink {
	public var a:SealedEnd;
	public var b:SealedEnd;

	public static function make(seed:Int = 1):Null<SealedLink> {
		if (!ReliableDatagramSocket.isEncryptionSupported) {
			Assert.isFalse(ReliableDatagramSocket.isEncryptionSupported);
			return null;
		}
		return new SealedLink(seed);
	}

	function new(seed:Int) {
		a = new SealedEnd();
		b = new SealedEnd();
		var key = Bytes.alloc(32);
		for (i in 0...32) {
			key.set(i, (i * 13 + seed) & 255);
		}
		a.__cipher = new SessionCipher(key, fill(seed + 1));
		b.__cipher = new SessionCipher(key, fill(seed + 2));
		a.__cipher.derive(b.__cipher.localRandom);
		b.__cipher.derive(a.__cipher.localRandom);
		for (end in [a, b]) {
			end.__connected = true;
			end.__peerConfirmed = true;
			end.__peerHasKeys = true;
			end.__peerTakesBundles = true;
			end.__remoteAddress = "127.0.0.1";
			end.__remotePort = 9;
			// Every acknowledgement at once, rather than held for something
			// to ride on.
			end.ackDelay = 0;
		}
		a.__inSequence = b.__outSequence;
		b.__inSequence = a.__outSequence;
	}

	static function fill(seed:Int):Bytes {
		var out = Bytes.alloc(16);
		for (i in 0...16) {
			out.set(i, (i * 7 + seed * 3) & 255);
		}
		return out;
	}

	public function toB(datagram:Bytes):Void {
		deliver(b, datagram);
	}

	public function toA(datagrams:Dynamic):Void {
		if (Std.isOfType(datagrams, Array)) {
			for (d in (datagrams : Array<Bytes>)) {
				deliver(a, d);
			}
		} else {
			deliver(a, datagrams);
		}
	}

	function deliver(to:SealedEnd, datagram:Bytes):Void {
		var transport = to.__transport;
		var pooled:Bool = transport.__pooledArrival();
		var payload:ByteArray = transport.__payloadOf(datagram, 0, datagram.length, pooled);
		transport.__deliver(payload, pooled, "127.0.0.1", 9, "127.0.0.1", 1);
	}

	public function aTexts():Array<String> {
		return a.got;
	}

	public function bTexts():Array<String> {
		return b.got;
	}

	public function close():Void {
		try a.__dispose(false) catch (_:Dynamic) {}
		try b.__dispose(false) catch (_:Dynamic) {}
	}
}
