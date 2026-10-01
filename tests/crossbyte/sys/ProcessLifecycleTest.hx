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
		// Node exited on SIGTERM and SIGINT, so docker stop or Ctrl+C on a
		// Node service skipped the drain. Emitted rather than sent: a real
		// SIGTERM on Windows ends a Node process whatever listens for it.
		var ran = false;
		ProcessLifecycle.onShutdown(() -> ran = true);

		Assert.isTrue(ProcessLifecycle.installDefaultHandlers(), "no handlers on Node");
		js.Node.process.emit("SIGTERM");
		Assert.isTrue(ProcessLifecycle.shutdownRequested);
		Assert.isTrue(ProcessLifecycle.poll());
		Assert.isTrue(ran);
	}
	#end

	#if (java || jvm)
	public function testASignalOnTheJvmLatchesTheRequest():Void {
		// The JVM's default for SIGINT and SIGTERM halts it after its
		// shutdown hooks, so a jvm service skipped the drain.
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
		or a shutdown returns, and the handler returned at once: the process
		was gone before the runtime's next tick saw the request, so only
		Ctrl+C and Ctrl+Break ran onShutdown. Delivered here as Windows
		delivers it, on a thread of its own, with a short hold.
	**/
	public function testAClosingConsoleWaitsForTheShutdown():Void {
		var runtime = crossbyte.core.CrossByte.current();
		var heldWhileRunning:Null<Bool> = null;
		ProcessLifecycle.onShutdown(() -> {
			heldWhileRunning = crossbyte.sys._internal.NativeLifecycle.consoleHandlersHolding() > 0;
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

		// Let the held handler go before the next test: its bound ends it.
		deadline = haxe.Timer.stamp() + 5;
		while (crossbyte.sys._internal.NativeLifecycle.consoleHandlersHolding() > 0 && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}
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

		// Contained, and said: it was swallowed without a word.
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

		// Drives the real SERVICE_CONTROL_STOP handler, not a copy of it. This
		// is the path that did not exist: a service stop reached no callback,
		// so a drain registered here never ran and the SCM killed the process.
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
