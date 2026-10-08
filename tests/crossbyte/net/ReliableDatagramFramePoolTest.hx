package crossbyte.net;

import crossbyte.Seq32;
import crossbyte.core.CrossByte;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.FramePool;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	What a reliable session keeps a message in until its peer acknowledges
	it: a frame from a pool (`FramePool`), the message copied into the
	frame's own buffer, and the frame given back once acknowledged, for the
	next message. A steady flow allocates nothing for its messages, as
	`AllocationBudgetTest`'s reliable UDP line holds it to; these cases are
	what reusing them must never cost, a message sent with another's
	bytes, a caller's buffer changed under a resend, a pool that keeps
	growing, or one that keeps too little for a game's ticks.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net._internal.reliable.FramePool)
class ReliableDatagramFramePoolTest extends utest.Test {
	public function testAnAcknowledgedMessagesFrameCarriesTheNext():Void {
		var sender = PoolWire.make();
		if (sender == null) return;

		sender.send(message(200, 1));
		var first = Require.notNull(sender.__outFrameCache.get(1000), "the message was not kept to be sent again");
		sender.take();
		sender.__acceptFrame(ack(1001));
		Assert.equals(0, sender.__pool().inUse, "an acknowledged message's frame was not given back");
		Assert.equals(1, sender.__pool().idle);

		// A shorter message, of the same class: the same frame, carrying its
		// own bytes and none of the first's.
		sender.send(message(150, 2));
		var second = Require.notNull(sender.__outFrameCache.get(1001));
		Assert.isTrue(first == second, "the next message did not take the frame given back");
		Assert.equals(1, sender.__pool().made, "a frame was made for a message with one waiting");
		var sent = sender.take();
		Assert.equals(1, sent.length);
		Assert.same(bytesOf(message(150, 2)), bytesOf(sent[0].payload), "the frame went with bytes that were not its message's");
		sender.abort();
	}

	public function testTheCallersBytesMayChangeOnceSendReturns():Void {
		var sender = PoolWire.make();
		if (sender == null) return;

		var buffer = message(300, 7);
		sender.send(buffer);
		sender.take();
		// Written over at once, as a caller reusing its buffer does.
		for (i in 0...buffer.length) {
			(buffer : Bytes).set(i, 0xEE);
		}
		// Lost, and sent again from what the session kept.
		Require.notNull(sender.__outFrameCache.get(1000)).deadline = 0;
		sender.__checkRetransmits();
		var resent = sender.take();
		Assert.equals(1, resent.length);
		Assert.isTrue(resent[0].resend);
		Assert.same(bytesOf(message(300, 7)), bytesOf(resent[0].payload), "the resend carried the caller's bytes as they were changed");
		sender.abort();
	}

	public function testEachFrameIsCopiedIntoTheSmallestBufferThatHoldsIt():Void {
		Assert.same([64, 128, 256, 512, 768, 1024, ReliableDatagramProtocol.MAX_PAYLOAD_SIZE], [for (c in 0...7) FramePool.capacityOf(c)]);
		var pool = new FramePool();
		var lengths = [1, 64, 65, 128, 129, 256, 257, 512, 513, 768, 769, 1024, 1025, ReliableDatagramProtocol.MAX_PAYLOAD_SIZE];
		var capacities = [64, 64, 128, 128, 256, 256, 512, 512, 768, 768, 1024, 1024, 1200, 1200];
		Assert.same(capacities, [for (length in lengths) pool.take(length).buffer.length]);

		// A message larger than a frame, split: two whole frames and the rest,
		// each in a buffer of its own size.
		var sender = PoolWire.make();
		if (sender == null) return;
		var big = message(2500, 3);
		sender.send(big);
		var sizes = [for (s in 1000...1003) Require.notNull(sender.__outFrameCache.get(s)).buffer.length];
		Assert.same([1200, 1200, 128], sizes);
		var sent = sender.take();
		var joined = new ByteArray();
		for (frame in sent) {
			joined.writeBytes(frame.payload, 0, frame.payload.length);
		}
		Assert.same(bytesOf(big), bytesOf(joined), "the message split into frames was not the message");
		Assert.same([true, true, false], [for (frame in sent) frame.more]);
		sender.abort();
	}

	/**
		A game server's tick sends to every session and has it all back
		before the next: what is in use goes from a thousand to none, every
		tick. Every frame is kept for the next tick, a pool that kept only
		what was in use as each came back kept half, and made the other half
		again every tick, and once the ticks shrink, what was kept for them
		goes, within two periods; once nothing comes back for a while, all but
		the spare goes.
	**/
	public function testAPoolKeepsWhatWasInUseLatelyAndLetsTheRestGo():Void {
		var pool = new FramePool();
		var now:Float = 100.0;
		function tick(count:Int):Void {
			var frames = [for (_ in 0...count) pool.take(200)];
			for (frame in frames) {
				pool.give(frame, now);
			}
			now += 1 / 30;
		}
		for (_ in 0...30) {
			tick(1000);
		}
		Assert.equals(1000, pool.made, "the ticks made frames when the ones before had come back");
		Assert.equals(0, pool.inUse);
		Assert.equals(1000, pool.idle);

		// Ten a tick, for a minute: the pool keeps those and the spare.
		for (_ in 0...30 * 60) {
			tick(10);
		}
		Assert.isTrue(pool.idle <= 10 + FramePool.SPARE, 'after the traffic fell to ten a tick the pool kept ${pool.idle}');
		Assert.equals(1000, pool.made, "the smaller ticks made frames");

		// Nothing in use and nothing back for a while: down to the spare.
		var last:Float = now;
		var kept:Int = pool.idle;
		pool.quiet(last + FramePool.QUIET_PERIOD / 2);
		Assert.equals(kept, pool.idle, "a pool let frames go while traffic was recent");
		var burst = [for (_ in 0...200) pool.take(64)];
		for (frame in burst) {
			pool.give(frame, last);
		}
		Assert.isTrue(pool.idle > FramePool.SPARE);
		pool.quiet(last + FramePool.QUIET_PERIOD + 1);
		Assert.equals(FramePool.SPARE, pool.idle, "a quiet pool kept more than the spare");
		// A frame that is still out is not let go under it.
		var out = pool.take(64);
		pool.quiet(last + FramePool.QUIET_PERIOD * 3);
		Assert.equals(FramePool.SPARE - 1, pool.idle);
		pool.give(out, last + FramePool.QUIET_PERIOD * 3);
	}

	public function testAnEndedSessionGivesItsFramesBack():Void {
		var sender = PoolWire.make();
		if (sender == null) return;

		// Ten in flight, and five waiting for the window.
		for (i in 0...15) {
			sender.send(message(100, i));
		}
		Assert.equals(15, sender.__pool().inUse);
		sender.abort();
		Assert.equals(0, sender.__pool().inUse, "an ended session's frames were not given back");
		Assert.equals(15, sender.__pool().idle);
	}

	public function testAServersSessionsShareItsPool():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}
		#if nodejs
		// A real pair needs Node's event loop, which a case pumping the
		// runtime itself never gives back to; which pool a session takes is
		// the same code there.
		Assert.pass();
		return;
		#end
		var server = new ReliableDatagramServerSocket();
		var accepted:Array<ReliableDatagramSocket> = [];
		var clients = [new ReliableDatagramSocket(), new ReliableDatagramSocket()];
		try {
			server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted.push(e.socket));
			server.bind(0, "127.0.0.1");
			server.listen();
			for (client in clients) {
				client.connect("127.0.0.1", server.localPort);
			}
			pumpUntil(() -> accepted.length == 2 && clients[0].connected && clients[1].connected, 3.0);
			Assert.equals(2, accepted.length, "the sessions never connected");
			if (accepted.length == 2) {
				var shared = server.__framePool();
				Assert.isTrue(accepted[0].__pool() == shared && accepted[1].__pool() == shared, "a server's sessions took frames from pools of their own");
				Assert.isTrue(clients[0].__pool() != shared && clients[0].__pool() != clients[1].__pool(), "a client shared a pool");
				// And the scratch a HANDSHAKE's and an ACK's payload are written
				// into, copied out at once: the server's, not one a session.
				Assert.isTrue(accepted[0].__echoBuffer() == accepted[1].__echoBuffer() && accepted[0].__echoBuffer() == server.__echoScratch);
				Assert.isTrue(accepted[0].__sackBuffer() == accepted[1].__sackBuffer() && accepted[0].__sackBuffer() == server.__sackScratch);
				Assert.isTrue(clients[0].__echoBuffer() != clients[1].__echoBuffer(), "two clients shared a scratch");
				// One the server dials, to a port nobody answers on.
				var dialled = server.connect("127.0.0.1", 9, 1000);
				Assert.isTrue(dialled.__pool() == shared, "a session the server dialled took frames from a pool of its own");
				dialled.abort();
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		for (client in clients) {
			try client.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}

	// ------------------------------------------------------------- helpers

	private static function message(length:Int, seed:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		for (i in 0...length) {
			(bytes : Bytes).set(i, (i * 31 + seed * 7) & 0xFF);
		}
		return bytes;
	}

	private static function bytesOf(bytes:ByteArray):Array<Int> {
		return [for (i in 0...bytes.length) (bytes : Bytes).get(i)];
	}

	private static function ack(value:Int):ReliableDatagramFrame {
		return new ReliableDatagramFrame(ACK, value, new ByteArray(), false);
	}

	private static var __last:Float = -1;

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now = haxe.Timer.stamp();
			if (__last < 0) {
				__last = now;
			}
			crossbyte.sys.System.sleep(0.001);
			CrossByte.current().pump(now - __last, 0);
			__last = now;
		}
	}
}

/**
	A connected session whose frames are recorded instead of sent, with every
	sequence pinned: its own start at 1000, and the peer's at 1000 too.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
private class PoolWire extends ReliableDatagramSocket {
	private var __recorded:Array<ByteArray> = [];

	/** One ready to send, or null where this target has no datagrams. **/
	public static function make():PoolWire {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return null;
		}
		var socket = new PoolWire();
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

	/** Every frame recorded since the last call, and what the pass owes. **/
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
}
