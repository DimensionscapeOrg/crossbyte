package crossbyte.sys;

import utest.Assert;

class ProcessLifecycleTest extends utest.Test {
	public function setup():Void {
		ProcessLifecycle.__resetForTesting();
		// Never let a test dispatch exit a live runtime (e.g. the native
		// smoke harness).
		ProcessLifecycle.exitOnShutdown = false;
	}

	public function teardown():Void {
		ProcessLifecycle.__resetForTesting();
	}

	#if nodejs
	public function testASigtermOnNodeLatchesTheRequest():Void {
		// Node exits on SIGTERM and SIGINT by default, so docker stop or Ctrl+C
		// on a Node service would skip the drain. Emitted rather than sent: a
		// real SIGTERM on Windows ends a Node process whatever listens for it.
		var ran = false;
		ProcessLifecycle.onShutdown(() -> ran = true);

		Assert.isTrue(ProcessLifecycle.installDefaultHandlers(), "no handlers on Node");
		js.Node.process.emit("SIGTERM");
		Assert.isTrue(ProcessLifecycle.shutdownRequested);
		Assert.isTrue(ProcessLifecycle.poll());
		Assert.isTrue(ran);
	}
	#end

	#if nodejs
	/**
		A SIGHUP on Node runs the same shutdown. By default Node ends the
		process on it (a terminal gone, or on Windows a console window closing,
		which Node delivers as SIGHUP) with no callbacks. On macOS, where Node
		cannot see whether nohup ignored it, it is left to Node's default.
	**/
	public function testASighupOnNodeLatchesTheRequest():Void {
		var ran = false;
		ProcessLifecycle.onShutdown(() -> ran = true);
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());

		var listening:Bool = js.Node.process.listenerCount("SIGHUP") > 0;
		if (js.Node.process.platform == "win32") {
			Assert.isTrue(listening, "nothing listens for SIGHUP on Windows");
		}
		if (listening) {
			js.Node.process.emit("SIGHUP");
			Assert.isTrue(ProcessLifecycle.shutdownRequested);
			Assert.isTrue(ProcessLifecycle.poll());
			Assert.isTrue(ran);
		}
	}
	#end

	#if (java || jvm)
	/**
		A HUP on the jvm runs the same shutdown, where by default the JVM halts
		on it. A JVM on Windows has no HUP, and installing still arms TERM and
		INT there.
	**/
	public function testAHangupOnTheJvmLatchesTheRequest():Void {
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers(), "this JVM has no signal hook");
		if (Sys.systemName() == "Windows") {
			return;
		}

		crossbyte.sys._internal.JvmSignals.JvmSignal.raise(new crossbyte.sys._internal.JvmSignals.JvmSignal("HUP"));
		var deadline = haxe.Timer.stamp() + 5;
		while (!ProcessLifecycle.shutdownRequested && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}
		Assert.isTrue(ProcessLifecycle.shutdownRequested, "the HUP did not reach the handler");
	}

	public function testASignalOnTheJvmLatchesTheRequest():Void {
		// The JVM's default for SIGINT and SIGTERM halts it after its
		// shutdown hooks, so a jvm service would skip the drain.
		if (!ProcessLifecycle.installDefaultHandlers()) {
			Assert.fail("this JVM has no signal hook");
			return;
		}

		crossbyte.sys._internal.JvmSignals.JvmSignal.raise(new crossbyte.sys._internal.JvmSignals.JvmSignal("INT"));
		var deadline = haxe.Timer.stamp() + 5;
		while (!ProcessLifecycle.shutdownRequested && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}
		Assert.isTrue(ProcessLifecycle.shutdownRequested, "the signal did not reach the handler");
	}
	#end

	#if (cpp && windows)
	/**
		A closing console window holds the close while the shutdown runs.
		Windows ends the process as soon as the handler for a close, a logoff
		or a shutdown returns, so a handler that returned at once would let the
		process go before the runtime's next tick saw the request, and only
		Ctrl+C and Ctrl+Break would run onShutdown. Delivered here as Windows
		delivers it, on a thread of its own, with a short hold.
	**/
	public function testAClosingConsoleWaitsForTheShutdown():Void {
		var runtime = crossbyte.core.CrossByte.current();
		var heldWhileRunning:Null<Bool> = null;
		ProcessLifecycle.onShutdown(() -> {
			heldWhileRunning = crossbyte.sys._internal.NativeLifecycle.holding() > 0;
		});
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());

		var CTRL_CLOSE_EVENT:Int = 2;
		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.deliverConsoleEvent(CTRL_CLOSE_EVENT, 1000));

		// What the watching runtime does each tick.
		var deadline:Float = haxe.Timer.stamp() + 5;
		while (heldWhileRunning == null && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.005);
		}

		Assert.equals(true, heldWhileRunning, "the close was let go before the shutdown ran: " + heldWhileRunning);
		letTheHoldGo();
	}

	/**
		A process that has loaded user32.dll hears of a logoff or a shutdown
		through a window: Windows does not call its console handler for them.
		A hidden one runs the shutdown and holds the session's end while it
		runs, as the console handler holds a close. Without it, such a process
		(a GUI toolkit's, or one calling a Shell function) would have no window,
		and the session would end it with no onShutdown.

		user32 is loaded here as such a process loads it; the test process
		loads none of it otherwise. The logoff is the one Windows sends:
		WM_QUERYENDSESSION, then WM_ENDSESSION.
	**/
	public function testALogoffReachesAProcessThatLoadedUser32ThroughAWindow():Void {
		var runtime = crossbyte.core.CrossByte.current();
		var heldWhileRunning:Null<Bool> = null;
		ProcessLifecycle.onShutdown(() -> {
			heldWhileRunning = crossbyte.sys._internal.NativeLifecycle.holding() > 0;
		});

		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.loadUser32ForTest());
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
		var deadline:Float = haxe.Timer.stamp() + 5;
		while (!crossbyte.sys._internal.NativeLifecycle.sessionWindowReady() && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}
		if (!crossbyte.sys._internal.NativeLifecycle.sessionWindowReady()) {
			Assert.fail("no window was made for a process that loaded user32");
			return;
		}

		Assert.equals(1, crossbyte.sys._internal.NativeLifecycle.deliverSessionEnd(1000), "the window did not take the logoff");
		deadline = haxe.Timer.stamp() + 5;
		while (heldWhileRunning == null && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.005);
		}

		Assert.equals(true, heldWhileRunning, "the session's end was let go before the shutdown ran: " + heldWhileRunning);
		letTheHoldGo();
	}

	/**
		Windows sends a logoff to services whenever anyone signs out, and does
		not end them, so a process in session 0 ignores it; shutting down on it
		would make a service, or a process a service started, stop serving
		whenever a user went home. Delivered here as though in session 0 (a
		test hook), and then outside it, where a logoff is still a shutdown.
	**/
	public function testALogoffInSessionZeroIsIgnored():Void {
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
		var CTRL_LOGOFF_EVENT:Int = 5;

		crossbyte.sys._internal.NativeLifecycle.forceServiceSessionForTest(1);
		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.deliverConsoleEvent(CTRL_LOGOFF_EVENT, 300));
		crossbyte.sys.System.sleep(0.5);
		Assert.isFalse(ProcessLifecycle.shutdownRequested, "a logoff in session 0 shut the process down");
		Assert.equals(0, crossbyte.sys._internal.NativeLifecycle.holding());

		crossbyte.sys._internal.NativeLifecycle.forceServiceSessionForTest(0);
		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.deliverConsoleEvent(CTRL_LOGOFF_EVENT, 300));
		var deadline:Float = haxe.Timer.stamp() + 5;
		while (!ProcessLifecycle.shutdownRequested && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}
		Assert.isTrue(ProcessLifecycle.shutdownRequested, "a logoff outside session 0 did not shut down");
		letTheHoldGo();
	}

	// Waits out a held close, logoff or shutdown before the next test: its
	// bound ends it.
	private static function letTheHoldGo():Void {
		var deadline:Float = haxe.Timer.stamp() + 5;
		while (crossbyte.sys._internal.NativeLifecycle.holding() > 0 && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}
	}
	#end

	#if (cpp && !windows)
	// SIGHUP: the same number on Linux and macOS. Not named SIGHUP, which
	// macOS's headers define as a macro over the C++ member it becomes.
	static inline var HANGUP:Int = 1;

	/**
		A SIGHUP (the terminal a server was started from going away) runs the
		same shutdown as SIGTERM, rather than its default, which ends the
		process at once, with no onShutdown and no drain.
	**/
	public function testAHangupShutsDownGracefully():Void {
		var ran = false;
		ProcessLifecycle.onShutdown(() -> ran = true);
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());

		// Asked first, so that a hangup left at its default fails here rather
		// than ending the suite, as it can on macOS where SIGHUP has been
		// handled with SA_SIGINFO in the shell that started the run.
		if (!crossbyte.sys._internal.NativeLifecycle.handlesForTest(HANGUP)) {
			Assert.fail("SIGHUP was left at its default by installDefaultHandlers()");
			return;
		}
		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.raiseForTest(HANGUP));
		Assert.isTrue(ProcessLifecycle.shutdownRequested);
		Assert.isTrue(ProcessLifecycle.poll());
		Assert.isTrue(ran);
	}

	/**
		A SIGHUP at its default whose SA_SIGINFO flag is still set is handled
		all the same. macOS keeps the flag across exec for a signal the parent
		handled with it, and an install that read the flag as some other
		handler would leave SIGHUP alone, and a hangup would end the whole suite.
	**/
	public function testAHangupLeftWithSiginfoIsStillHandled():Void {
		crossbyte.sys._internal.NativeLifecycle.uninstallForTest();
		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.defaultWithSiginfoForTest(HANGUP));
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.handlesForTest(HANGUP), "SIGHUP was left at its default");

		// As it was: SIGHUP to its default, and the handlers installed over it.
		crossbyte.sys._internal.NativeLifecycle.uninstallForTest();
		crossbyte.sys._internal.NativeLifecycle.ignoreForTest(HANGUP, false);
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
	}

	/**
		A SIGHUP ignored when the handlers are installed (nohup, which asks
		for the process to outlive its terminal) stays ignored.
	**/
	public function testAHangupIgnoredByNohupStaysIgnored():Void {
		crossbyte.sys._internal.NativeLifecycle.uninstallForTest();
		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.ignoreForTest(HANGUP, true));
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());

		Assert.isTrue(crossbyte.sys._internal.NativeLifecycle.raiseForTest(HANGUP));
		Assert.isFalse(ProcessLifecycle.shutdownRequested);

		// As it was: SIGHUP to its default, and the handlers installed over it.
		crossbyte.sys._internal.NativeLifecycle.uninstallForTest();
		crossbyte.sys._internal.NativeLifecycle.ignoreForTest(HANGUP, false);
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
	}
	#end

	public function testShutdownStartsUnrequested():Void {
		Assert.isFalse(ProcessLifecycle.shutdownRequested);
		Assert.isFalse(ProcessLifecycle.poll());
	}

	public function testProgrammaticShutdownDispatchesOnceInOrder():Void {
		var order:Array<Int> = [];
		ProcessLifecycle.onShutdown(() -> order.push(1));
		ProcessLifecycle.onShutdown(() -> order.push(2));
		ProcessLifecycle.onShutdown(() -> order.push(3));

		// Registration alone must not dispatch.
		Assert.equals(0, order.length);

		ProcessLifecycle.requestShutdown();
		Assert.isTrue(ProcessLifecycle.shutdownRequested);
		// The request latches; dispatch happens on poll, not on request.
		Assert.equals(0, order.length);

		Assert.isTrue(ProcessLifecycle.poll());
		Assert.same([1, 2, 3], order);

		// Second poll and second request must not re-fire.
		Assert.isFalse(ProcessLifecycle.poll());
		ProcessLifecycle.requestShutdown();
		Assert.isFalse(ProcessLifecycle.poll());
		Assert.same([1, 2, 3], order);

		// The latch survives dispatch.
		Assert.isTrue(ProcessLifecycle.shutdownRequested);
	}

	public function testCallbackExceptionDoesNotBlockOthers():Void {
		var order:Array<Int> = [];
		ProcessLifecycle.onShutdown(() -> order.push(1));
		ProcessLifecycle.onShutdown(() -> throw "shutdown callback failure");
		ProcessLifecycle.onShutdown(() -> order.push(3));

		// Contained, and said, not swallowed without a word.
		var errors:Array<String> = [];
		crossbyte.utils.Logger.recordSink = record -> {
			if (record.level == crossbyte.utils.LogLevel.ERROR) {
				errors.push(record.message);
			}
		};
		ProcessLifecycle.requestShutdown();
		var dispatched = ProcessLifecycle.poll();
		crossbyte.utils.Logger.recordSink = null;

		Assert.isTrue(dispatched);
		Assert.same([1, 3], order);
		Assert.equals(1, errors.length, "errors logged: " + errors.join(" | "));
		if (errors.length == 1) {
			Assert.isTrue(errors[0].indexOf("shutdown callback failure") >= 0, errors[0]);
		}
	}

	public function testLateRegistrationRunsImmediately():Void {
		ProcessLifecycle.requestShutdown();
		Assert.isTrue(ProcessLifecycle.poll());

		var lateRan = false;
		ProcessLifecycle.onShutdown(() -> lateRan = true);
		Assert.isTrue(lateRan);

		// A late callback that throws is also contained, and logged.
		var logged = 0;
		crossbyte.utils.Logger.recordSink = record -> logged++;
		ProcessLifecycle.onShutdown(() -> throw "late failure");
		crossbyte.utils.Logger.recordSink = null;
		Assert.equals(1, logged);
	}

	public function testNullCallbackIsIgnored():Void {
		ProcessLifecycle.onShutdown(null);
		ProcessLifecycle.requestShutdown();
		Assert.isTrue(ProcessLifecycle.poll());
	}

	public function testServiceControlReportsConsoleRunAsNotAService():Void {
		// The test process is started by a shell, not by the SCM, so attaching
		// has to settle on "not a service" rather than hang or claim otherwise.
		// A short bound keeps a regression here from stalling the suite.
		Assert.isFalse(ProcessLifecycle.installServiceControl("CrossByteTestService", 3000));
		Assert.isFalse(ProcessLifecycle.isService);

		// Idempotent, and still not a service the second time.
		Assert.isFalse(ProcessLifecycle.installServiceControl("CrossByteTestService", 3000));

		#if (cpp && windows)
		// Specifically "the SCM did not start us", not "the handshake failed":
		// returning false covers both, and only one of them is correct here. A
		// dispatcher thread that never started would report UNAVAILABLE.
		Assert.equals(crossbyte.sys._internal.NativeServiceControl.NOT_A_SERVICE,
			crossbyte.sys._internal.NativeServiceControl.attachState());
		#end

		// Attaching must not by itself request shutdown, and it must leave the
		// console/signal handlers armed.
		Assert.isFalse(ProcessLifecycle.shutdownRequested);
		#if cpp
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
		#end
	}

	/**
		A handshake timeout of 0 is none, as everywhere in CrossByte: the call
		waits for the handshake to settle. Read as "do not wait", it would
		answer while the handshake was still pending, so a process the SCM did
		start could report itself a console run. Run alone, before anything
		else here attaches, that would read PENDING.
	**/
	public function testServiceControlWithATimeoutOfZeroWaitsForTheHandshake():Void {
		Assert.isFalse(ProcessLifecycle.installServiceControl("CrossByteTestService", 0));

		#if (cpp && windows)
		Assert.equals(crossbyte.sys._internal.NativeServiceControl.NOT_A_SERVICE,
			crossbyte.sys._internal.NativeServiceControl.attachState(), "answered before the handshake settled");
		#end
	}

	/** A negative bound is refused, on every target, rather than read as 0. **/
	public function testServiceControlRefusesANegativeTimeout():Void {
		Assert.raises(() -> ProcessLifecycle.installServiceControl("CrossByteTestService", -1), crossbyte.errors.ArgumentError);
		Assert.raises(() -> ProcessLifecycle.reportServiceStopPending(-1), crossbyte.errors.ArgumentError);
		// 0 is the SCM's default hint, there being no hint without a limit.
		ProcessLifecycle.reportServiceStopPending(0);
		Assert.isFalse(ProcessLifecycle.shutdownRequested);
	}

	public function testServiceStatusReportsAreSafeWhenNotAService():Void {
		// Every one of these is a no-op off the SCM. The point is that a server
		// written for service deployment can call them unconditionally and still
		// run from a console.
		ProcessLifecycle.reportServiceStopPending(1000);
		ProcessLifecycle.reportServiceStopped(0);
		ProcessLifecycle.reportServiceStopPending();
		ProcessLifecycle.reportServiceStopped();

		Assert.isFalse(ProcessLifecycle.shutdownRequested);
		Assert.isFalse(ProcessLifecycle.poll());
	}

	public function testServiceStopControlDispatchesShutdownCallbacks():Void {
		#if cpp
		var ran:Array<Int> = [];
		ProcessLifecycle.onShutdown(() -> ran.push(1));
		ProcessLifecycle.onShutdown(() -> ran.push(2));

		Assert.isFalse(ProcessLifecycle.shutdownRequested);

		// Drives the real SERVICE_CONTROL_STOP handler, not a copy of it: a
		// service stop reaches the callbacks, so a drain registered here runs
		// before the SCM would kill the process.
		crossbyte.sys._internal.NativeServiceControl.simulateStop();

		Assert.isTrue(ProcessLifecycle.shutdownRequested);
		// The control handler only latches; dispatch still belongs to poll().
		Assert.equals(0, ran.length);

		Assert.isTrue(ProcessLifecycle.poll());
		Assert.same([1, 2], ran);
		#else
		Assert.pass();
		#end
	}

	public function testDeferServiceStopSurvivesReset():Void {
		ProcessLifecycle.deferServiceStop = true;
		ProcessLifecycle.__resetForTesting();
		// Left set, it would silently suppress the stop report for every later
		// shutdown in the process.
		Assert.isFalse(ProcessLifecycle.deferServiceStop);
	}

	public function testInstallDefaultHandlersMatchesTargetSupport():Void {
		// Native, Node and the jvm have a signal source; the rest do not.
		#if (cpp || nodejs || java || jvm)
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
		// Idempotent.
		Assert.isTrue(ProcessLifecycle.installDefaultHandlers());
		// Arming handlers must not by itself request shutdown.
		Assert.isFalse(ProcessLifecycle.shutdownRequested);
		#else
		Assert.isFalse(ProcessLifecycle.installDefaultHandlers());
		// The programmatic path still works without native handlers.
		ProcessLifecycle.requestShutdown();
		Assert.isTrue(ProcessLifecycle.shutdownRequested);
		Assert.isTrue(ProcessLifecycle.poll());
		#end
	}
}
