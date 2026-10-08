/**
 * JVM test entry point.
 *
 * Runs the whole suite, with nothing excluded.
 *
 * A Haxe 4.3.7 `--jvm` bytecode bug turns some code shapes into a
 * VerifyError that kills the process at class load rather than failing a
 * case: constructing an object for its side effects and discarding the
 * result leaves an uninitialised reference live across a branch, which
 * the verifier rejects. A test written that way binds each construction
 * to a local instead. Excluding a group to get past it would hide the
 * group for good, since nothing re-tests an exclusion once its reason has
 * gone.
 *
 * This calls `addAll` rather than listing the groups, so no group can be
 * left out by omission.
 */
class JvmTestMain {
	public static function main():Void {
		// Run as a child by a test that needs a process's first moments: the
		// first reads of a process-wide registry, in MetricsTest.
		if (Sys.args().indexOf(crossbyte.metrics.MetricsTest.FIRST_READ_CHILD) >= 0) {
			crossbyte.metrics.MetricsTest.firstReadChild();
			return;
		}

		crossbyte.test.TestHarness.run(function(runner) {
			crossbyte.test.TestSuites.addAll(runner);
		});
	}
}
