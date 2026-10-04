package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	"Copy it to keep it" in reliable UDP: everything a session or a server
	keeps past the call that handed it a datagram is a copy.

	Every datagram goes in through the transport's own delivery, as the
	socket hands one over, and through one buffer filled again for each,
	which is what a socket that reuses its payload does. So a session that
	kept any of a datagram by reference, a frame held past a gap, a
	fragment, a CONNECT's payload, reads the wrong bytes here in every
	mode, not only under `-D crossbyte_check_events`, where the buffer is
	also killed between datagrams.

	No network: the sender's frames are recorded as it sends them, and the
	order they arrive in is each case's.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.DatagramSocket)
class ReliableDatagramArrivalTest extends utest.Test {
	public function testFramesHeldPastAGapKeepTheirOwnBytes():Void {
		var link = Link.make();
		if (link == null) return;

		link.sender.send(text("one"));
		link.sender.send(text("two"));
		link.sender.send(text("three"));
		var sent = link.sender.take();

		// The last two wait for the first, which arrives last of all.
		link.deliver([sent[2], sent[1], sent[0]]);

		Assert.same(["one", "two", "three"], link.texts(), "frames held past the gap were delivered as other datagrams' bytes");
		link.close();
	}

	public function testFragmentsArrivingInOrderMakeTheMessageThatWasSent():Void {
		var link = Link.make();
		if (link == null) return;

		link.sender.send(numbered(3000));
		link.deliver(link.sender.take());

		Assert.equals(1, link.received.length);
		Assert.equals(-1, wrongByte(link.received[0], 3000), "a fragment was joined as another datagram's bytes");
		link.close();
	}

	public function testFragmentsArrivingOutOfOrderMakeTheMessageThatWasSent():Void {
		var link = Link.make();
		if (link == null) return;

		link.sender.send(numbered(3000));
		link.sender.send(text("after"));
		var sent = link.sender.take();
		// The middle fragment and the message after it wait past a gap, and
		// then the first fragment fills it.
		link.deliver([sent[3], sent[1], sent[2], sent[0]]);

		Assert.equals(2, link.received.length);
		if (link.received.length == 2) {
			Assert.equals(-1, wrongByte(link.received[0], 3000), "a held fragment was joined as another datagram's bytes");
			Assert.equals("after", link.received[1].toString());
		}
		link.close();
	}

	public function testFramesBundledInOneDatagramAreEachTheirOwn():Void {
		var link = Link.make();
		if (link == null) return;

		link.sender.send(numbered(2000));
		link.sender.send(text("small"));
		link.sender.send(text("last"));
		var sent = link.sender.take();
		// The two small ones bundled, and the second fragment, all held past
		// the gap the first fragment leaves, a full frame, which no bundle
		// has room for, until it arrives, last.
		link.deliver([bundle([sent[2], sent[3]]), bundle([sent[1]]), sent[0]]);

		Assert.equals(3, link.received.length);
		if (link.received.length == 3) {
			Assert.equals(-1, wrongByte(link.received[0], 2000));
			Assert.equals("small", link.received[1].toString());
			Assert.equals("last", link.received[2].toString());
		}
		link.close();
	}

	public function testUnreliableAndSequencedMessagesAreTheirOwnWhileTheyAreHandled():Void {
		var link = Link.make();
		if (link == null) return;

		link.sender.send(text("plain"), 0, 0, DeliveryMode.UNRELIABLE);
		link.sender.send(text("latest"), 0, 0, DeliveryMode.sequenced(3));
		link.deliver(link.sender.take());

		Assert.same(["plain", "latest"], link.texts());
		link.close();
	}

	public function testAnEchoSentAgainLaterCarriesTheBytesThatArrived():Void {
		var link = Link.make();
		if (link == null) return;

		// The commonest thing a server does: send what arrived straight back,
		// from inside the listener. The session keeps that until it is
		// acknowledged, so it must have kept a copy, and not the event's
		// bytes, which belong to the next datagram by the time it is sent
		// again.
		link.receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> link.receiver.send(e.data));
		link.sender.send(numbered(500));
		link.deliver(link.sender.take());
		var echoed = [for (frame in link.receiver.takeFrames()) if (frame.type == PACKET) frame];
		Assert.equals(1, echoed.length, "the listener's echo was not sent");

		// More arrives, through the same buffer, and the echo goes unanswered.
		link.sender.send(text("overwrite every byte of the first datagram, and some, with these"));
		link.deliver(link.sender.take());
		link.receiver.take();

		// Its timeout passes: it goes again, from what the session kept.
		var outstanding = link.receiver.__outFrameCache.get(link.receiver.__windowBase);
		Require.notNull(outstanding, "nothing was waiting to be sent again");
		outstanding.deadline = 0;
		link.receiver.__checkRetransmits();
		var resent = [for (frame in link.receiver.takeFrames()) if (frame.type == PACKET) frame];

		Assert.equals(1, resent.length, "the echo was not sent again");
		if (resent.length == 1) {
			Assert.isTrue(resent[0].resend);
			Assert.equals(-1, wrongByte(resent[0].payload, 500), "the echo was sent again as bytes that arrived after it");
		}
		link.close();
	}

	public function testAStreamKeepsWhatArrivedUntilItIsRead():Void {
		var link = Link.make(STREAM);
		if (link == null) return;

		var loaded:Array<Int> = [];
		var kept:ProgressEvent = null;
		link.receiver.addEventListener(ProgressEvent.SOCKET_DATA, e -> {
			loaded.push(e.bytesLoaded);
			kept = e;
		});

		link.sender.writeUTFBytes("held ");
		link.sender.flush();
		link.sender.writeUTFBytes("in order");
		link.sender.flush();
		var sent = link.sender.take();
		link.deliver([sent[1], sent[0]]);

		Assert.same([5, 8], loaded);
		Assert.equals("held in order", link.receiver.readUTFBytes(link.receiver.bytesAvailable));
		#if crossbyte_check_events
		Assert.isTrue(kept.bytesLoaded == (cast -1 : UInt), "a SOCKET_DATA event kept past its call still said what arrived");
		#end
		link.close();
	}

	public function testANetConnectionsMessageIsItsOwnToKeep():Void {
		var link = Link.make();
		if (link == null) return;

		// What onData is handed is the application's, as an RPC argument is:
		// kept, and read only once more has arrived.
		var connection:NetConnection = NetConnection.fromReliableDatagramSocket(link.receiver);
		var kept:Array<ByteArrayInput> = [];
		connection.onData = input -> kept.push(input);
		connection.readEnabled = true;

		link.sender.send(text("first"));
		link.sender.send(numbered(2500));
		link.sender.send(text("third"));
		link.deliver(link.sender.take());

		Assert.equals(3, kept.length);
		if (kept.length == 3) {
			Assert.equals("first", (cast kept[0] : ByteArray).toString());
			Assert.equals(-1, wrongByte(cast kept[1], 2500));
			Assert.equals("third", (cast kept[2] : ByteArray).toString());
		}
		connection.readEnabled = false;
		link.close();
	}

	public function testAPeersConnectPayloadIsKeptAsItCame():Void {
		var link = Link.make(DATAGRAM, false);
		if (link == null) return;

		// Two peers dialling each other, as hole punching has them: the one
		// still connecting is sent its peer's CONNECT, and keeps the payload.
		var connect = ReliableDatagramProtocol.encode(CONNECT, 1234, text("peer token"));
		link.deliver([connect]);
		link.deliver([ReliableDatagramProtocol.encode(UNRELIABLE, 0, text("something else entirely, and longer"))]);

		Require.notNull(link.receiver.connectPayload, "the peer's CONNECT payload was not kept");
		Assert.equals("peer token", link.receiver.connectPayload.toString(), "the CONNECT payload was kept as a later datagram's bytes");
		link.close();
	}

	public function testAnAcceptedSessionKeepsItsConnectPayloadAndAdmitSawIt():Void {
		if (!ReliableDatagramServerSocket.isSupported) {
			Assert.isFalse(ReliableDatagramServerSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var admitted:Array<String> = [];
		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			// Read during the call, which is when the payload is valid.
			server.admit = (address, port, payload) -> {
				admitted.push(payload.readUTFBytes(payload.length));
				return true;
			};

			var buffer = new ByteArray();
			deliverThrough(server.__socket, buffer, ReliableDatagramProtocol.encode(CONNECT, 77, text("join token A")), 40001);
			deliverThrough(server.__socket, buffer, ReliableDatagramProtocol.encode(CONNECT, 78, text("a longer join token, B")), 40002);

			Assert.same(["join token A", "a longer join token, B"], admitted);
			var first = server.__sessionAt("127.0.0.1", 40001);
			var second = server.__sessionAt("127.0.0.1", 40002);
			Require.notNull(first, "the first CONNECT opened no session");
			Require.notNull(second, "the second CONNECT opened no session");
			Assert.equals("join token A", first.connectPayload.toString(), "a pending session's connectPayload became a later datagram");
			Assert.equals("a longer join token, B", second.connectPayload.toString());
			Assert.equals(0, first.connectPayload.position);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try server.close() catch (_:Dynamic) {}
	}

	public function testAPayloadKeptPastItsCallIsDeadUnderTheCheck():Void {
		var link = Link.make();
		if (link == null) return;

		var keptData:Array<ByteArray> = [];
		var keptEvents:Array<DatagramSocketDataEvent> = [];
		var during:Array<String> = [];
		link.receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> {
			during.push(e.data.toString());
			keptData.push(e.data);
			keptEvents.push(e);
		});

		link.sender.send(text("alpha"));
		link.sender.send(numbered(1500));
		// Each in a buffer of its own, so what a kept reference reads is the
		// session's doing alone.
		link.deliver(link.sender.take(), true);

		Assert.equals("alpha", during[0], "the message was not itself during the call");
		#if crossbyte_check_events
		// What a listener keeps reads dead, at the line that reads it.
		for (data in keptData) {
			Assert.equals(0, data.length, "a payload kept past its call was left alive");
		}
		for (event in keptEvents) {
			Assert.isNull(event.srcAddress, "an event kept past its call still said where it came from");
			Assert.equals(-1, event.srcPort);
		}
		#elseif crossbyte_fresh_events
		// The workaround: nothing is reused, and what was kept stays as it came.
		Assert.equals("alpha", keptData[0].toString());
		Assert.equals(-1, wrongByte(keptData[1], 1500));
		Assert.equals("127.0.0.1", keptEvents[0].srcAddress);
		#end
		link.close();
	}

	// ------------------------------------------------------------- helpers

	/** One datagram through `socket`'s own delivery, in `buffer`, as the socket would hand it over. **/
	private static function deliverThrough(socket:DatagramSocket, buffer:ByteArray, datagram:ByteArray, port:Int):Void {
		buffer.length = datagram.length;
		(buffer : Bytes).blit(0, datagram, 0, datagram.length);
		buffer.position = 0;
		socket.__deliver(buffer, "127.0.0.1", port, "127.0.0.1", 1);
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function numbered(length:Int):ByteArray {
		var bytes = new ByteArray();
		for (i in 0...length) {
			bytes.writeByte(i * 7 & 0xFF);
		}
		bytes.position = 0;
		return bytes;
	}

	/** The first byte of `bytes` not as `numbered` made it, or -1; its length checked too. **/
	public static function wrongByte(bytes:ByteArray, length:Int):Int {
		if (bytes == null || bytes.length != length) {
			return -2;
		}
		var raw:Bytes = bytes;
		for (i in 0...length) {
			if (raw.get(i) != (i * 7 & 0xFF)) {
				return i;
			}
		}
		return -1;
	}

	/** Frames as one datagram, as a session bundles them for a peer that takes bundles. **/
	private static function bundle(frames:Array<ByteArray>):ByteArray {
		var out = new ByteArray();
		out.writeByte(ReliableDatagramProtocol.BUNDLE_MAGIC >> 8);
		out.writeByte(ReliableDatagramProtocol.BUNDLE_MAGIC & 0xFF);
		for (frame in frames) {
			out.writeByte(frame.length >> 8);
			out.writeByte(frame.length & 0xFF);
			out.writeBytes(frame, 0, frame.length);
		}
		out.position = 0;
		return out;
	}
}

/** A session whose frames are recorded as datagrams, rather than sent. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class Recorder extends ReliableDatagramSocket {
	private var __recorded:Array<ByteArray> = [];

	public function new() {
		super();
	}

	/** Every frame recorded since the last call, as its own datagram, and what the pass owes. **/
	public function take():Array<ByteArray> {
		__sendBundle();
		var frames = __recorded;
		__recorded = [];
		return frames;
	}

	override private function __sendFrame(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int, resend:Bool,
			ack:Int, hasAck:Bool, more:Bool, graceful:Bool = false):Void {
		var frame = new ByteArray();
		frame.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		frame.length = ReliableDatagramProtocol.encodeInto(frame, type, sequence, payload, offset, length, resend, ack, hasAck, more, 0, graceful);
		frame.position = 0;
		__recorded.push(frame);
	}
}

/**
	A sender and a receiver that believe they are connected to each other at
	127.0.0.1:9, the receiver handed every datagram through its transport's
	own delivery in one buffer.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.DatagramSocket)
private class Link {
	public var sender:Recorder;
	public var receiver:LinkReceiver;

	/** Copies of what the receiver delivered, made during each call. **/
	public var received:Array<ByteArray> = [];

	private var __buffer:ByteArray = new ByteArray();

	public static function make(mode:ReliableDatagramSocketMode = DATAGRAM, connected:Bool = true):Link {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return null;
		}
		return new Link(mode, connected);
	}

	private function new(mode:ReliableDatagramSocketMode, connected:Bool) {
		sender = new Recorder();
		receiver = new LinkReceiver();
		sender.__mode = mode;
		receiver.__mode = mode;
		for (socket in [sender, receiver]) {
			socket.__connected = connected;
			socket.__remoteAddress = "127.0.0.1";
			socket.__remotePort = 9;
		}
		// Where the handshake would have left them.
		receiver.__inSequence = sender.__outSequence;
		if (mode == DATAGRAM) {
			receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> received.push(cast(e.clone(), DatagramSocketDataEvent).data));
		}
	}

	/**
		Each datagram to the receiver, in the order given, through the
		transport's own delivery: in one buffer filled again for each, as a
		socket that reuses its payload hands them over, or with `fresh`, in
		a buffer of its own each.
	**/
	public function deliver(datagrams:Array<ByteArray>, fresh:Bool = false):Void {
		for (datagram in datagrams) {
			var buffer:ByteArray = fresh ? new ByteArray() : __buffer;
			buffer.length = datagram.length;
			(buffer : Bytes).blit(0, datagram, 0, datagram.length);
			buffer.position = 0;
			receiver.__transport.__deliver(buffer, "127.0.0.1", 9, "127.0.0.1", 1);
		}
	}

	public function texts():Array<String> {
		return [for (message in received) message.toString()];
	}

	public function close():Void {
		try sender.__dispose(false) catch (_:Dynamic) {}
		try receiver.__dispose(false) catch (_:Dynamic) {}
	}
}

/** The receiving end: records what it sends too, decoded, for the echo case. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class LinkReceiver extends Recorder {
	public function new() {
		super();
	}

	public function takeFrames():Array<ReliableDatagramFrame> {
		return [for (bytes in take()) ReliableDatagramProtocol.decode(bytes)];
	}
}
