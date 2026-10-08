package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	One message to many reliable UDP sessions: a `PreparedDatagram`, copied
	once when it is made, that each session sends, and sends again until
	its peer has it, from the same bytes, through `sendPrepared` or a
	server's `broadcast`. Each session still frames it with its own
	sequence numbers, bundles it, and keeps a record of each frame, but no
	copy.

	Over real loopback sockets, but for the cases that look at what a
	session holds and sends, which record frames instead of sending them.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.PreparedDatagram)
@:access(crossbyte.net.CongestionControl)
class ReliableDatagramBroadcastTest extends utest.Test {
	// ------------------------------------------------------------ the message

	public function testPreparingCopiesTheBytesOnce():Void {
		var bytes = message(300, 1);
		var prepared = PreparedDatagram.of(bytes, 100, 150);
		Assert.equals(150, prepared.length);
		// The caller's buffer is its own again.
		for (i in 0...bytes.length) {
			(bytes : Bytes).set(i, 0xEE);
		}
		Assert.same(slice(message(300, 1), 100, 150), bytesOf(prepared.__bytes, 0, prepared.length));
		Assert.equals(300, PreparedDatagram.of(message(300, 1)).length, "a length of 0 did not take everything");
		Assert.equals(0, PreparedDatagram.of(new ByteArray()).length);
	}

	public function testPreparingRefusesWhatIsNotThere():Void {
		Assert.raises(() -> PreparedDatagram.of(null), ArgumentError);
		Assert.raises(() -> PreparedDatagram.of(message(10, 0), 11), RangeError);
		Assert.raises(() -> PreparedDatagram.of(message(10, 0), 5, 6), RangeError);
		Assert.raises(() -> PreparedDatagram.of(message(10, 0), -1), RangeError);
		Assert.raises(() -> PreparedDatagram.of(message(10, 0), 0, -1), RangeError);
	}

	// ------------------------------------------------- what a session holds

	public function testASessionSendsItFromTheSharedBytesAndKeepsNoCopy():Void {
		var sessions = [Wire.make(), Wire.make()];
		if (sessions[0] == null) return;
		var prepared = PreparedDatagram.of(message(2500, 2));

		for (session in sessions) {
			session.sendPrepared(prepared);
		}
		for (session in sessions) {
			// Three frames, each over the same bytes, none with a buffer of its own.
			for (sequence in 1000...1003) {
				var frame = Require.notNull(session.__outFrameCache.get(sequence), "a frame of the message was not kept to be sent again");
				Assert.isTrue(frame.payload == prepared.__bytes, "a frame kept a copy of the message");
				Assert.isNull(frame.buffer);
			}
			var sent = session.take();
			Assert.same(["PACKET 1000 more", "PACKET 1001 more", "PACKET 1002"], described(sent));
			Assert.same(bytesOf(prepared.__bytes, 0, prepared.length), joined(sent));
		}
		for (session in sessions) {
			session.abort();
		}
	}

	public function testAFrameLostIsSentAgainFromTheSameBytes():Void {
		var session = Wire.make();
		if (session == null) return;
		var bytes = message(400, 3);
		var prepared = PreparedDatagram.of(bytes);
		session.sendPrepared(prepared);
		session.take();
		// The caller's bytes change; the prepared message's do not.
		for (i in 0...bytes.length) {
			(bytes : Bytes).set(i, 0);
		}
		Require.notNull(session.__outFrameCache.get(1000)).deadline = 0;
		session.__checkRetransmits();
		var resent = session.take();
		Assert.same(["PACKET 1000 resend"], described(resent));
		Assert.same(bytesOf(message(400, 3), 0, 400), bytesOf(resent[0].payload, 0, resent[0].payload.length));
		session.abort();
	}

	public function testAnEncryptedSessionSplitsTheSameBytesIntoItsSmallerFrames():Void {
		var plain = Wire.make();
		if (plain == null) return;
		if (!ReliableDatagramSocket.isEncryptionSupported) {
			plain.abort();
			Assert.pass();
			return;
		}
		var sealed = Wire.make();
		// A session that seals: its frames carry 1,179 bytes.
		sealed.__cipher = new crossbyte.net._internal.reliable.SessionCipher(Bytes.alloc(32));
		var prepared = PreparedDatagram.of(message(2400, 4));
		plain.sendPrepared(prepared);
		sealed.sendPrepared(prepared);
		Assert.same([1200, 1200], [for (s in 1000...1002) Require.notNull(plain.__outFrameCache.get(s)).length]);
		Assert.same([1179, 1179, 42], [for (s in 1000...1003) Require.notNull(sealed.__outFrameCache.get(s)).length]);
		Assert.isTrue(sealed.__outFrameCache.get(1002).payload == prepared.__bytes);
		Assert.equals(2358, sealed.__outFrameCache.get(1002).offset);
		plain.abort();
		sealed.abort();
	}

	public function testEveryDeliveryModeSendsIt():Void {
		var session = Wire.make();
		if (session == null) return;
		var prepared = PreparedDatagram.of(message(100, 5));
		session.sendPrepared(prepared, DeliveryMode.UNRELIABLE);
		session.sendPrepared(prepared, DeliveryMode.sequenced(3));
		session.sendPrepared(prepared, DeliveryMode.sequenced(3));
		session.sendPrepared(prepared);
		var sent = session.take();
		Assert.same(["UNRELIABLE 0", "SEQUENCED " + ((3 << 24) | 0), "SEQUENCED " + ((3 << 24) | 1), "PACKET 1000"], described(sent));
		for (frame in sent) {
			Assert.same(bytesOf(prepared.__bytes, 0, 100), bytesOf(frame.payload, 0, frame.payload.length));
		}
		// Unreliable is never kept: only the reliable one is in flight.
		Assert.equals(1, session.__outFrameCache.count, "an unreliable message was kept to be sent again");
		// And an unreliable message must fit a frame, as with send.
		Assert.raises(() -> session.sendPrepared(PreparedDatagram.of(message(1201, 0)), DeliveryMode.UNRELIABLE), RangeError);
		session.abort();
	}

	public function testItIsRefusedWhereSendIs():Void {
		var session = Wire.make();
		if (session == null) return;
		var prepared = PreparedDatagram.of(message(10, 0));
		Assert.raises(() -> session.sendPrepared(null), ArgumentError);
		session.__mode = STREAM;
		Assert.raises(() -> session.sendPrepared(prepared), crossbyte.errors.IllegalOperationError);
		session.__mode = DATAGRAM;
		session.close();
		Assert.raises(() -> session.sendPrepared(prepared), crossbyte.errors.IOError);
		session.abort();
	}

	// ------------------------------------------------------------- broadcast

	public function testABroadcastReachesEverySessionOnceAsTheSameBytes():Void {
		var pair = Room.make(3);
		if (pair == null) return;
		try {
			var prepared = PreparedDatagram.of(message(3000, 6));
			pair.server.broadcast(prepared);
			pair.server.broadcast(PreparedDatagram.of(message(50, 7)), DeliveryMode.sequenced(0));
			pair.waitFor(() -> pair.received.length == 6);
			for (client in pair.clients) {
				var mine = pair.receivedBy(client);
				Assert.equals(2, mine.length, "a client was not sent each message once");
				if (mine.length == 2) {
					// The sequenced one may overtake the reliable one.
					mine.sort((a, b) -> b.length - a.length);
					Assert.same(bytesOf(message(3000, 6), 0, 3000), mine[0]);
					Assert.same(bytesOf(message(50, 7), 0, 50), mine[1]);
				}
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	public function testABroadcastToAListReachesOnlyThoseConnected():Void {
		var pair = Room.make(3);
		if (pair == null) return;
		try {
			var chosen = [pair.accepted[0], pair.accepted[2], null];
			pair.server.broadcast(PreparedDatagram.of(message(80, 8)), chosen);
			pair.waitFor(() -> pair.received.length == 2);
			pair.pumpFor(0.05);
			Assert.equals(2, pair.received.length);
			Assert.equals(0, pair.receivedBy(pair.peerOf(pair.accepted[1])).length, "a session not in the list was sent the message");

			// Closing, or closed: passed over, and nothing thrown.
			pair.accepted[0].close();
			pair.server.broadcast(PreparedDatagram.of(message(80, 9)));
			pair.waitFor(() -> pair.received.length == 4);
			pair.pumpFor(0.05);
			Assert.equals(4, pair.received.length, "a closing session was sent the message, or another was not");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	/**
		A session that a broadcast closes, past its output limit, comes off
		the server's list as the broadcast walks it: the others are each sent
		the message once, none twice and none passed over.
	**/
	public function testASessionClosingDuringABroadcastLeavesTheOthersOneEach():Void {
		var pair = Room.make(4);
		if (pair == null) return;
		try {
			// In the order the server walks them: the second's window is shut
			// and its limit small, so the broadcast ends it, and its close
			// listener ends the third, each coming off the server's list,
			// the last taking its place.
			var order = pair.server.__sessionList.copy();
			Assert.equals(4, order.length);
			var doomed = order[1];
			doomed.__congestion.window = 0;
			doomed.maxOutputBufferSize = 100;
			doomed.addEventListener(Event.CLOSE, _ -> order[2].abort());
			pair.server.broadcast(PreparedDatagram.of(message(500, 10)));
			pair.waitFor(() -> pair.received.length >= 2);
			pair.pumpFor(0.05);
			Assert.equals(1, pair.receivedBy(pair.peerOf(order[0])).length);
			Assert.equals(1, pair.receivedBy(pair.peerOf(order[3])).length, "the last session, moved up the list, was passed over or sent it twice");
			Assert.equals(0, pair.receivedBy(pair.peerOf(order[2])).length, "a session closed during the broadcast was sent it");
			Assert.equals(2, pair.received.length);
			Assert.isFalse(doomed.connected);
			Assert.equals(2, pair.server.__sessionList.length, "a closed session was left on the server's list");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	public function testABroadcastThrowsForNoOneSession():Void {
		var pair = Room.make(2);
		if (pair == null) return;
		try {
			var stuck = pair.accepted[0];
			stuck.__congestion.window = 0;
			stuck.maxOutputBufferSize = 100;
			stuck.outputOverflowPolicy = THROW;
			pair.server.broadcast(PreparedDatagram.of(message(500, 11)));
			Assert.equals(500, stuck.bufferedAmount, "what the session holds was not said");
			Assert.isTrue(stuck.connected);
			pair.waitFor(() -> pair.received.length == 1);
			Assert.equals(1, pair.receivedBy(pair.peerOf(pair.accepted[1])).length, "the other session was not sent it");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	public function testAnUnreliableBroadcastTooLargeForASessionThrowsBeforeSendingAny():Void {
		var pair = Room.make(2);
		if (pair == null) return;
		try {
			Assert.raises(() -> pair.server.broadcast(PreparedDatagram.of(message(1201, 0)), DeliveryMode.UNRELIABLE), RangeError);
			Assert.raises(() -> pair.server.broadcast(null), ArgumentError);
			pair.pumpFor(0.05);
			Assert.equals(0, pair.received.length);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	public function testABroadcastsFramesGoBackOnceAcknowledged():Void {
		var pair = Room.make(3);
		if (pair == null) return;
		try {
			var pool = pair.server.__framePool();
			pair.server.broadcast(PreparedDatagram.of(message(2500, 12)));
			Assert.equals(9, pool.inUse, "three frames for each of three sessions");
			pair.waitFor(() -> pair.received.length == 3 && pool.inUse == 0);
			Assert.equals(0, pool.inUse, "a broadcast's frames were not given back once acknowledged");
			var made = pool.made;
			pair.server.broadcast(PreparedDatagram.of(message(2500, 13)));
			Assert.equals(made, pool.made, "the second broadcast made frames with nine waiting");
			pair.waitFor(() -> pair.received.length == 6 && pool.inUse == 0);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	// ------------------------------------------------------------- helpers

	private static function message(length:Int, seed:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		for (i in 0...length) {
			(bytes : Bytes).set(i, (i * 13 + seed * 29 + 1) & 0xFF);
		}
		return bytes;
	}

	private static function bytesOf(bytes:ByteArray, from:Int, length:Int):Array<Int> {
		return [for (i in from...from + length) (bytes : Bytes).get(i)];
	}

	private static function slice(bytes:ByteArray, from:Int, length:Int):Array<Int> {
		return bytesOf(bytes, from, length);
	}

	private static function joined(frames:Array<ReliableDatagramFrame>):Array<Int> {
		var all:Array<Int> = [];
		for (frame in frames) {
			all = all.concat(bytesOf(frame.payload, 0, frame.payload.length));
		}
		return all;
	}

	private static function described(frames:Array<ReliableDatagramFrame>):Array<String> {
		return [
			for (frame in frames)
				Wire.typeName(frame.type) + " " + (frame.sequence : Int) + (frame.more ? " more" : "") + (frame.resend ? " resend" : "")
		];
	}
}

/** A connected session whose frames are recorded instead of sent; sequences pinned at 1000. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class Wire extends ReliableDatagramSocket {
	private var __recorded:Array<ByteArray> = [];

	public static function make():Wire {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new Wire();
		socket.__connected = true;
		socket.__peerConfirmed = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		socket.__outSequence = 1000;
		socket.__windowBase = 1000;
		socket.__firstSequence = 1000;
		socket.__inSequence = 1000;
		return socket;
	}

	public function new() {
		super();
	}

	public function take():Array<ReliableDatagramFrame> {
		__sendBundle();
		var frames = [for (bytes in __recorded) ReliableDatagramProtocol.decode(bytes)];
		__recorded = [];
		return frames;
	}

	override private function __sendFrame(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int, resend:Bool,
			ack:Int, hasAck:Bool, more:Bool, graceful:Bool = false):Void {
		var frame = new ByteArray();
		frame.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		frame.length = ReliableDatagramProtocol.encodeInto(frame, type, sequence, payload, offset, length, resend, ack, hasAck, more, 0, graceful);
		__recorded.push(frame);
	}

	public static function typeName(type:ReliableDatagramFrameType):String {
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

/** A server and its clients over loopback, and every message each client received, copied. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class Room {
	public var server:ReliableDatagramServerSocket;
	public var clients:Array<ReliableDatagramSocket> = [];
	public var accepted:Array<ReliableDatagramSocket> = [];
	public var received:Array<{client:ReliableDatagramSocket, bytes:Array<Int>}> = [];

	static var __last:Float = -1;

	public static function make(count:Int):Room {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return null;
		}
		var room = new Room();
		room.server = new ReliableDatagramServerSocket();
		room.server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> room.accepted.push(e.socket));
		room.server.bind(0, "127.0.0.1");
		room.server.listen();
		room.waitFor(() -> room.server.localPort != 0);
		for (_ in 0...count) {
			var client = new ReliableDatagramSocket();
			client.addEventListener(DatagramSocketDataEvent.DATA, e -> {
				var data = e.data;
				room.received.push({client: client, bytes: [for (i in 0...data.length) (data : Bytes).get(i)]});
			});
			client.connect("127.0.0.1", room.server.localPort);
			room.clients.push(client);
		}
		room.waitFor(() -> room.accepted.length == count && room.allConnected());
		if (room.accepted.length != count) {
			Assert.fail("the sessions never connected");
			room.close();
			return null;
		}
		// The order the clients were made in, not the one they connected in.
		room.accepted.sort((a, b) -> room.indexOfPeer(a) - room.indexOfPeer(b));
		return room;
	}

	public function new() {}

	function allConnected():Bool {
		for (c in clients) {
			if (!c.connected) {
				return false;
			}
		}
		for (a in accepted) {
			if (!a.connected) {
				return false;
			}
		}
		return true;
	}

	function indexOfPeer(session:ReliableDatagramSocket):Int {
		for (i in 0...clients.length) {
			if (clients[i].localPort == session.remotePort) {
				return i;
			}
		}
		return -1;
	}

	public function peerOf(session:ReliableDatagramSocket):ReliableDatagramSocket {
		return clients[indexOfPeer(session)];
	}

	public function receivedBy(client:ReliableDatagramSocket):Array<Array<Int>> {
		return [for (r in received) if (r.client == client) r.bytes];
	}

	public function pump():Void {
		var now = haxe.Timer.stamp();
		if (__last < 0) {
			__last = now;
		}
		crossbyte.sys.System.sleep(0.001);
		CrossByte.current().pump(now - __last, 0);
		__last = now;
	}

	public function waitFor(done:Void->Bool, timeout:Float = 3.0):Void {
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			pump();
		}
	}

	public function pumpFor(seconds:Float):Void {
		var until = haxe.Timer.stamp() + seconds;
		while (haxe.Timer.stamp() < until) {
			pump();
		}
	}

	public function close():Void {
		for (c in clients) {
			try c.abort() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}
}
