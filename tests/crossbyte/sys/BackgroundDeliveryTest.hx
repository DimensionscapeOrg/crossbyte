package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.TaskEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.events.UncaughtErrorEvent;
import utest.Assert;

/**
	`TaskPool` and `Worker` where there are no threads: JavaScript.

	The work runs on the one thread there is, inside `submit` or `run`, and
	what it reports is delivered in a later turn, as it is from a thread
	elsewhere. It was delivered inside the call, so a listener added after
	`submit`: the obvious order, and the only one `submit`'s return value
	allows, never heard anything.

	Empty wherever there are threads; `TaskPoolTest` and `WorkerTest` cover
	those.
**/
@:access(crossbyte.core.CrossByte)
class BackgroundDeliveryTest extends utest.Test {
	#if js
	@:timeout(5000)
	public function testATaskListenerAddedAfterSubmitHearsItsCompletion(async:utest.Async):Void {
		var pool = new TaskPool(2);
		var ran = false;
		var task = pool.submitResult(() -> {
			ran = true;
			return 42;
		});

		// The job ran inside submit, on the one thread there is; its event has
		// not been delivered yet.
		Assert.isTrue(ran);
		Assert.equals(TaskState.COMPLETED, task.state);

		var heard:Null<Int> = null;
		task.addEventListener(TaskEvent.COMPLETE, (event:TaskEvent<Int>) -> heard = event.result);
		Assert.isNull(heard, "COMPLETE was delivered inside submit");

		__waitThen(() -> heard != null, () -> {
			Assert.equals(42, heard, "a listener added after submit never heard the completion");
			pool.shutdown(false);
			async.done();
		});
	}

	@:timeout(5000)
	public function testATaskListenerAddedAfterSubmitHearsItsFailure(async:utest.Async):Void {
		var pool = new TaskPool(1);
		var task = pool.submitResult(() -> {
			throw "bad job";
			return 0;
		});
		Assert.equals(TaskState.FAILED, task.state);

		var heard:Dynamic = null;
		task.addEventListener(TaskEvent.ERROR, (event:TaskEvent<Int>) -> heard = event.error);

		__waitThen(() -> heard != null, () -> {
			Assert.equals("bad job", heard, "a listener added after submit never heard the failure");
			pool.shutdown(false);
			async.done();
		});
	}

	@:timeout(5000)
	public function testAWorkersMessagesArriveInALaterTurnInOrder(async:utest.Async):Void {
		var worker = new Worker();
		worker.doWork = _ -> {
			worker.sendProgress("one");
			worker.sendProgress("two");
			worker.sendComplete("done");
		};
		worker.run();
		// Still running as far as anyone listening can tell: COMPLETE, and the
		// state that goes with it, arrive with the messages, as from a thread.
		Assert.equals(WorkerState.RUNNING, worker.state);

		var events:Array<String> = [];
		worker.addEventListener(ThreadEvent.PROGRESS, (event:ThreadEvent) -> events.push("progress:" + event.message));
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> events.push("complete:" + event.message));

		__waitThen(() -> events.length >= 3, () -> {
			Assert.same(["progress:one", "progress:two", "complete:done"], events);
			Assert.equals(WorkerState.COMPLETED, worker.state);
			Assert.equals("done", worker.result);
			async.done();
		});
	}

	/**
		Cancelled between `run()` and the later turn its messages come in, a
		worker delivers none of them and ends cancelled, not RUNNING for
		good, as it did when the work had already sent its COMPLETE.
	**/
	@:timeout(5000)
	public function testACancelledWorkerDeliversNothingMore(async:utest.Async):Void {
		var worker = new Worker();
		var heard = 0;
		worker.doWork = _ -> {
			worker.sendProgress(1);
			worker.sendComplete("done");
		};
		worker.addEventListener(ThreadEvent.PROGRESS, (_:ThreadEvent) -> heard++);
		worker.addEventListener(ThreadEvent.COMPLETE, (_:ThreadEvent) -> heard++);
		worker.run();
		worker.cancel(false);

		__waitThen(() -> false, () -> {
			Assert.equals(0, heard, "a cancelled worker's messages were still delivered");
			Assert.equals(WorkerState.CANCELLED, worker.state);
			Assert.isFalse(worker.running);
			async.done();
		}, 0.1);
	}

	/**
		A listener that throws is reported as a posted callback's failure is,
		not thrown into the platform's loop, which on Node ends the process.
	**/
	@:timeout(5000)
	public function testAListenerThatThrowsIsReported(async:utest.Async):Void {
		var runtime = CrossByte.current();
		var reports:Array<String> = [];
		var watch = (event:UncaughtErrorEvent) -> reports.push(event.source);
		runtime.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, watch);

		var pool = new TaskPool(1);
		var task = pool.submitResult(() -> 1);
		task.addEventListener(TaskEvent.COMPLETE, (_:TaskEvent<Int>) -> throw "listener bug");

		__waitThen(() -> reports.length > 0, () -> {
			runtime.removeEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, watch);
			pool.shutdown(false);
			Assert.same([UncaughtErrorEvent.POSTED], reports);
			async.done();
		});
	}

	private static function __waitThen(done:Void->Bool, then:Void->Void, seconds:Float = 4):Void {
		var started = haxe.Timer.stamp();
		var check:Void->Void = null;
		check = () -> {
			if (!done() && haxe.Timer.stamp() - started < seconds) {
				js.Syntax.code("setTimeout({0}, 5)", check);
				return;
			}
			then();
		};
		js.Syntax.code("setTimeout({0}, 5)", check);
	}
	#else
	public function testThreadedTargetsAreCoveredElsewhere():Void {
		Assert.pass();
	}
	#end
}
