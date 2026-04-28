import crossbyte.core.HostApplication;
import crossbyte.events.ThreadEvent;
import crossbyte.sys.Worker;

class WorkerSample extends HostApplication {
	public static function main():Void {
		#if !(sys && !eval)
		Sys.println("Worker is only supported on native sys targets.");
		return;
		#end

		var app = new WorkerSample();
		app.run();
	}

	private var worker:Worker;
	private var done:Bool = false;
	private var failed:String = null;

	public function new() {
		super();
	}

	private function run():Void {
		worker = new Worker();
		worker.addEventListener(ThreadEvent.PROGRESS, event -> Sys.println('progress -> ${event.message}'));
		worker.addEventListener(ThreadEvent.COMPLETE, event -> {
			done = true;
			Sys.println('complete -> ${event.message}');
		});
		worker.addEventListener(ThreadEvent.ERROR, event -> {
			failed = Std.string(event.message);
			done = true;
		});
		worker.doWork = _ -> {
			var total = 0;
			for (value in 1...6) {
				total += value;
				worker.sendProgress('added $value, total=$total');
				Sys.sleep(0.02);
			}
			worker.sendComplete('sum(1..5)=$total');
		};
		worker.run();

		var deadline = Sys.time() + 2.0;
		while (!done && Sys.time() < deadline) {
			advance(1 / 60, 0);
			Sys.sleep(0.01);
		}

		worker.clean();

		if (failed != null) {
			throw failed;
		}

		if (!done) {
			throw "Worker sample timed out waiting for completion.";
		}

		shutdown();
	}
}
