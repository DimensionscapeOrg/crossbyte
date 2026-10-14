package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net.DeliveryMode;
import crossbyte.net.NetConnection;
import crossbyte.net.ReliableDatagramSocket;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.io.Bytes;
import utest.Assert;

/**
	`RPCCommands.delivery`: the next call in a mode of its own over reliable
	UDP, and as usual over a transport with one way to send.

	The sockets are real sessions whose datagrams go through memory: every
	frame one sends is recorded, so a case can see which mode each call went
	in, and hand them to the other side.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
class RPCDeliveryTest extends utest.Test {
	public function testTheNextCallGoesInTheModeItWasGiven():Void {
		final ends = Ends.make();
		if (ends == null) {
			return;
		}
		ends.sender.take();
		ends.commands.delivery(DeliveryMode.UNRELIABLE).note(1);
		Assert.same([ReliableDatagramFrameType.UNRELIABLE], ends.sentTypes(), "an unreliable call went otherwise");
		ends.commands.note(2);
		Assert.same([ReliableDatagramFrameType.PACKET], ends.sentTypes(), "the call after it was not reliable");
		ends.commands.delivery(DeliveryMode.sequenced(3)).note(3);
		Assert.same([ReliableDatagramFrameType.SEQUENCED], ends.sentTypes(), "a sequenced call went otherwise");
		// A request too: it goes in the mode given, and is answered.
		final asked = ends.commands.delivery(DeliveryMode.UNRELIABLE).ask(4);
		final askFrames = ends.sender.take();
		Assert.same([ReliableDatagramFrameType.UNRELIABLE], typesOf(askFrames), "an unreliable request went otherwise");
		// Each arrives at the other side and is run there.
		ends.carry(askFrames);
		ends.back();
		Assert.equals(4, asked.result, "an unreliable request was not answered");
		// `within` and `delivery` together, for one call.
		ends.commands.delivery(DeliveryMode.UNRELIABLE).within(5).note(5);
		Assert.same([ReliableDatagramFrameType.UNRELIABLE], ends.sentTypes());
		ends.commands.within(5).note(6);
		Assert.same([ReliableDatagramFrameType.PACKET], ends.sentTypes(), "a deadline alone sent a call unreliably");
	}

	public function testAnUnreliableCallArrivesAndRuns():Void {
		final ends = Ends.make();
		if (ends == null) {
			return;
		}
		ends.carry(ends.sender.take());
		ends.commands.delivery(DeliveryMode.UNRELIABLE).note(7);
		ends.commands.delivery(DeliveryMode.sequenced(0)).note(8);
		ends.carry(ends.sender.take());
		Assert.same([7, 8], ends.handler.notes);
	}

	public function testACallLargerThanADatagramIsRefusedUnreliable():Void {
		final ends = Ends.make();
		if (ends == null) {
			return;
		}
		ends.sender.take();
		Assert.raises(() -> ends.commands.delivery(DeliveryMode.UNRELIABLE).blob(Bytes.alloc(2000)), RangeError);
		final asked = ends.commands.delivery(DeliveryMode.UNRELIABLE).echo(Bytes.alloc(2000));
		switch (asked.failure) {
			case Unsent(_):
				Assert.pass();
			case other:
				Assert.fail("an unreliable request past a datagram failed as " + other);
		}
		// The buffer they were written in goes as usual for the next call.
		ends.commands.blob(Bytes.alloc(2000));
		Assert.isTrue(ends.sentTypes().indexOf(ReliableDatagramFrameType.UNRELIABLE) < 0, "the next call went unreliably");
	}

	public function testACallThatCouldNotBeWrittenLeavesNothingForTheNext():Void {
		final ends = Ends.make();
		if (ends == null) {
			return;
		}
		ends.sender.take();
		Assert.raises(() -> ends.commands.delivery(DeliveryMode.UNRELIABLE).names([null]), ArgumentError);
		ends.commands.note(9);
		Assert.same([ReliableDatagramFrameType.PACKET], ends.sentTypes(), "a call after one that could not be written went unreliably");
	}

	public function testATransportWithOneWayToSendIgnoresIt():Void {
		final link = LinkedConnection.pair();
		final commands = new DeliveryCommands();
		final handler = new DeliveryHandler();
		final client = new RPCSession<DeliveryCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, handler);
		Assert.notNull(client);
		Assert.notNull(server);
		commands.delivery(DeliveryMode.UNRELIABLE).note(1);
		Assert.equals(2, commands.delivery(DeliveryMode.sequenced(1)).ask(2).result);
		commands.note(3);
		Assert.same([1, 3], handler.notes);
	}

	public static function typesOf(frames:Array<ReliableDatagramFrame>):Array<ReliableDatagramFrameType> {
		return [
			for (frame in frames)
				if (frame.payload != null && frame.payload.length > 0 && frame.type != ReliableDatagramFrameType.ACK) frame.type
		];
	}
}

/** A client session and a server session over recording sockets. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class Ends {
	public final sender:RecordingRudp;
	public final receiver:RecordingRudp;
	public final commands = new DeliveryCommands();
	public final handler = new DeliveryHandler();
	public final client:RPCSession<DeliveryCommands, Dynamic>;
	public final server:RPCSession<Dynamic, Dynamic>;

	public static function make():Null<Ends> {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		return new Ends();
	}

	function new() {
		sender = RecordingRudp.ready();
		receiver = RecordingRudp.ready();
		// Where a handshake would have left them: each expecting the other's
		// first sequence number.
		receiver.__inSequence = sender.__outSequence;
		sender.__inSequence = receiver.__outSequence;
		client = new RPCSession<DeliveryCommands, Dynamic>(NetConnection.fromReliableDatagramSocket(sender), commands);
		server = new RPCSession(NetConnection.fromReliableDatagramSocket(receiver), null, handler);
	}

	/** The types of the frames the client has sent since last asked, its calls'. **/
	public function sentTypes():Array<ReliableDatagramFrameType> {
		return RPCDeliveryTest.typesOf(sender.take());
	}

	/** Hands the server each frame. **/
	public function carry(frames:Array<ReliableDatagramFrame>):Void {
		for (frame in frames) {
			receiver.__acceptFrame(frame);
		}
	}

	/** Hands the client what the server has sent. **/
	public function back():Void {
		for (frame in receiver.take()) {
			sender.__acceptFrame(frame);
		}
	}
}

@:access(crossbyte.net.ReliableDatagramSocket)
private class RecordingRudp extends ReliableDatagramSocket {
	var __recorded:Array<ByteArray> = [];

	public static function ready():RecordingRudp {
		final socket = new RecordingRudp();
		socket.__connected = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		return socket;
	}

	public function new() {
		super();
	}

	/** Every frame sent since the last call, decoded, the acknowledgement owed included. **/
	public function take():Array<ReliableDatagramFrame> {
		__sendBundle();
		final frames = [for (bytes in __recorded) ReliableDatagramProtocol.decode(bytes)];
		__recorded = [];
		return frames;
	}

	override private function __sendFrame(type:ReliableDatagramFrameType, sequence:crossbyte.Seq32, payload:ByteArray, offset:Int, length:Int,
			resend:Bool, ack:Int, hasAck:Bool, more:Bool, graceful:Bool = false):Void {
		final frame = new ByteArray();
		frame.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		frame.length = ReliableDatagramProtocol.encodeInto(frame, type, sequence, payload, offset, length, resend, ack, hasAck, more, 0, graceful);
		__recorded.push(frame);
	}
}

private class DeliveryCommands extends RPCCommands {
	public function new() {}

	@:rpc public function note(value:Int):Void {}

	@:rpc public function blob(data:Bytes):Void {}

	@:rpc public function names(list:Array<String>):Void {}

	@:rpc public function ask(value:Int):RPCResponse<Int> {}

	@:rpc public function echo(data:Bytes):RPCResponse<Bytes> {}
}

private class DeliveryHandler extends RPCHandler {
	public final notes:Array<Int> = [];

	public function new() {}

	@:rpc public function note(value:Int):Void {
		notes.push(value);
	}

	@:rpc public function blob(data:Bytes):Void {}

	@:rpc public function names(list:Array<String>):Void {}

	@:rpc public function ask(value:Int):Int {
		return value;
	}

	@:rpc public function echo(data:Bytes):Bytes {
		return data;
	}
}
