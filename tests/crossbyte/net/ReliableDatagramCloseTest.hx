package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import haxe.Timer;
import utest.Assert;

/**
	How a reliable session closes.

	`close()` sent the frames gathered in the pass and a FIN, and disposed:
	whatever the congestion window held back, whatever had been lost and was
	waiting to be sent again, and stream bytes not yet flushed went nowhere.
	The FIN carried no sequence, so the receiver closed the moment it came,
	throwing away anything held past a gap -- and a FIN overtaking a lost
	frame took that frame with it.

	A close is graceful now: what was sent goes, a FIN follows in the same
	sequence, and the receiver closes only once everything before the FIN has
	been delivered. `abort()` keeps the old way for whoever needs it.

	Two real sessions whose frames are carried across by hand, so a case says
	exactly what the network loses; only the datagram leaving is replaced.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramCloseTest extends utest.Test {
	// ------------------------------------------------------------ graceful

	public function testDataSentJustBeforeCloseArrivesInFullAndInOrderThenClose():Void {
		var link = Link.make();
		if (link == null) return;

		// More than the window of ten takes, so some wait behind it.
		var sent:Array<String> = [for (i in 0...25) "m" + i];
		for (message in sent) {
			link.a.send(text(message));
		}
		Assert.isTrue(link.a.bufferedAmount > 0, "nothing was waiting for the window, so nothing was tested");

		// Two lost on their first trip.
		link.lose = ["PACKET 1002", "PACKET 1007"];
		link.a.close();
		Assert.isFalse(link.a.connected, "a session closing still said it was connected");
		link.run();

		Assert.same(["PACKET 1002", "PACKET 1007"], link.lost, "the loss the case is about never happened");
		var expected:Array<String> = [for (message in sent) "b data " + message];
		expected.push("b close");
		expected.push("a close");
		Assert.same(expected, link.log);
	}

	public function testAFinThatOvertakesALostFrameWaitsForIt():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.send(text("first"));
		link.a.send(text("lost on the way"));
		link.a.send(text("last"));
		link.a.close();

		// The FIN arrives behind a gap, and is held until it fills.
		link.lose = ["PACKET 1001"];
		link.run();

		Assert.same(["PACKET 1001"], link.lost);
		Assert.same(["b data first", "b data lost on the way", "b data last", "b close", "a close"], link.log);
	}

	public function testStreamBytesNotYetFlushedGoBeforeTheFin():Void {
		var link = Link.make(STREAM);
		if (link == null) return;

		link.a.writeUTFBytes("written and never flushed");
		Assert.isTrue(link.a.bytesPending > 0);
		link.a.close();
		link.run();

		Assert.same(["b data written and never flushed", "b close", "a close"], link.log);
	}

	public function testAClosedStreamHasNothingLeftToRead():Void {
		var link = Link.make(STREAM);
		if (link == null) return;

		// Arrived and never read, then closed.
		link.b.writeUTFBytes("unread");
		link.b.flush();
		link.a.removeAllListeners();
		for (frame in link.b.take()) {
			link.a.__acceptFrame(frame);
		}
		Assert.equals(6, link.a.bytesAvailable);

		link.a.close();
		Assert.equals(0, link.a.bytesAvailable, "a closed stream still said it had bytes to read");
		Assert.raises(() -> link.a.readUTFBytes(1), IOError);
		link.a.abort();
		link.b.abort();
	}

	public function testALostFinIsSentAgain():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.send(text("before"));
		link.a.close();
		link.lose = ["FIN 1001"];
		link.run();

		Assert.same(["FIN 1001"], link.lost);
		Assert.same(["b data before", "b close", "a close"], link.log);
	}

	public function testTheFinIsAcknowledgedBeforeTheReceiverGoes():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.close();
		var fin = link.a.take();
		Assert.same(["FIN 1000 graceful"], described(fin));

		for (frame in fin) {
			link.b.__acceptFrame(frame);
		}
		Assert.same(["b close"], link.log);
		// Its last word, without which the closing side waits out its
		// deadline: the acknowledgement, past the FIN.
		Assert.same(["ACK 1001"], described(link.b.take()));
	}

	public function testBothSidesClosingAtOnceBothEnd():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.send(text("from a"));
		link.b.send(text("from b"));
		link.a.close();
		link.b.close();
		link.run();

		Assert.isTrue(link.a.__closed && link.b.__closed, "a simultaneous close left a session open: " + link.log.join(", "));
		Assert.isTrue(link.log.indexOf("a ioError") < 0 && link.log.indexOf("b ioError") < 0, "a simultaneous close failed: " + link.log.join(", "));
		Assert.equals(1, count(link.log, "a close"));
		Assert.equals(1, count(link.log, "b close"));
	}

	public function testAClosingSessionTakesNothingMoreAndPassesNothingOn():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.close();
		Assert.isFalse(link.a.connected);
		Assert.raises(() -> link.a.send(text("too late")), IOError);
		// Nor started again while the close waits.
		Assert.raises(() -> link.a.connect("127.0.0.1", 9), IOError);
		link.a.take();

		// The peer, not yet aware, sends something: acknowledged, so it is
		// not sent again, and not delivered.
		link.b.send(text("not heard"));
		for (frame in link.b.take()) {
			link.a.__acceptFrame(frame);
		}
		var answer = described(link.a.take());
		Assert.same(["ACK 5001"], answer, "what arrived after close() was not acknowledged");
		Assert.same([], link.log, "what arrived after close() was passed on");

		// And calling it again changes nothing.
		link.a.close();
		Assert.same([], described(link.a.take()));
		link.a.abort();
		link.b.abort();
	}

	public function testAPeerThatNeverAcknowledgesDoesNotHoldTheCloseForever():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.closeTimeout = 0.15;
		link.a.send(text("into the void"));
		var started:Float = Timer.stamp();
		link.a.close();
		pumpUntil(() -> link.a.__closed, 3.0);
		var took:Float = Timer.stamp() - started;

		Assert.isTrue(link.a.__closed, "a close waiting on a silent peer never ended");
		Assert.isTrue(took >= 0.14, 'gave the peer up after $took s against a closeTimeout of 0.15 s');
		Assert.same(["a ioError", "a close"], link.log, "what was never acknowledged went without a word");

		// The peer is told at once, rather than left holding a gap: the last
		// frame is a FIN of the abortive kind.
		var frames = link.a.take();
		Assert.isTrue(frames.length > 0);
		if (frames.length > 0) {
			var last = frames[frames.length - 1];
			Assert.equals(ReliableDatagramFrameType.FIN, last.type);
			Assert.isFalse(last.graceful, "the FIN sent on giving up still waited for a gap to fill");
		}
	}

	public function testOnlyTheFinUnacknowledgedClosesWithoutAnError():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.send(text("arrived"));
		link.exchange();
		Assert.same(["b data arrived"], link.log);

		// Everything arrived; only the close itself goes unanswered.
		link.a.closeTimeout = 0.1;
		link.a.close();
		link.a.take();
		pumpUntil(() -> link.a.__closed, 3.0);

		Assert.same(["b data arrived", "a close"], link.log);
	}

	public function testAPeerStillAcknowledgingKeepsTheCloseWaiting():Void {
		var link = Link.make();
		if (link == null) return;

		// The deadline runs from the last progress, not the call: a queue
		// draining slowly but steadily is not cut off.
		link.a.closeTimeout = 0.25;
		for (i in 0...6) {
			link.a.send(text("slow " + i));
		}
		link.a.close();
		var outbound:Array<ReliableDatagramFrame> = link.a.take();
		Assert.equals(7, outbound.length, "six frames and the FIN were not all sent");

		for (frame in outbound) {
			pumpFor(0.12);
			link.a.take();
			link.b.__acceptFrame(frame);
			for (ack in link.b.take()) {
				link.a.__acceptFrame(ack);
			}
		}

		Assert.isTrue(link.a.__closed, "the close never finished");
		Assert.equals(-1, link.log.indexOf("a ioError"), "a peer acknowledging every 0.12 s was given up at 0.25: " + link.log.join(", "));
		Assert.equals("a close", link.log[link.log.length - 1]);
	}

	public function testAZeroCloseTimeoutWaitsForThePeer():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.closeTimeout = 0;
		link.a.close();
		pumpFor(0.3);

		Assert.isFalse(link.a.__closed, "a close with no deadline gave up");
		link.a.abort();
		Assert.isTrue(link.a.__closed);
	}

	public function testANegativeCloseTimeoutIsRefused():Void {
		var link = Link.make();
		if (link == null) return;

		Assert.raises(() -> link.a.closeTimeout = -1, crossbyte.errors.RangeError);
		Assert.equals(ReliableDatagramSocket.DEFAULT_CLOSE_TIMEOUT, link.a.closeTimeout);
		link.a.abort();
		link.b.abort();
	}

	public function testAPeerThatEndsTheSessionEndsAWaitingClose():Void {
		var link = Link.make();
		if (link == null) return;

		link.a.send(text("unacknowledged"));
		link.a.close();
		link.a.take();

		// The peer aborts, as a server shutting down does.
		link.b.abort();
		for (frame in link.b.take()) {
			link.a.__acceptFrame(frame);
		}

		Assert.isTrue(link.a.__closed);
		Assert.same(["b close", "a ioError", "a close"], link.log);
	}

	// --------------------------------------------------------------- abort

	public function testAbortEndsBothSidesAtOnce():Void {
		var link = Link.make();
		if (link == null) return;

		for (i in 0...3) {
			link.a.send(text("m" + i));
		}
		link.a.abort();
		Assert.same(["a close"], link.log, "abort() did not close at once");

		// The FIN ends the peer's session as it arrives, gap or none.
		var frames = link.a.take();
		Assert.same(["PACKET 1000", "PACKET 1001", "PACKET 1002", "FIN 0"], described(frames));
		link.b.__acceptFrame(frames[0]);
		link.b.__acceptFrame(frames[2]);
		link.b.__acceptFrame(frames[3]);
		Assert.same(["a close", "b data m0", "b close"], link.log);
	}

	// ------------------------------------------------------------- helpers

	private static function count(log:Array<String>, entry:String):Int {
		var found = 0;
		for (line in log) {
			if (line == entry) {
				found++;
			}
		}
		return found;
	}

	private static function described(frames:Array<ReliableDatagramFrame>):Array<String> {
		return [for (frame in frames) Link.describe(frame) + (frame.graceful ? " graceful" : "")];
	}

	private static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	/** Runs the runtime's timers, at the wall clock's pace, until `done` or `timeout` seconds. **/
	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var last:Float = Timer.stamp();
		var deadline:Float = last + timeout;
		while (!done() && Timer.stamp() < deadline) {
			var now:Float = Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			crossbyte.sys.System.sleep(0.002);
		}
	}

	private static function pumpFor(seconds:Float):Void {
		pumpUntil(() -> false, seconds);
	}
}

/**
	Two connected sessions, `a` and `b`, whose frames are carried across by
	`exchange`. `a` starts its sequence at 1000 and `b` at 5000. Everything
	each dispatches goes into `log`, prefixed with its name.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
private class Link {
	public var a:TapSocket;
	public var b:TapSocket;
	public var log:Array<String> = [];

	/** Frames, as `describe` names them, to lose: once each time one is listed. **/
	public var lose:Array<String> = [];

	/** What was lost, in order. **/
	public var lost:Array<String> = [];

	public static function make(mode:ReliableDatagramSocketMode = DATAGRAM):Link {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		return new Link(mode);
	}

	private function new(mode:ReliableDatagramSocketMode) {
		a = TapSocket.make("a", 1000, 5000, log, mode);
		b = TapSocket.make("b", 5000, 1000, log, mode);
	}

	public static function describe(frame:ReliableDatagramFrame):String {
		var type:String = switch (frame.type) {
			case CONNECT: "CONNECT";
			case HANDSHAKE: "HANDSHAKE";
			case PACKET: "PACKET";
			case ACK: "ACK";
			case FIN: "FIN";
			case UNRELIABLE: "UNRELIABLE";
			case SEQUENCED: "SEQUENCED";
			case _: "?";
		}
		return type + " " + (frame.sequence : Int);
	}

	/** What `a` has sent goes to `b`, and then what `b` has sent to `a`, less what `lose` names. **/
	public function exchange():Void {
		carry(a.take(), b);
		carry(b.take(), a);
	}

	private function carry(frames:Array<ReliableDatagramFrame>, to:TapSocket):Void {
		for (frame in frames) {
			var index:Int = lose.indexOf(describe(frame));
			if (index >= 0) {
				lose.splice(index, 1);
				lost.push(describe(frame));
				continue;
			}
			to.__acceptFrame(frame);
		}
	}

	/**
		Exchanges until both have closed, at most `rounds` times, giving each
		side's retransmission clock the time to find what was lost between.
	**/
	public function run(rounds:Int = 300):Void {
		for (_ in 0...rounds) {
			exchange();
			if (a.__closed && b.__closed) {
				return;
			}
			var until:Float = Timer.stamp() + 0.012;
			while (Timer.stamp() < until) {}
			if (!a.__closed) {
				a.__checkRetransmits();
			}
			if (!b.__closed) {
				b.__checkRetransmits();
			}
		}
	}
}

/** A connected session whose frames are recorded instead of sent. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class TapSocket extends ReliableDatagramSocket {
	private var __recorded:Array<ByteArray> = [];

	public static function make(name:String, out:Int, inbound:Int, log:Array<String>, mode:ReliableDatagramSocketMode):TapSocket {
		var socket = new TapSocket();
		socket.__mode = mode;
		socket.__connected = true;
		socket.__peerConfirmed = true;
		socket.__remoteAddress = "127.0.0.1";
		socket.__remotePort = 9;
		socket.__outSequence = out;
		socket.__windowBase = out;
		socket.__firstSequence = out;
		socket.__inSequence = inbound;
		socket.addEventListener(DatagramSocketDataEvent.DATA, e -> log.push(name + " data " + e.data.toString()));
		socket.addEventListener(ProgressEvent.SOCKET_DATA, _ -> log.push(name + " data " + socket.readUTFBytes(socket.bytesAvailable)));
		socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> log.push(name + " ioError"));
		socket.addEventListener(Event.CLOSE, _ -> log.push(name + " close"));
		return socket;
	}

	public function new() {
		super();
	}

	/** Every frame sent since the last call, and whatever the pass owes. **/
	public function take():Array<ReliableDatagramFrame> {
		__sendBundle();
		var frames = [for (bytes in __recorded) ReliableDatagramProtocol.decode(bytes)];
		__recorded = [];
		return frames;
	}

	override private function __sendFrame(type:ReliableDatagramFrameType, sequence:Seq32, payload:ByteArray, offset:Int, length:Int, resend:Bool,
			ack:Null<Seq32>, more:Bool, graceful:Bool = false):Void {
		var frame = new ByteArray();
		frame.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;
		frame.length = ReliableDatagramProtocol.encodeInto(frame, type, sequence, payload, offset, length, resend, ack, more, 0, graceful);
		__recorded.push(frame);
	}
}
