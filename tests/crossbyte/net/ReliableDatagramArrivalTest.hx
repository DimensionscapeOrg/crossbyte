package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.Endian;
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
	socket hands one over: released, in the socket's own payload, filled
	again for each datagram and emptied after it. So a session that kept
	any of a datagram by reference (a frame held past a gap, a fragment,
	a CONNECT's payload) reads the wrong bytes here in every mode, not
	only under `-D crossbyte_check_events`, where each datagram's own
	payload is killed once its call returns.

	And what the session hands out again for each message (its event,
	the buffer a fragmented message is put back together in, the payload a
	bundle's frame is copied into) is right for every message, emptied
	after each, and taken afresh for a message arriving inside a listener's
	call.

	No network: the sender's frames are recorded as it sends them, and the
	order they arrive in is each case's.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.DatagramSocket)
@:access(crossbyte.net.CongestionControl)
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
		// the gap the first fragment leaves (a full frame, which no bundle has
		// room for) until it arrives, last.
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
		// acknowledged, so it must have kept a copy, and not the event's bytes,
		// which belong to the next datagram by the time it is sent again.
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

			deliverThrough(server.__socket, ReliableDatagramProtocol.encode(CONNECT, 77, text("join token A")), 40001);
			deliverThrough(server.__socket, ReliableDatagramProtocol.encode(CONNECT, 78, text("a longer join token, B")), 40002);

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
		#else
		// Released: the session's one event, handed out for both, and the
		// message it put back together emptied once its call returned.
		Assert.isTrue(keptEvents[0] == keptEvents[1], "the session's event was not handed out again");
		Assert.isTrue(keptData[1] == link.receiver.__assemblyKept, "the message was not put back together in the session's own buffer");
		Assert.equals(0, keptData[1].length, "a message put back together still read whole after its call");
		Assert.equals(0, keptData[1].position);
		#end
		link.close();
	}

	/**
		Message after message through what the session hands out again: each
		is right in its call, in the session's byte order from position 0,
		whatever the one before was left as; a clone keeps its bytes after
		later messages; and storage a large message grew past `Arrivals.KEEP`
		is let go once its call returns.
	**/
	public function testEachMessageIsRightInWhatTheSessionHandsOutAgain():Void {
		var link = Link.make();
		if (link == null) return;

		// Room for every frame at once: nothing acknowledges them here.
		link.sender.__congestion.window = CongestionControl.MAX_WINDOW;
		link.receiver.endian = Endian.BIG_ENDIAN;
		var seen:Array<String> = [];
		var clones:Array<DatagramSocketDataEvent> = [];
		var capacityAfterLarge:Int = -1;
		link.receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> {
			var data:ByteArray = e.data;
			var first:Int = data.readUnsignedShort();
			seen.push(data.position + ":" + data.length + ":" + (data.endian == Endian.BIG_ENDIAN ? "big" : "little") + ":" + first);
			clones.push(cast e.clone());
			// Left at its end and in the other order: the next is not to
			// start where this one was left.
			data.position = data.length;
			data.endian = Endian.LITTLE_ENDIAN;
		});

		// Fragmented, single, fragmented and past KEEP, fragmented again, and
		// bundled: each through what the session keeps for it.
		link.sender.send(numbered(3000));
		link.sender.send(numbered(40));
		link.sender.send(numbered(20000));
		link.deliver(link.sender.take());
		capacityAfterLarge = capacityOf(link.receiver.__assemblyKept);
		link.sender.send(numbered(2600));
		var sent = link.sender.take();
		link.sender.send(numbered(30));
		link.sender.send(numbered(31));
		var small = link.sender.take();
		link.deliver(sent.concat([bundle(small)]));

		var lead:Int = (0 << 8) | 7;
		Assert.same(['2:3000:big:$lead', '2:40:big:$lead', '2:20000:big:$lead', '2:2600:big:$lead', '2:30:big:$lead', '2:31:big:$lead'], seen);
		var sizes = [3000, 40, 20000, 2600, 30, 31];
		for (i in 0...clones.length) {
			Assert.equals(-1, wrongByte(clones[i].data, sizes[i]), 'clone $i lost its bytes to a later message');
		}
		#if !(crossbyte_fresh_events || crossbyte_check_events)
		Assert.isTrue(capacityAfterLarge <= crossbyte.events._internal.Arrivals.KEEP, "a 20,000-byte message's storage was held after its call: " + capacityAfterLarge);
		Assert.isTrue(capacityOf(link.receiver.__assemblyKept) <= crossbyte.events._internal.Arrivals.KEEP);
		Assert.notNull(link.receiver.__entry, "a bundle's frames were not copied into the session's own payload");
		Assert.equals(0, link.receiver.__entry.length, "a bundle's frame still read whole after its call");
		Assert.isFalse(link.receiver.__arrivalOut || link.receiver.__assemblyOut || link.receiver.__entryOut, "something was left out after its call");
		#else
		Assert.isNull(link.receiver.__assemblyKept, "a buffer was kept for reuse with reuse off");
		Assert.isNull(link.receiver.__arrivalEvent, "an event was kept for reuse with reuse off");
		#end
		link.close();
	}

	/**
		A message arriving inside a listener's call (the listener pumps, and
		the next datagram is delivered) gets an event and a buffer of its own,
		and the one being handled is left as it was.
	**/
	public function testAMessageArrivingInsideAListenersCallHasItsOwnEventAndBytes():Void {
		var link = Link.make();
		if (link == null) return;

		// Both fragmented, so each is put back together; the nested one is
		// delivered from inside the listener handling the first.
		link.sender.send(numbered(2200));
		var outer = link.sender.take();
		link.sender.send(numbered(1800));
		var nested = link.sender.take();

		var depth:Int = 0;
		var outerEvent:DatagramSocketDataEvent = null;
		var outerData:ByteArray = null;
		var nestedEvent:DatagramSocketDataEvent = null;
		var nestedData:ByteArray = null;
		var nestedWrong:Int = -2;
		var outerAfter:Int = -2;
		var outerFrom:Int = 0;
		link.receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> {
			depth++;
			if (depth == 1) {
				outerEvent = e;
				outerData = e.data;
				link.deliver(nested);
				e.data.position = 0;
				outerAfter = wrongByte(e.data, 2200);
				outerFrom = e.srcPort;
			} else {
				nestedEvent = e;
				nestedData = e.data;
				nestedWrong = wrongByte(e.data, 1800);
			}
			depth--;
		});
		link.deliver(outer);

		Assert.equals(-1, nestedWrong, "the nested message was not itself");
		Assert.equals(-1, outerAfter, "a message arriving inside a listener changed the one it was handling");
		Assert.equals(9, outerFrom, "a message arriving inside a listener changed the event it was handling");
		Assert.isTrue(nestedEvent != null && nestedEvent != outerEvent, "a nested message was handed the event still out");
		Assert.isTrue(nestedData != null && nestedData != outerData, "a nested message was put back together in the buffer still out");
		#if !(crossbyte_fresh_events || crossbyte_check_events)
		Assert.isTrue(outerEvent == link.receiver.__arrivalEvent, "the outer message was not handed out in the session's own event");
		Assert.isTrue(outerData == link.receiver.__assemblyKept, "the outer message was not put back together in the session's own buffer");
		Assert.isFalse(link.receiver.__arrivalOut || link.receiver.__assemblyOut, "something was left out after its call");
		#end
		link.close();
	}

	/**
		A payload made for one message, not the session's own (here a message
		whose first fragment arrived inside another message's call, so it is
		put back together in a buffer of its own), handed out in the session's
		reused event, is emptied once its call returns, and its storage let
		go: the event does not go on holding it until the next message, which
		could be a whole `maxMessageSize`.
	**/
	public function testAMessageOfItsOwnHandedOutInTheReusedEventIsLetGo():Void {
		var link = Link.make();
		if (link == null) return;

		// Room for every frame at once: nothing acknowledges them here.
		link.sender.__congestion.window = CongestionControl.MAX_WINDOW;
		// The first message fragmented too, so its call has the session's
		// own buffer out.
		link.sender.send(numbered(3000));
		var first = link.sender.take();
		link.sender.send(numbered(40000));
		var large = link.sender.take();
		Assert.isTrue(large.length > 2, "the large message was not fragmented");

		var kept:Array<ByteArray> = [];
		var lengths:Array<Int> = [];
		link.receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> {
			kept.push(e.data);
			lengths.push(e.data.length);
			if (lengths.length == 1) {
				// The large message's first fragment, inside this call: put
				// back together in a buffer of its own, the session's out.
				link.deliver([large[0]]);
			}
		});
		link.deliver(first);
		link.deliver(large.slice(1));

		Assert.same([3000, 40000], lengths, "the messages were not delivered whole");
		Assert.equals(-1, link.received.length == 2 ? wrongByte(link.received[1], 40000) : -3, "the large message was not itself");
		#if crossbyte_check_events
		Assert.equals(0, kept[1].length, "a message kept past its call was left alive");
		#elseif crossbyte_fresh_events
		Assert.equals(40000, kept[1].length);
		#else
		Assert.isTrue(kept[1] != link.receiver.__assemblyKept, "the large message was put back together in the session's own buffer, so this shows nothing");
		Assert.equals(0, kept[1].length, "a message of its own kept past its call still read whole");
		var event = link.receiver.__arrivalEvent;
		var held:Int = event == null || event.data == null ? 0 : capacityOf(event.data);
		Assert.isTrue(held <= crossbyte.events._internal.Arrivals.KEEP, 'the session went on holding $held bytes of a message whose call had returned');
		#end
		link.close();
	}

	/**
		A listener that throws lets go of what it was handed: the next message
		is right, and goes through the session's own event and buffer again.
	**/
	public function testAListenerThatThrowsLeavesTheNextMessageRight():Void {
		var link = Link.make();
		if (link == null) return;

		var calls:Int = 0;
		var events:Array<DatagramSocketDataEvent> = [];
		var after:Array<Int> = [];
		link.receiver.addEventListener(DatagramSocketDataEvent.DATA, e -> {
			calls++;
			events.push(e);
			if (calls == 1) {
				e.data.position = 9;
				throw "a listener's own failure";
			}
			after.push(wrongByte(e.data, 2400));
		});

		link.sender.send(numbered(2400));
		var first = link.sender.take();
		var thrown:Dynamic = null;
		try {
			link.deliver(first);
		} catch (e:Dynamic) {
			thrown = e;
		}
		Assert.equals("a listener's own failure", Std.string(thrown), "the listener's throw did not reach the caller");

		link.sender.send(numbered(2400));
		link.deliver(link.sender.take());

		Assert.same([-1], after, "the message after a listener threw was wrong");
		#if !(crossbyte_fresh_events || crossbyte_check_events)
		Assert.isTrue(events[0] == events[1], "a listener's throw left the session's event out");
		Assert.isFalse(link.receiver.__arrivalOut || link.receiver.__assemblyOut, "a listener's throw left something out");
		Assert.isFalse(link.receiver.__transport.__arrivalOut, "a listener's throw left the socket's payload out");
		#end
		link.close();
	}

	/**
		A server whose application sees each datagram first (`onDatagram`)
		cannot let a frame take the datagram itself: the frame's payload is
		copied into the server's own, filled again for each, and the sessions
		get each message right.
	**/
	public function testAServerWhoseApplicationSeesDatagramsFirstCopiesEachRight():Void {
		if (!ReliableDatagramServerSocket.isSupported) {
			Assert.isFalse(ReliableDatagramServerSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var looked:Int = 0;
		var payloads:Array<String> = [];
		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			server.onDatagram = (data, address, port) -> {
				looked++;
				return false;
			};
			var orders:Array<String> = [];
			server.admit = (address, port, payload) -> {
				orders.push((payload.endian == Endian.BIG_ENDIAN ? "big" : "little") + "/" + payload.objectEncoding + "/" + payload.position);
				payloads.push(payload.readUTFBytes(payload.length));
				// What a hook might leave behind on the payload it was handed.
				payload.endian = payload.endian == Endian.BIG_ENDIAN ? Endian.LITTLE_ENDIAN : Endian.BIG_ENDIAN;
				payload.objectEncoding = ObjectEncoding.JSON;
				return true;
			};

			deliverThrough(server.__socket, ReliableDatagramProtocol.encode(CONNECT, 91, text("first token")), 40011);
			deliverThrough(server.__socket, ReliableDatagramProtocol.encode(CONNECT, 92, text("second, longer token")), 40012);

			Assert.equals(2, looked, "the application did not see each datagram first");
			Assert.same(["first token", "second, longer token"], payloads);
			// Each in the order and encoding a payload made for it has, whatever
			// the hook before it left on the server's one buffer.
			var start:String = (ByteArray.defaultEndian == Endian.BIG_ENDIAN ? "big" : "little") + "/" + ByteArray.defaultObjectEncoding + "/0";
			Assert.same([start, start], orders, "a CONNECT's payload kept what the hook before it left: " + orders.join(", "));
			var first = server.__sessionAt("127.0.0.1", 40011);
			Require.notNull(first, "the first CONNECT opened no session");
			Assert.equals("first token", first.connectPayload.toString(), "a session's connectPayload was the server's copy");
			#if !(crossbyte_fresh_events || crossbyte_check_events)
			Assert.notNull(server.__copy, "the frames were not copied into the server's own payload");
			Assert.equals(0, server.__copy.length, "the server's copy still read whole after its call");
			Assert.isFalse(server.__copyOut);
			#else
			Assert.isNull(server.__copy, "a payload was kept for reuse with reuse off");
			#end
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try server.close() catch (_:Dynamic) {}
	}

	// ------------------------------------------------------------- helpers

	/**
		One datagram through `socket`'s own delivery, as the socket hands one
		over: in its own payload, filled again for each, where it reuses one.
	**/
	private static function deliverThrough(socket:DatagramSocket, datagram:ByteArray, port:Int):Void {
		var pooled:Bool = socket.__pooledArrival();
		var payload:ByteArray = socket.__payloadOf(datagram, 0, datagram.length, pooled);
		socket.__deliver(payload, pooled, "127.0.0.1", port, "127.0.0.1", 1);
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	/** The storage a payload holds, readable or not; 0 for none. **/
	private static function capacityOf(payload:ByteArray):Int {
		if (payload == null) {
			return 0;
		}
		var data:ByteArrayData = payload;
		return @:privateAccess data.__length;
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
		transport's own delivery, as the socket hands them over: in its own
		payload, filled again for each, where it reuses one, or with `fresh`,
		in a payload of its own each.
	**/
	public function deliver(datagrams:Array<ByteArray>, fresh:Bool = false):Void {
		var transport = receiver.__transport;
		for (datagram in datagrams) {
			var pooled:Bool = !fresh && transport.__pooledArrival();
			var payload:ByteArray = transport.__payloadOf(datagram, 0, datagram.length, pooled);
			transport.__deliver(payload, pooled, "127.0.0.1", 9, "127.0.0.1", 1);
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
