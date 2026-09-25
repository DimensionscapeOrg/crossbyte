package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	What a reliable session gathers and when it sends it.

	Frames produced in one pass of the runtime's loop go out together when the
	pass ends, as one datagram to a peer that said in its CONNECT or HANDSHAKE
	that it takes bundles, and as one datagram each to a peer that did not.
	Acknowledgements are cumulative, so a pass owes one at most, and none when
	a frame going out already carries it.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.core.CrossByte)
class ReliableDatagramCoalescingTest extends utest.Test {
	// ------------------------------------------------------------- sending

	public function testNothingLeavesUntilThePassEnds():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.send(text("one"));
		socket.send(text("two"));
		Assert.equals(0, socket.datagrams.length, "a frame left from inside send()");

		CrossByte.current().pump(0, 0);
		Assert.equals(1, socket.datagrams.length);
		Assert.isTrue(ReliableDatagramProtocol.isBundle(socket.datagrams[0]));
		Assert.same(["PACKET one", "PACKET two"], socket.described());
		socket.close();
	}

	public function testFlushSendsAtOnce():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.send(text("now"));
		socket.flush();
		Assert.equals(1, socket.datagrams.length, "flush() sent nothing");

		CrossByte.current().pump(0, 0);
		Assert.equals(1, socket.datagrams.length, "the pass sent it again");
		socket.close();
	}

	public function testFlushIsNoLongerOnlyForStreams():Void {
		// It threw in DATAGRAM mode when it meant only "turn the stream into
		// frames"; now it also means "send", which every mode has.
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.flush();
		Assert.equals(0, socket.datagrams.length);
		socket.close();
	}

	public function testOneFrameIsSentAsItIs():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.send(text("alone"));
		socket.flush();

		// No magic and no length for a bundle of one: the datagram is the
		// frame, byte for byte what a peer of any version reads.
		var datagram = socket.datagrams[0];
		Assert.isFalse(ReliableDatagramProtocol.isBundle(datagram));
		Assert.equals(ReliableDatagramProtocol.frameSize(5, true), datagram.length);
		Assert.same(["PACKET alone"], socket.described());
		socket.close();
	}

	public function testAPeerThatTakesNoBundlesGetsAFrameADatagram():Void {
		var socket = WireSocket.make(false);
		if (socket == null) return;

		socket.send(text("a"));
		socket.send(text("b"));
		socket.send(text("c"));
		socket.flush();

		Assert.equals(3, socket.datagrams.length);
		for (datagram in socket.datagrams) {
			Assert.isFalse(ReliableDatagramProtocol.isBundle(datagram));
		}
		Assert.same(["PACKET a", "PACKET b", "PACKET c"], socket.described());
		socket.close();
	}

	public function testABundleIsNeverLargerThanAFrameCouldBe():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		// Unreliable, which the congestion window does not pace, so all forty
		// go in the one pass rather than the ten the window opens with.
		var sent:Array<String> = [];
		for (i in 0...40) {
			var message = StringTools.lpad(Std.string(i), "0", 100);
			sent.push("UNRELIABLE " + message);
			socket.send(text(message), 0, 0, DeliveryMode.UNRELIABLE);
		}
		socket.flush();

		Assert.isTrue(socket.datagrams.length > 1, "forty frames of a hundred bytes fitted one bundle");
		Assert.isTrue(socket.datagrams.length < 40, "nothing was bundled");
		for (datagram in socket.datagrams) {
			Assert.isTrue(datagram.length <= ReliableDatagramProtocol.BUNDLE_LIMIT, "a datagram of " + datagram.length);
		}
		Assert.same(sent, socket.described());
		socket.close();
	}

	public function testAFullSizeFrameStillGoesAlone():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.send(text("small"));
		socket.send(filled(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE));
		socket.send(text("after"));
		socket.flush();

		// The large one does not fit beside anything, so it ends the bundle
		// before it and goes out as it is; order is kept throughout.
		Assert.equals(3, socket.datagrams.length);
		Assert.equals(ReliableDatagramProtocol.MAX_FRAME_SIZE, socket.datagrams[1].length);
		var described = socket.described();
		Assert.equals("PACKET small", described[0]);
		Assert.equals("PACKET after", described[2]);
		socket.close();
	}

	public function testFramesOfEverySortShareABundle():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.send(text("kept"));
		socket.send(text("once"), 0, 0, DeliveryMode.UNRELIABLE);
		socket.send(text("latest"), 0, 0, DeliveryMode.sequenced(3));
		socket.flush();

		Assert.equals(1, socket.datagrams.length);
		Assert.same(["PACKET kept", "UNRELIABLE once", "SEQUENCED latest"], socket.described());
		socket.close();
	}

	public function testCloseSendsWhatWasGatheredBeforeTheFin():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.send(text("last words"));
		socket.close();

		Assert.same(["PACKET last words", "FIN "], socket.described());
	}

	public function testAFailedSessionDropsWhatItGathered():Void {
		var socket = WireSocket.make(true);
		if (socket == null) return;

		socket.send(text("never"));
		socket.__dispose(true);
		CrossByte.current().pump(0, 0);
		socket.flush();

		Assert.equals(0, socket.datagrams.length, "a dead session sent what it had gathered");
	}

	// ------------------------------------------------------ acknowledgement

	public function testAPassOwesOneAcknowledgementForEverythingThatArrived():Void {
		var sender = WireSocket.make(true);
		var receiver = WireSocket.make(true);
		if (sender == null || receiver == null) return;
		receiver.__inSequence = sender.__outSequence;

		for (i in 0...5) {
			sender.send(text("m" + i));
		}
		sender.flush();
		for (frame in sender.frames()) {
			receiver.__acceptFrame(frame);
		}
		Assert.equals(0, receiver.datagrams.length, "an acknowledgement went out per packet");

		CrossByte.current().pump(0, 0);
		var frames = receiver.frames();
		Assert.equals(1, frames.length);
		Assert.equals(ReliableDatagramFrameType.ACK, frames[0].type);
		Assert.equals(sender.__outSequence, frames[0].sequence, "the one acknowledgement did not cover all five");
		sender.close();
		receiver.close();
	}

	public function testAnAcknowledgementAFrameAlreadyCarriesIsNotSentAgain():Void {
		var sender = WireSocket.make(true);
		var receiver = WireSocket.make(true);
		if (sender == null || receiver == null) return;
		receiver.__inSequence = sender.__outSequence;

		sender.send(text("question"));
		sender.flush();
		for (frame in sender.frames()) {
			receiver.__acceptFrame(frame);
		}
		// Answered in the same pass: the answer carries the acknowledgement.
		receiver.send(text("answer"));
		receiver.flush();

		var frames = receiver.frames();
		Assert.equals(1, frames.length, "a separate acknowledgement went with a frame that carried it");
		Assert.equals(ReliableDatagramFrameType.PACKET, frames[0].type);
		Assert.equals(receiver.__inSequence, frames[0].ack);
		sender.close();
		receiver.close();
	}

	public function testAnAcknowledgementNewerThanTheOneCarriedIsStillSent():Void {
		var sender = WireSocket.make(true);
		var receiver = WireSocket.make(true);
		if (sender == null || receiver == null) return;
		receiver.__inSequence = sender.__outSequence;

		// The answer goes into the bundle first, carrying what had arrived by
		// then; the packet after it makes that out of date.
		receiver.send(text("early"));
		sender.send(text("later"));
		sender.flush();
		for (frame in sender.frames()) {
			receiver.__acceptFrame(frame);
		}
		receiver.flush();

		Assert.same(["PACKET early", "ACK "], receiver.described());
		var frames = receiver.frames();
		Assert.equals(receiver.__inSequence, frames[1].sequence);
		sender.close();
		receiver.close();
	}

	public function testADuplicateIsStillAcknowledged():Void {
		// The peer resends when an acknowledgement is lost, and only a fresh
		// one stops it -- so a packet already delivered is acknowledged again.
		var sender = WireSocket.make(true);
		var receiver = WireSocket.make(true);
		if (sender == null || receiver == null) return;
		receiver.__inSequence = sender.__outSequence;

		sender.send(text("again"));
		sender.flush();
		var frames = sender.frames();
		receiver.__acceptFrame(frames[0]);
		receiver.flush();
		receiver.datagrams = [];

		receiver.__acceptFrame(frames[0]);
		receiver.flush();
		Assert.same(["ACK "], receiver.described());
		sender.close();
		receiver.close();
	}

	// ------------------------------------------------------------ receiving

	public function testABundleIsTakenFrameByFrame():Void {
		var sender = WireSocket.make(true);
		var receiver = WireSocket.make(true);
		if (sender == null || receiver == null) return;
		receiver.__inSequence = sender.__outSequence;
		var delivered:Array<String> = [];
		receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> delivered.push(e.data.toString()));

		sender.send(text("x"));
		sender.send(text("y"));
		sender.send(text("z"), 0, 0, DeliveryMode.UNRELIABLE);
		sender.flush();
		Assert.equals(1, sender.datagrams.length);

		receiver.__acceptBundle(sender.datagrams[0]);
		Assert.same(["x", "y", "z"], delivered);
		sender.close();
		receiver.close();
	}

	public function testABundleThatRunsPastItsEndKeepsWhatCameBefore():Void {
		var sender = WireSocket.make(true);
		var receiver = WireSocket.make(true);
		if (sender == null || receiver == null) return;
		receiver.__inSequence = sender.__outSequence;
		var delivered:Array<String> = [];
		receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> delivered.push(e.data.toString()));

		sender.send(text("whole"));
		sender.send(text("cut short"));
		sender.flush();
		var bundle = sender.datagrams[0];
		bundle.length = bundle.length - 3;

		receiver.__acceptBundle(bundle);
		Assert.same(["whole"], delivered);
		sender.close();
		receiver.close();
	}

	public function testABundleLargerThanAnySenderMakesIsDropped():Void {
		var sender = WireSocket.make(true);
		var receiver = WireSocket.make(true);
		if (sender == null || receiver == null) return;
		receiver.__inSequence = sender.__outSequence;
		var delivered:Array<String> = [];
		receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> delivered.push(e.data.toString()));

		sender.send(text("real"));
		sender.send(text("also real"));
		sender.flush();

		// Padded past the limit with empty entries, each a length of zero.
		var bundle = sender.datagrams[0];
		var padded = new ByteArray();
		padded.writeBytes(bundle);
		while (padded.length <= ReliableDatagramProtocol.BUNDLE_LIMIT) {
			padded.writeShort(0);
		}
		receiver.__acceptBundle(padded);
		Assert.same([], delivered, "a bundle no sender could make was read");

		// The same entries within the limit are read, the empty ones skipped.
		var within = new ByteArray();
		within.writeBytes(bundle);
		for (_ in 0...10) {
			within.writeShort(0);
		}
		receiver.__acceptBundle(within);
		Assert.same(["real", "also real"], delivered);
		sender.close();
		receiver.close();
	}

	public function testABundleEntryIsReadOnlyWhereItFits():Void {
		var bundle = new ByteArray();
		bundle.length = 8;
		var bytes:Bytes = bundle;
		bytes.set(0, ReliableDatagramProtocol.BUNDLE_MAGIC >> 8);
		bytes.set(1, ReliableDatagramProtocol.BUNDLE_MAGIC & 0xFF);
		bytes.set(2, 0);
		bytes.set(3, 4);

		Assert.equals(4, ReliableDatagramProtocol.bundleEntryLength(bundle, 2), "an entry that ends with the bundle");
		bytes.set(3, 5);
		Assert.equals(-1, ReliableDatagramProtocol.bundleEntryLength(bundle, 2), "an entry one past the end");
		Assert.equals(-1, ReliableDatagramProtocol.bundleEntryLength(bundle, 7), "a length cut in half");
		Assert.equals(-1, ReliableDatagramProtocol.bundleEntryLength(bundle, 8), "nothing left");
		Assert.equals(-1, ReliableDatagramProtocol.bundleEntryLength(bundle, -1));

		Assert.isTrue(ReliableDatagramProtocol.isBundle(bundle));
		Assert.isFalse(ReliableDatagramProtocol.isBundle(ReliableDatagramProtocol.encode(PACKET, 1, text("frame"))));
		bundle.length = 1;
		Assert.isFalse(ReliableDatagramProtocol.isBundle(bundle));
	}

	public function testABundleFromAnAddressWithNoSessionOpensNothing():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			// A CONNECT in a bundle: nothing sends one, since a peer bundles
			// only once it has heard this side, and a session is opened only
			// by a CONNECT alone.
			var connect = ReliableDatagramProtocol.encode(CONNECT, 0);
			var bundle = new ByteArray();
			bundle.writeShort(ReliableDatagramProtocol.BUNDLE_MAGIC);
			bundle.writeShort(connect.length);
			bundle.writeBytes(connect);
			bundle.writeShort(connect.length);
			bundle.writeBytes(connect);
			bundle.position = 0;
			server.__onData(new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "127.0.0.1", 40700, "127.0.0.1", server.localPort, bundle));

			var count = 0;
			for (_ in server.__connections) {
				count++;
			}
			Assert.equals(0, count);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try server.close() catch (_:Dynamic) {}
	}

	// ----------------------------------------------------------- capability

	public function testEveryConnectAndHandshakeSaysItTakesBundles():Void {
		var saying:Array<ReliableDatagramFrameType> = [CONNECT, HANDSHAKE];
		var silent:Array<ReliableDatagramFrameType> = [PACKET, ACK, FIN, UNRELIABLE, SEQUENCED];
		for (type in saying) {
			Assert.isTrue(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(type, 1)).bundles, 'a $type did not say so');
		}
		for (type in silent) {
			Assert.isFalse(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(type, 1)).bundles, 'a $type said so');
		}
	}

	public function testAPeerIsSentBundlesOnlyOnceItHasSaidItTakesThem():Void {
		var socket = WireSocket.make(false);
		if (socket == null) return;

		socket.__acceptFrame(olderPeer(HANDSHAKE, socket.__inSequence));
		Assert.isFalse(socket.__peerTakesBundles, "a HANDSHAKE that said nothing was taken as yes");
		socket.__acceptFrame(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(HANDSHAKE, socket.__inSequence)));
		Assert.isTrue(socket.__peerTakesBundles);

		var dialled = WireSocket.make(false);
		dialled.__acceptFrame(ReliableDatagramProtocol.decode(ReliableDatagramProtocol.encode(CONNECT, 0)));
		Assert.isTrue(dialled.__peerTakesBundles, "a peer that dialled too was not heard");
		socket.close();
		dialled.close();
	}

	public function testAConnectFromAnOlderPeerIsAnsweredWithoutBundles():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			var older = ReliableDatagramProtocol.encode(CONNECT, 0);
			clearBundlesFlag(older);
			server.__onData(new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "127.0.0.1", 40800, "127.0.0.1", server.localPort, older));
			server.__onData(new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "127.0.0.1", 40801, "127.0.0.1", server.localPort,
				ReliableDatagramProtocol.encode(CONNECT, 0)));

			Assert.isFalse(Require.notNull(server.__connections.get("127.0.0.1:40800")).__peerTakesBundles);
			Assert.isTrue(Require.notNull(server.__connections.get("127.0.0.1:40801")).__peerTakesBundles);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try server.close() catch (_:Dynamic) {}
	}

	// ---------------------------------------------------------- a real pair

	public function testABurstCrossesARealSessionInOrderAndBundled():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client = new CountingSocket();
		var accepted:ReliableDatagramSocket = null;
		var delivered:Array<String> = [];
		var datagrams:Int = 0;

		try {
			server.bind(0, "127.0.0.1");
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> {
				accepted = e.socket;
				accepted.addEventListener(DatagramSocketDataEvent.DATA, d -> delivered.push(d.data.toString()));
			});
			server.listen();
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 3.0);
			Require.notNull(accepted, "the pair never connected");

			Assert.isTrue(client.__peerTakesBundles, "the client did not hear that the server takes bundles");
			Assert.isTrue(accepted.__peerTakesBundles, "the server did not hear that the client takes bundles");

			var expected:Array<String> = [for (i in 0...200) "message " + i];
			var before = client.datagramsOut;
			for (message in expected) {
				client.send(text(message));
			}
			pumpUntil(() -> delivered.length >= expected.length, 5.0);
			datagrams = client.datagramsOut - before;

			Assert.same(expected, delivered);
			Assert.isTrue(datagrams < expected.length / 4, '$datagrams datagrams for ${expected.length} messages');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	public function testABurstFromTheServerReachesItsClientBundled():Void {
		// The other direction: an accepted session sends, over the server's
		// transport, and the client reads bundles off its own.
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var delivered:Array<String> = [];

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			client.addEventListener(DatagramSocketDataEvent.DATA, d -> delivered.push(d.data.toString()));
			client.connect("127.0.0.1", server.localPort);
			var session:ReliableDatagramSocket = null;
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> session = e.socket);
			pumpUntil(() -> client.connected && session != null && session.connected, 3.0);
			Require.notNull(session, "the pair never connected");

			var expected:Array<String> = [for (i in 0...200) "reply " + i];
			var bundles = 0;
			client.__transport.addEventListener(DatagramSocketDataEvent.DATA, d -> {
				if (ReliableDatagramProtocol.isBundle(d.data)) {
					bundles++;
				}
			});
			for (message in expected) {
				session.send(text(message));
			}
			pumpUntil(() -> delivered.length >= expected.length, 5.0);

			Assert.same(expected, delivered);
			Assert.isTrue(bundles > 0, "the server sent its client no bundles");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}

	// ------------------------------------------------------------- helpers

	private static function olderPeer(type:ReliableDatagramFrameType, sequence:Int):ReliableDatagramFrame {
		var bytes = ReliableDatagramProtocol.encode(type, sequence);
		clearBundlesFlag(bytes);
		return ReliableDatagramProtocol.decode(bytes);
	}

	private static function clearBundlesFlag(frame:ByteArray):Void {
		var bytes:Bytes = frame;
		bytes.set(2, bytes.get(2) & ~0x10);
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function filled(length:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		return bytes;
	}
}

/** A connected session whose datagrams are kept instead of sent. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class WireSocket extends ReliableDatagramSocket {
	public var datagrams:Array<ByteArray> = [];

	/** One ready to send, or null where this target has no datagrams. **/
	public static function make(takesBundles:Bool):WireSocket {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new WireSocket();
		socket.__connected = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		socket.__peerTakesBundles = takesBundles;
		return socket;
	}

	public function new() {
		super();
	}

	/** Every frame sent, in order, across however many datagrams. **/
	public function frames():Array<ReliableDatagramFrame> {
		var frames:Array<ReliableDatagramFrame> = [];
		for (datagram in datagrams) {
			if (!ReliableDatagramProtocol.isBundle(datagram)) {
				frames.push(ReliableDatagramProtocol.decode(datagram));
				continue;
			}
			var at = ReliableDatagramProtocol.BUNDLE_HEADER_SIZE;
			while (true) {
				var length = ReliableDatagramProtocol.bundleEntryLength(datagram, at);
				if (length < 0) {
					break;
				}
				frames.push(ReliableDatagramProtocol.decodeRange(datagram, at + ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE, length));
				at += ReliableDatagramProtocol.BUNDLE_ENTRY_SIZE + length;
			}
		}
		return frames;
	}

	/** Each frame as its type and its payload as text. **/
	public function described():Array<String> {
		return [for (frame in frames()) typeName(frame.type) + " " + frame.payload.toString()];
	}

	override private function __sendDatagram(offset:Int, length:Int):Bool {
		var copy = new ByteArray();
		copy.length = length;
		(copy : Bytes).blit(0, __scratch, offset, length);
		datagrams.push(copy);
		return true;
	}

	private static function typeName(type:ReliableDatagramFrameType):String {
		return switch (type) {
			case CONNECT: "CONNECT";
			case HANDSHAKE: "HANDSHAKE";
			case PACKET: "PACKET";
			case ACK: "ACK";
			case FIN: "FIN";
			case UNRELIABLE: "UNRELIABLE";
			case SEQUENCED: "SEQUENCED";
			case _: "?";
		}
	}
}

/** A real session that counts the datagrams it sends. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class CountingSocket extends ReliableDatagramSocket {
	public var datagramsOut:Int = 0;

	public function new() {
		super();
	}

	override private function __sendDatagram(offset:Int, length:Int):Bool {
		datagramsOut++;
		return super.__sendDatagram(offset, length);
	}
}
