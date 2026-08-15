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
