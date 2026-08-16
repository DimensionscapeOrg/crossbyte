import stress.StressCase;
import stress.StressResult;

/**
 * Entry point for the concurrency stress suite (`ci/stress-tests.hxml`).
 *
 * Kept separate from the utest suites because these cases need real
 * threads, take seconds rather than milliseconds each, and assert on
 * invariants under contention rather than on single-threaded behavior.
 *
 * Exits non-zero if any case fails, so CI treats a race as a build
 * failure.
 */
@:access(crossbyte.core.CrossByte)
class StressMain {
	public static function main():Void {
		// Several cases construct runtime-owned objects (timers, task
		// pools), which require a primordial runtime. Host-driven so no
		// loop thread competes with the cases for CPU.
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var cases:Array<StressCase> = [
			new stress.TaskPoolDrainStress(),
			new stress.ConnectionPoolStress(),
			new stress.MetricsStress(),
			new stress.TimerIdStress(),
			new stress.SocketBackpressureStress(),
			new stress.SocketDeferredFlushStress(),
			new stress.WebSocketRetentionStress(),
			new stress.WebSocketFinalMessageStress(),
			new stress.WebSocketBufferLimitStress(),
			new stress.IdleTaskPoolGcStress()
		];

		// Optional case-name filter. These cases share one process and one
		// runtime, so a failure that only appears in a full run is a
		// different bug from one that reproduces alone; running a single
		// case is how the two are told apart.
		var filter:String = Sys.args()[0];
		if (filter != null && filter != "") {
			var wanted:String = filter.toLowerCase();
			cases = cases.filter(function(c) {
				return Type.getClassName(Type.getClass(c)).toLowerCase().indexOf(wanted) >= 0;
			});

			if (cases.length == 0) {
				Sys.println('No stress case matches "$filter".');
				Sys.exit(2);
			}
		}

		var failed:Int = 0;
		var started:Float = Sys.time();

		Sys.println("CrossByte concurrency stress suite");
		Sys.println("==================================");

		for (stressCase in cases) {
			var caseStarted:Float = Sys.time();
			var result:StressResult;

			try {
				result = stressCase.run();
			} catch (error:Dynamic) {
				// Without the stack a thrown case reports only a message,
				// which for shared messages like "invalid socket" does not
				// say which call raised it.
				var stack:String = haxe.CallStack.toString(haxe.CallStack.exceptionStack());
				result = {
					name: Type.getClassName(Type.getClass(stressCase)),
					passed: false,
					details: ["threw: " + Std.string(error)].concat(stack.split("\n"))
				};
			}

			var elapsed:Int = Std.int((Sys.time() - caseStarted) * 1000);
			Sys.println("");
			Sys.println((result.passed ? "[PASS] " : "[FAIL] ") + result.name + " (" + elapsed + "ms)");
			for (line in result.details) {
				Sys.println("       " + line);
			}

			if (!result.passed) {
				failed++;
			}
		}

		var total:Int = Std.int((Sys.time() - started) * 1000);
		Sys.println("");
		Sys.println("==================================");
		Sys.println(cases.length + " case(s), " + failed + " failed, " + total + "ms");

		Sys.exit(failed == 0 ? 0 : 1);
	}
}
