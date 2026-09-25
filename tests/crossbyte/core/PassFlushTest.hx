package crossbyte.core;

import crossbyte.core._internal.PassFlush;
import utest.Assert;

/**
	The runtime's end of a pass: what asked to be flushed is flushed once, in
	the order it asked, including anything that asks while the flush is under
	way, and a flush that throws does not take the rest with it.
**/
@:access(crossbyte.core.CrossByte)
class PassFlushTest extends utest.Test {
	public function testWhatAskedIsFlushedOnceWhenThePassEnds():Void {
		var runtime = CrossByte.current();
		var flushed:Array<String> = [];
		runtime.__queuePassFlush(new Holder("first", flushed));
		runtime.__queuePassFlush(new Holder("second", flushed));
		Assert.same([], flushed, "flushed before the pass ended");

		runtime.pump(0, 0);
		Assert.same(["first", "second"], flushed);

		runtime.pump(0, 0);
		Assert.same(["first", "second"], flushed, "flushed again without asking again");
	}

	public function testWhatAsksDuringTheFlushIsFlushedInTheSamePass():Void {
		var runtime = CrossByte.current();
		var flushed:Array<String> = [];
		var late = new Holder("late", flushed);
		runtime.__queuePassFlush(new Holder("early", flushed, () -> runtime.__queuePassFlush(late)));

		runtime.pump(0, 0);
		Assert.same(["early", "late"], flushed);
	}

	public function testAFlushThatThrowsLeavesTheRestForTheNextPass():Void {
		var runtime = CrossByte.current();
		var flushed:Array<String> = [];
		runtime.__queuePassFlush(new Holder("throws", flushed, () -> throw "a handler's own bug"));
		runtime.__queuePassFlush(new Holder("after", flushed));

		Assert.raises(() -> runtime.pump(0, 0));
		Assert.same(["throws"], flushed);

		runtime.pump(0, 0);
		Assert.same(["throws", "after"], flushed, "the one after the throw was lost");

		runtime.pump(0, 0);
		Assert.same(["throws", "after"], flushed);
	}

	public function testTheTickIsInsideThePass():Void {
		// Sent from a tick handler, gone by the time the pump returns.
		var runtime = CrossByte.current();
		var flushed:Array<String> = [];
		var holder = new Holder("from a tick", flushed);
		var onTick:crossbyte.events.TickEvent->Void = null;
		onTick = _ -> {
			runtime.removeEventListener(crossbyte.events.TickEvent.TICK, onTick);
			runtime.__queuePassFlush(holder);
		};
		runtime.addEventListener(crossbyte.events.TickEvent.TICK, onTick);

		runtime.pump(0, 0);
		Assert.same(["from a tick"], flushed);
	}

	public function testWhatASocketHandlerAsksForIsFlushedBeforeThePumpReturns():Void {
		// The answer to what arrived goes before the loop waits again, not a
		// pass later: acknowledgements are sent from here.
		if (!crossbyte.net.DatagramSocket.isSupported) {
			Assert.isFalse(crossbyte.net.DatagramSocket.isSupported);
			return;
		}
		var runtime = CrossByte.current();
		var flushed:Array<String> = [];
		var listener = new crossbyte.net.DatagramSocket();
		var sender = new crossbyte.net.DatagramSocket();
		var handled = false;
		var flushedWhenHandled = false;

		try {
			listener.bind(0, "127.0.0.1");
			listener.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, _ -> {
				handled = true;
				runtime.__queuePassFlush(new Holder("answer", flushed));
			});
			listener.receive();
			sender.send(bytes("ping"), 0, 0, "127.0.0.1", listener.localPort);

			var deadline = haxe.Timer.stamp() + 3;
			while (!handled && haxe.Timer.stamp() < deadline) {
				runtime.pump(0, 0.01);
				if (handled) {
					flushedWhenHandled = flushed.length > 0;
				}
			}
			Assert.isTrue(handled, "the datagram never arrived");
			Assert.isTrue(flushedWhenHandled, "what the handler asked for waited for another pass");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try listener.close() catch (_:Dynamic) {}
		try sender.close() catch (_:Dynamic) {}
	}

	public function testWhatATickAsksForIsFlushedBeforeSocketsArePolled():Void {
		// A poll can wait out the rest of the frame, so a message sent from a
		// tick handler goes before it rather than after.
		if (!crossbyte.net.DatagramSocket.isSupported) {
			Assert.isFalse(crossbyte.net.DatagramSocket.isSupported);
			return;
		}
		var runtime = CrossByte.current();
		var flushed:Array<String> = [];
		var listener = new crossbyte.net.DatagramSocket();
		var sender = new crossbyte.net.DatagramSocket();
		var tickFlushedByPoll:Null<Bool> = null;
		var onTick:crossbyte.events.TickEvent->Void = null;

		try {
			listener.bind(0, "127.0.0.1");
			listener.addEventListener(crossbyte.events.DatagramSocketDataEvent.DATA, _ -> {
				if (tickFlushedByPoll == null) {
					tickFlushedByPoll = flushed.indexOf("from a tick") >= 0;
				}
			});
			listener.receive();
			onTick = _ -> {
				runtime.removeEventListener(crossbyte.events.TickEvent.TICK, onTick);
				runtime.__queuePassFlush(new Holder("from a tick", flushed));
			};

			// Already waiting when the pass begins, so the poll that follows
			// the tick finds it.
			sender.send(bytes("waiting"), 0, 0, "127.0.0.1", listener.localPort);
			Sys.sleep(0.05);
			runtime.addEventListener(crossbyte.events.TickEvent.TICK, onTick);

			var deadline = haxe.Timer.stamp() + 3;
			while (tickFlushedByPoll == null && haxe.Timer.stamp() < deadline) {
				runtime.pump(0, 0.01);
			}
			Assert.equals(true, tickFlushedByPoll, "the tick's flush waited for the poll");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try runtime.removeEventListener(crossbyte.events.TickEvent.TICK, onTick) catch (_:Dynamic) {}
		try listener.close() catch (_:Dynamic) {}
		try sender.close() catch (_:Dynamic) {}
	}

	private static function bytes(text:String):crossbyte.io.ByteArray {
		var bytes = new crossbyte.io.ByteArray();
		bytes.writeUTFBytes(text);
		bytes.position = 0;
		return bytes;
	}
}

private class Holder implements PassFlush {
	private var name:String;
	private var into:Array<String>;
	private var then:Null<Void->Void>;

	public function new(name:String, into:Array<String>, ?then:Void->Void) {
		this.name = name;
		this.into = into;
		this.then = then;
	}

	public function __flushPass():Void {
		into.push(name);
		if (then != null) {
			then();
		}
	}
}
