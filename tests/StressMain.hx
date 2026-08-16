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
			new stress.TimerIdStress()
		];

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
				result = {
					name: Type.getClassName(Type.getClass(stressCase)),
					passed: false,
					details: ["threw: " + Std.string(error)]
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
