package crossbyte.sys;

import crossbyte.errors.IllegalOperationError;
import crossbyte.events.ThreadEvent;
import utest.Assert;

class WorkerTest extends utest.Test {
	public function testCompleteCapturesResultAndState():Void {
		var worker = new Worker();
		var completeMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> completeMessage = event.message);
		worker.doWork = message -> worker.sendComplete("done:" + message);

		worker.run("job");

		Assert.equals("done:job", completeMessage);
		Assert.equals("done:job", worker.result);
		Assert.equals(WorkerState.COMPLETED, worker.state);
		Assert.isTrue(worker.completed);
		Assert.isTrue(worker.canceled);
		Assert.isFalse(worker.cancelRequested);
	}

	public function testProgressIsDispatchedBeforeComplete():Void {
		var worker = new Worker();
		var events:Array<String> = [];
		worker.addEventListener(ThreadEvent.PROGRESS, (event:ThreadEvent) -> events.push("progress:" + event.message));
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> events.push("complete:" + event.message));
		worker.doWork = _ -> {
			worker.sendProgress("one");
			worker.sendProgress("two");
			worker.sendComplete("done");
		};

		worker.run();

		Assert.equals("progress:one", events[0]);
		Assert.equals("progress:two", events[1]);
		Assert.equals("complete:done", events[2]);
		Assert.equals(3, events.length);
	}

	public function testSendErrorCapturesErrorAndState():Void {
		var worker = new Worker();
		var errorMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.ERROR, (event:ThreadEvent) -> errorMessage = event.message);
		worker.doWork = _ -> worker.sendError("bad");

		worker.run();

		Assert.equals("bad", errorMessage);
		Assert.equals("bad", worker.error);
		Assert.equals(WorkerState.FAILED, worker.state);
		Assert.isTrue(worker.failed);
		Assert.isTrue(worker.canceled);
	}

	public function testThrownExceptionIsCapturedAsError():Void {
		var worker = new Worker();
		var errorMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.ERROR, (event:ThreadEvent) -> errorMessage = event.message);
		worker.doWork = _ -> throw "boom";

		worker.run();

		Assert.equals("boom", errorMessage);
		Assert.equals("boom", worker.error);
		Assert.equals(WorkerState.FAILED, worker.state);
	}

	public function testCancelSuppressesLaterMessages():Void {
		var worker = new Worker();
		var completeCount:Int = 0;
		var progressCount:Int = 0;
		worker.addEventListener(ThreadEvent.COMPLETE, (_:ThreadEvent) -> completeCount++);
		worker.addEventListener(ThreadEvent.PROGRESS, (_:ThreadEvent) -> progressCount++);
		worker.doWork = _ -> {
			worker.cancel(false);
			worker.sendProgress("late");
			worker.sendComplete("late");
		};

		worker.run();

		Assert.equals(0, completeCount);
		Assert.equals(0, progressCount);
		Assert.equals(WorkerState.CANCELLED, worker.state);
		Assert.isTrue(worker.canceled);
		Assert.isTrue(worker.cancelRequested);
	}

	public function testRunWhileRunningThrows():Void {
		var worker = new Worker();
		var threw:Bool = false;
		worker.doWork = _ -> {
			try {
				worker.run("again");
			} catch (e:IllegalOperationError) {
				threw = true;
			}
			worker.sendComplete();
		};

		worker.run();

		Assert.isTrue(threw);
		Assert.equals(WorkerState.COMPLETED, worker.state);
	}

	public function testCleanResetsReusableWorker():Void {
		var worker = new Worker();
		worker.doWork = _ -> worker.sendComplete("first");
		worker.run();
		worker.clean();

		var completeMessage:Dynamic = null;
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> completeMessage = event.message);
		worker.doWork = _ -> worker.sendComplete("second");
		worker.run();

		Assert.equals("second", completeMessage);
		Assert.equals(WorkerState.COMPLETED, worker.state);
		Assert.equals("second", worker.result);
	}
}
