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

		ProcessLifecycle.requestShutdown();
		Assert.isTrue(ProcessLifecycle.poll());
		Assert.same([1, 3], order);
	}

	public function testLateRegistrationRunsImmediately():Void {
		ProcessLifecycle.requestShutdown();
		Assert.isTrue(ProcessLifecycle.poll());

		var lateRan = false;
		ProcessLifecycle.onShutdown(() -> lateRan = true);
		Assert.isTrue(lateRan);

		// A late callback that throws is also contained.
		ProcessLifecycle.onShutdown(() -> throw "late failure");
		Assert.pass();
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
		#if cpp
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
