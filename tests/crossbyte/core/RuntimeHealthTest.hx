package crossbyte.core;

import crossbyte.events.TickEvent;
import haxe.Timer;
import utest.Assert;
#if target.threaded
import crossbyte._internal.socket.IPollableSocket;
import sys.net.Host;
import sys.net.Socket;
#end

/**
	What a runtime reports about itself: how much of each frame it spends
	working, how far behind its schedule it is, and what is waiting for it.

	The frames are run one at a time on a host-driven runtime, with the
	deadline placed where each case needs it, rather than timed on a live
	loop.
**/
@:access(crossbyte.core.CrossByte)
class RuntimeHealthTest extends utest.Test {
	#if target.threaded
	public function testAPollLoopCountsTheTimeItsSocketHandlersTake():Void {
		// The load was measured before the poll, so a POLL server's socket
		// handlers -- nearly all of what it does -- never counted: busy half
		// of every frame, it reported 0%.
		var busy = BusySocket.create(0.005);
		if (busy == null) {
			Assert.fail("could not open a loopback connection");
			return;
		}

		var runtime = new CrossByte(false, POLL, true);
		runtime.tps = 20;
		runtime.registerSocket(busy.reader);
		busy.poke();
		runtime.__frameDeadline = Timer.stamp() + runtime.__tickInterval;
		runtime.__pollBasedMainLoop();
		var load = runtime.cpuLoad;
		runtime.deregisterSocket(busy.reader);
		runtime.exit();
		busy.close();

		Assert.isTrue(busy.calls > 1, "the handler ran " + busy.calls + " times");
		Assert.isTrue(load >= 50, "a frame spent in socket handlers reported " + load + "% load");
	}

	public function testTimeBlockedInPollIsNotCountedAsWork():Void {
		// The other half of the same measurement: a POLL loop spends an idle
		// frame blocked in poll, which is waiting, not work.
		var idle = BusySocket.create(0.0);
		if (idle == null) {
			Assert.fail("could not open a loopback connection");
			return;
		}

		var runtime = new CrossByte(false, POLL, true);
		runtime.tps = 20;
		runtime.registerSocket(idle.reader);
		runtime.__frameDeadline = Timer.stamp() + runtime.__tickInterval;
		runtime.__pollBasedMainLoop();
		var load = runtime.cpuLoad;
		runtime.deregisterSocket(idle.reader);
		runtime.exit();
		idle.close();

		Assert.equals(0, idle.calls);
		Assert.isTrue(load < 25, "a frame spent blocked in poll reported " + load + "% load");
	}

	public function testWorkPostedDuringTheWaitCountsAsLoad():Void {
		// Posted callbacks the loop runs while waiting out its frame were
		// missing from the load as well.
		var runtime = new CrossByte(false, DEFAULT, true);
		runtime.tps = 20;
		runtime.__frameDeadline = Timer.stamp() + runtime.__tickInterval;
		runtime.__cpuTime = 0;
		runtime.post(() -> {
			var end = Timer.stamp() + 0.030;
			while (Timer.stamp() < end) {}
		});
		// The wait runs it, as it does work posted after the frame's tick.
		runtime.__wait(Timer.stamp());
		var load = runtime.cpuLoad;
		runtime.exit();

		Assert.isTrue(load >= 50, "30ms of posted work in a 50ms frame reported " + load + "% load");
	}

	public function testAFrameThatOutrunsItsTickIsCounted():Void {
		// Nothing said how far behind its schedule a loop was, or how often
		// a frame's work outran its tick.
		var runtime = new CrossByte(false, DEFAULT, true);
		runtime.tps = 20;
		// The frame was due to end 30ms ago, so its work left it no wait.
		runtime.__frameDeadline = Timer.stamp() - 0.030;
		runtime.__defaultMainLoop();
		var lag = runtime.loopLag;
		var overruns = runtime.frameOverruns;
		var dropped = runtime.droppedScheduleDebt;
		runtime.exit();

		Assert.equals(1, overruns);
		// Less a rounding: the clock reads as a large Float on some targets.
		Assert.isTrue(lag >= 0.0299, "a frame 30ms late reported a lag of " + lag + "s");
		// 30ms is repaid by the frames after it, not given up.
		Assert.equals(0.0, dropped);
	}

	public function testAFrameWithTimeToSpareIsNotAnOverrun():Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		runtime.tps = 20;
		runtime.__frameDeadline = Timer.stamp() + 0.030;
		runtime.__defaultMainLoop();
		var overruns = runtime.frameOverruns;
		var dropped = runtime.droppedScheduleDebt;
		runtime.exit();

		Assert.equals(0, overruns);
		Assert.equals(0.0, dropped);
	}

	public function testAStallTooLongToRepayIsCountedAsDropped():Void {
		// Past MAX_SCHEDULE_DEBT the schedule restarts from now rather than
		// running a burst of frames to catch up, and nothing recorded that
		// it had.
		var runtime = new CrossByte(false, DEFAULT, true);
		runtime.tps = 20;
		runtime.__frameDeadline = Timer.stamp() - 2.0;
		runtime.__defaultMainLoop();
		var dropped = runtime.droppedScheduleDebt;
		var ahead = runtime.__frameDeadline - Timer.stamp();
		runtime.exit();

		Assert.isTrue(dropped >= 1.95 && dropped < 3.0, "a 2s stall dropped " + dropped + "s");
		// And the schedule starts again from the present: one 50ms tick
		// away, give or take a rounding.
		Assert.isTrue(ahead > 0 && ahead < 0.0501, "the next deadline is " + ahead + "s away");
	}
	#end

	#if js
	/**
		The JavaScript loop is paced by the platform's timers rather than a
		wait of its own, so it notes lag and overruns where it takes a turn.
	**/
	@:timeout(5000)
	public function testTheJavaScriptLoopCountsAnOverrunAndTheLagAfterIt(async:utest.Async):Void {
		var runtime = new CrossByte(false, DEFAULT, true);
		runtime.tps = 50;
		var ticks = 0;
		var worstLag = 0.0;
		runtime.addEventListener(TickEvent.TICK, _ -> {
			ticks++;
			if (runtime.loopLag > worstLag) {
				worstLag = runtime.loopLag;
			}
			if (ticks == 3) {
				// More than two 20ms ticks' worth of work in one.
				var end = Timer.stamp() + 0.045;
				while (Timer.stamp() < end) {}
			}
		});
		runtime.__runEventLoop();

		js.Syntax.code("setTimeout({0}, 300)", () -> {
			var overruns = runtime.frameOverruns;
			runtime.exit();
			Assert.isTrue(ticks > 4, "the loop ticked " + ticks + " times");
			Assert.isTrue(overruns >= 1, "a 45ms frame at 20ms a tick was not an overrun");
			Assert.isTrue(worstLag >= 0.015, "the frame after a 45ms one reported a lag of " + worstLag + "s");
			async.done();
		});
	}
	#end

	public function testMemoryUsageIsReportedWhereThePlatformHasAFigure():Void {
		// It was 0 on every target but native, and natively the collector's
		// 32-bit figure, which wrapped negative past 2GiB.
		var used:Float = crossbyte.sys.System.memoryUsage();
		#if (cpp || java || jvm || nodejs)
		Assert.isTrue(used > 0, "memoryUsage is " + used);
		#else
		Assert.equals(0.0, used);
		#end
	}

	public function testPostedWorkIsCountedUntilItRuns():Void {
		// Nothing reported how much handed-over work was waiting.
		var runtime = new CrossByte(false, DEFAULT, true);
		var ran = 0;
		Assert.equals(0, runtime.postQueueDepth);
		for (_ in 0...3) {
			runtime.post(() -> ran++);
		}
		var queued = runtime.postQueueDepth;
		runtime.pump(1 / 60, 0);
		var after = runtime.postQueueDepth;
		runtime.exit();

		Assert.equals(3, queued);
		Assert.equals(0, after);
		Assert.equals(3, ran);
	}
}

#if target.threaded
/**
	The reading end of a loopback connection, as a socket the registry polls,
	whose handler spends `burn` seconds and leaves what it was sent unread --
	so once poked it stays readable, and a poll pass is all handler.
**/
private class BusySocket implements IPollableSocket {
	public var reader(default, null):Socket;
	public var calls(default, null):Int = 0;
	public var registryClosed(get, never):Bool;

	private var __writer:Socket;
	private var __burn:Float;
	private var __closed:Bool = false;

	public static function create(burn:Float):Null<BusySocket> {
		var listener:Socket = null;
		try {
			listener = new Socket();
			listener.bind(new Host("127.0.0.1"), 0);
			listener.listen(1);
			var writer = new Socket();
			writer.connect(new Host("127.0.0.1"), listener.host().port);
			var reader = listener.accept();
			listener.close();
			writer.setFastSend(true);
			reader.setBlocking(false);
			return new BusySocket(reader, writer, burn);
		} catch (_:Dynamic) {
			if (listener != null) {
				try {
					listener.close();
				} catch (_:Dynamic) {}
			}
			return null;
		}
	}

	private function new(reader:Socket, writer:Socket, burn:Float) {
		this.reader = reader;
		__writer = writer;
		__burn = burn;
		reader.custom = this;
	}

	public function poke():Void {
		__writer.output.writeByte(1);
		__writer.output.flush();
	}

	public function registryOnReadable():Void {
		calls++;
		var end = Timer.stamp() + __burn;
		while (Timer.stamp() < end) {}
	}

	public function registryOnWritable():Void {}

	public function registryHasBufferedInput():Bool {
		return false;
	}

	public function close():Void {
		if (__closed) {
			return;
		}
		__closed = true;
		for (socket in [reader, __writer]) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
	}

	private inline function get_registryClosed():Bool {
		return __closed;
	}
}
#end
