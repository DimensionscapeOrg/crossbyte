package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.net._internal.reliable.ResetBudget;
import utest.Assert;

/**
	What a reliable datagram server sends to addresses that hold no session
	with it: the resets it answers their frames with, held to one allowance
	for the process.
**/
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramJoinTest extends utest.Test {
	// ------------------------------------------------------------- resets

	/**
		A frame from an address with no session draws a FIN. One was sent for
		every such frame, however many came: a sender naming someone else's
		address could have the server send that address a datagram for each
		it sent. Now the process holds them to `maxResetsPerSecond`.
	**/
	public function testResetsToStrangersAreHeldToTheProcessAllowance():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var stranger = new DatagramSocket();
		var resets:Int = 0;
		var before:Int = ReliableDatagramServerSocket.maxResetsPerSecond;

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			stranger.bind(0, "127.0.0.1");
			try stranger.receiveBufferSize = 1 << 20 catch (_:Dynamic) {}
			stranger.addEventListener(DatagramSocketDataEvent.DATA, e -> {
				var frame = ReliableDatagramProtocol.decode(e.data);
				if (frame != null && frame.type == ReliableDatagramFrameType.FIN) {
					resets++;
				}
			});
			stranger.receive();

			ReliableDatagramServerSocket.maxResetsPerSecond = 50;
			ResetBudget.refill();
			var started:Float = haxe.Timer.stamp();

			// Frames as a session sends them, from an address the server has
			// never heard of: each one draws a reset, as far as the allowance
			// goes.
			var frame = ReliableDatagramProtocol.encode(PACKET, 1, bytesOf("x"), false, 1);
			for (i in 0...600) {
				stranger.send(frame, 0, frame.length, "127.0.0.1", server.localPort);
				if (i % 50 == 49) {
					CrossByte.current().pump(0, 0);
				}
			}
			pumpUntil(() -> false, 0.3);
			var took:Float = haxe.Timer.stamp() - started;

			// A full bucket's worth at once, and what it refilled since.
			var allowed:Float = 50 + took * 50 + 2;
			Assert.isTrue(resets >= 40, 'the first $resets resets were not let through at once');
			Assert.isTrue(resets <= allowed, '$resets resets were sent in $took s, past the allowance of $allowed');

			// The allowance comes back with time.
			var then:Int = resets;
			pumpUntil(() -> false, 0.2);
			for (_ in 0...20) {
				stranger.send(frame, 0, frame.length, "127.0.0.1", server.localPort);
			}
			pumpUntil(() -> resets > then, 1.0);
			Assert.isTrue(resets > then, 'no reset was sent once the allowance had filled again ($then before, $resets after; first phase $took s)');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		ReliableDatagramServerSocket.maxResetsPerSecond = before;
		ResetBudget.refill();
		try server.close() catch (_:Dynamic) {}
		try stranger.close() catch (_:Dynamic) {}
	}

	/** Negative lifts the limit, and 0 sends none. **/
	public function testTheAllowanceCanBeLiftedOrClosed():Void {
		var before:Int = ReliableDatagramServerSocket.maxResetsPerSecond;
		var now:Float = haxe.Timer.stamp();

		ResetBudget.refill();
		var taken:Int = 0;
		for (_ in 0...5000) {
			if (ResetBudget.take(-1, now)) {
				taken++;
			}
		}
		Assert.equals(5000, taken, "a negative allowance held resets back");

		taken = 0;
		for (_ in 0...10) {
			if (ResetBudget.take(0, now)) {
				taken++;
			}
		}
		Assert.equals(0, taken, "an allowance of 0 let a reset through");

		// A full bucket is one second's worth, and no more however long it
		// has been idle.
		ResetBudget.refill();
		taken = 0;
		for (_ in 0...30) {
			if (ResetBudget.take(10, now)) {
				taken++;
			}
		}
		Assert.equals(10, taken);
		taken = 0;
		for (_ in 0...30) {
			if (ResetBudget.take(10, now + 100)) {
				taken++;
			}
		}
		Assert.equals(10, taken, "an idle bucket filled past one second's worth");
		// Half a second refills half of it.
		taken = 0;
		for (_ in 0...30) {
			if (ResetBudget.take(10, now + 100.5)) {
				taken++;
			}
		}
		Assert.equals(5, taken);

		ReliableDatagramServerSocket.maxResetsPerSecond = before;
		ResetBudget.refill();
	}

	// ------------------------------------------------------------- helpers

	private static function requireDatagramSupport():Bool {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return false;
		}
		return true;
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		var last = haxe.Timer.stamp();
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			crossbyte.sys.System.sleep(0.001);
		}
	}
}
