package crossbyte.core;

import crossbyte.events.Event;
import utest.Assert;
#if target.threaded
import sys.thread.Lock;
import sys.thread.Tls;
#end

/**
	Child runtimes made with `CrossByte.make()`: they leave the calling
	thread's timers alone, can be configured before their thread starts, and
	exit with the runtime that made them.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.Timer)
class ChildRuntimeTest extends utest.Test {
	#if target.threaded
	public function testMakeLeavesTheCallersTimersAlone():Void {
		var before = crossbyte.Timer.currentOrNull();
		var child = CrossByte.make();
		var after = crossbyte.Timer.currentOrNull();
		child.exit();

		Assert.notNull(before);
		Assert.isTrue(before == after, "make() took over the calling thread's timers");
	}

	public function testATimerArmedAfterMakeRunsOnTheThreadThatArmedIt():Void {
		// A heartbeat armed on the main thread after a simulation thread has
		// started runs on the main thread, not on the simulation's.
		var runtime = CrossByte.current();
		var here = new Tls<Bool>();
		here.value = true;
		var ranHere:Null<Bool> = null;
		var child = CrossByte.make();

		crossbyte.Timer.setTimeout(0.01, () -> ranHere = here.value == true);
		var deadline = haxe.Timer.stamp() + 3;
		while (ranHere == null && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.005);
		}
		child.exit();

		Assert.equals(true, ranHere, "the timer ran on another thread, or never");
	}

	public function testAChildIsConfiguredBeforeItsThreadStarts():Void {
		var ran = new Lock();
		var inits = 0;
		var tpsAtInit:Int = 0;
		var child:CrossByte = null;
		child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 50;
			configured.addEventListener(Event.INIT, _ -> {
				inits++;
				tpsAtInit = configured.tps;
				ran.release();
			});
		});

		var initArrived = ran.wait(5.0);
		child.exit();

		Assert.isTrue(initArrived, "INIT never reached a listener added while configuring");
		Assert.equals(1, inits);
		Assert.equals(50, tpsAtInit);
	}

	public function testChildrenExitWithTheRuntimeThatMadeThem():Void {
		// On the primordial runtime this is what ends the process: a child must
		// not keep running, with the process waiting on its thread, after the
		// primordial runtime has exited.
		var parent = new CrossByte(false, DEFAULT, true);
		var exited = new Lock();
		var child = CrossByte.make(DEFAULT, HEAP, configured -> configured.addEventListener(Event.EXIT, _ -> exited.release()));

		parent.exit();
		var childExited = exited.wait(5.0);
		if (!childExited) {
			child.exit();
		}

		Assert.isTrue(childExited, "the child outlived the runtime that made it");
		Assert.isFalse(child.__getRunning());
		Assert.equals(CrossByte.__primordial, CrossByte.current(), "the thread was not handed back");
	}

	public function testAChildExitedWhileConfiguringNeverStarts():Void {
		var inits = 0;
		var exits = 0;
		var child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.addEventListener(Event.INIT, _ -> inits++);
			configured.addEventListener(Event.EXIT, _ -> exits++);
			configured.exit();
		});

		Assert.isFalse(child.__getRunning());
		Assert.equals(0, inits);
		Assert.equals(1, exits);
	}

	/**
		A `CUSTOM` loop body runs its runtime by calling `pump`: what was
		posted, the timers, the tick and the sockets. Everything else that does
		a frame's work is private, so `pump` has to accept a custom runtime, not
		only a host-driven one, or a custom loop body could run nothing but itself.
	**/
	public function testACustomLoopRunsItsRuntimeThroughPump():Void {
		var finished = new Lock();
		var ticks = 0;
		var timerFired = false;
		var posted = false;
		var accepted = false;
		var connected = false;
		var failure:Dynamic = null;
		var deadline:Float = haxe.Timer.stamp() + 10;
		var last:Float = -1;

		var child = CrossByte.make(CUSTOM(() -> {
			var runtime = CrossByte.current();
			var now:Float = haxe.Timer.stamp();
			try {
				// Its own pacing: pump waits up to 10 ms for a socket, or for
				// something posted.
				runtime.pump(last < 0 ? 0 : now - last, 0.01);
			} catch (error:Dynamic) {
				failure = error;
				runtime.exit();
				return;
			}
			last = now;
			if ((ticks >= 3 && timerFired && posted && accepted && connected) || now > deadline) {
				runtime.exit();
			}
		}), HEAP, configured -> {
			configured.addEventListener(crossbyte.events.TickEvent.TICK, _ -> ticks++);
			configured.addEventListener(Event.INIT, _ -> {
				crossbyte.Timer.setTimeout(0.05, () -> timerFired = true);
				var server = new crossbyte.net.ServerSocket();
				server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, event -> {
					accepted = true;
					event.socket.close();
					server.close();
				});
				server.bind(0, "127.0.0.1");
				server.listen();
				var client = new crossbyte.net.Socket();
				client.addEventListener(Event.CONNECT, _ -> {
					connected = true;
					client.close();
				});
				client.connect("127.0.0.1", server.localPort);
			});
			configured.addEventListener(Event.EXIT, _ -> finished.release());
		});
		child.post(() -> posted = true);

		var ended:Bool = finished.wait(20);
		if (!ended) {
			child.exit();
		}
		Assert.isTrue(ended, "the custom loop never exited");
		Assert.isNull(failure, "pump refused the custom loop: " + failure);
		Assert.isTrue(ticks >= 3, "the custom loop ticked " + ticks + " times");
		Assert.isTrue(timerFired, "a timer never fired");
		Assert.isTrue(posted, "posted work never ran");
		Assert.isTrue(accepted && connected, "the sockets were never serviced: accepted " + accepted + ", connected " + connected);
	}

	public function testPumpRefusesARuntimeThatLoopsByItself():Void {
		// A DEFAULT runtime runs its own frames; pumping it from outside would
		// run them from two threads at once.
		var child = CrossByte.make();
		Assert.raises(() -> child.pump(0, 0), crossbyte.errors.IllegalOperationError);
		child.exit();

		// A CUSTOM runtime is pumped by its own body, on its own thread.
		var blocked = new Lock();
		var custom = CrossByte.make(CUSTOM(() -> {
			blocked.wait(0.005);
		}));
		Assert.raises(() -> custom.pump(0, 0), crossbyte.errors.IllegalOperationError);
		custom.exit();
	}
	#end

	#if js
	/**
		A `CUSTOM` loop body runs its runtime by calling `pump`: posted work,
		the timers and the tick. On JavaScript the body is called once a
		frame, at the runtime's tick rate.
	**/
	@:timeout(5000)
	public function testACustomLoopRunsItsRuntimeThroughPump(async:utest.Async):Void {
		var ticks = 0;
		var timerFired = false;
		var posted = false;
		var failure:Dynamic = null;
		var last:Float = -1;
		var child:CrossByte = null;
		child = CrossByte.make(CUSTOM(() -> {
			var now:Float = haxe.Timer.stamp();
			try {
				child.pump(last < 0 ? 0 : now - last);
			} catch (error:Dynamic) {
				failure = error;
			}
			last = now;
		}), HEAP, configured -> {
			configured.tps = 100;
			configured.addEventListener(crossbyte.events.TickEvent.TICK, _ -> ticks++);
			configured.addEventListener(Event.INIT, _ -> crossbyte.Timer.setTimeout(0.05, () -> timerFired = true));
		});
		child.post(() -> posted = true);

		__waitThen(() -> failure != null || (ticks >= 3 && timerFired && posted), () -> {
			child.exit();
			Assert.isNull(failure, "pump refused the custom loop: " + failure);
			Assert.isTrue(ticks >= 3, "the custom loop ticked " + ticks + " times");
			Assert.isTrue(timerFired, "a timer never fired");
			Assert.isTrue(posted, "posted work never ran");
			async.done();
		});
	}
	#end

	#if js
	/**
		On JavaScript a child made once the program is running runs. Its loop
		is not left to `haxe.EntryPoint`, which runs what it is given only while
		its own loop goes on (on Node, until the program has started), so a child
		made later still gets its INIT and its ticks.
	**/
	@:timeout(5000)
	public function testAChildMadeOnceRunningRuns(async:utest.Async):Void {
		// From a later turn: one made while main() runs is started with the
		// program.
		__waitThen(() -> true, () -> {
			var inits = 0;
			var ticks = 0;
			var child = CrossByte.make(DEFAULT, HEAP, configured -> {
				configured.tps = 100;
				configured.addEventListener(Event.INIT, _ -> inits++);
				configured.addEventListener(crossbyte.events.TickEvent.TICK, _ -> ticks++);
			});
			// Not inside make(): what the caller does next comes first, as it
			// does where a child has a thread of its own.
			Assert.equals(0, inits, "the child started inside make()");

			__waitThen(() -> ticks >= 3, () -> {
				child.exit();
				Assert.equals(1, inits, "the child never started");
				Assert.isTrue(ticks >= 3, "the child ticked " + ticks + " times");
				async.done();
			});
		});
	}

	/**
		A child's timers are its own, and the program's stay the program's.
		There is one thread here, so the child's loop must not keep
		`crossbyte.Timer` bound to itself once it has started: a timer the
		program arms afterwards runs on the program's scheduler, and still runs
		once the child has exited. The child has the timers only while its own
		work runs (its INIT, ticks and timers), and `CrossByte.current()` is the
		child then too, as it is on a child's own thread elsewhere.
	**/
	@:timeout(5000)
	public function testAChildDoesNotTakeTheProgramsTimers(async:utest.Async):Void {
		var program = crossbyte.Timer.currentOrNull();
		var ticks = 0;
		var inTick:Array<String> = [];
		var child:CrossByte = null;
		child = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 100;
			configured.addEventListener(crossbyte.events.TickEvent.TICK, _ -> {
				ticks++;
				if (crossbyte.Timer.currentOrNull() != configured.__timer) {
					inTick.push("timers not the child's");
				}
				if (CrossByte.current() != configured) {
					inTick.push("current() not the child");
				}
			});
		});

		__waitThen(() -> ticks >= 3, () -> {
			// Ticking is what gives the child the chance to take the timers.
			Assert.isTrue(ticks >= 3, "the child ticked " + ticks + " times");
			Assert.notNull(program);
			Assert.isTrue(crossbyte.Timer.currentOrNull() == program, "between the child's ticks the program's timers were the child's");
			Assert.isTrue(CrossByte.current() != child, "between the child's ticks current() was the child");
			Assert.same([], inTick);
			child.exit();
			__waitThen(() -> child.__didExit, () -> {
				Assert.isTrue(crossbyte.Timer.currentOrNull() == program, "the child's exit left the program without its timers");
				async.done();
			});
		});
	}

	private static function __waitThen(done:Void->Bool, then:Void->Void):Void {
		var started = haxe.Timer.stamp();
		var check:Void->Void = null;
		check = () -> {
			if (!done() && haxe.Timer.stamp() - started < 4) {
				js.Syntax.code("setTimeout({0}, 5)", check);
				return;
			}
			then();
		};
		js.Syntax.code("setTimeout({0}, 5)", check);
	}
	#end
}
