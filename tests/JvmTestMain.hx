/**
 * JVM test entry point.
 *
 * Runs the whole suite. It used to run it minus RPCTest, CollectionsTest and
 * CompressionRoundTripTest, which tripped a Haxe 4.3.7 `--jvm` bytecode bug --
 * a VerifyError that kills the process at class-load rather than failing a
 * case, so the exclusion was the only way to see any result at all.
 *
 * Two of those three no longer trip it and had not for some time; the note
 * outlived the problem. The third was real, and was a property of the test
 * rather than of `crossbyte.rpc`: constructing an `RPCSession` for its side
 * effects and discarding the result leaves an uninitialised reference live
 * across a branch, which the verifier rejects. Binding each construction to a
 * local fixes it, and production RPC on jvm turned out never to have been the
 * problem -- it simply had no coverage saying so.
 *
 * The lesson worth keeping: an exclusion written for a real reason is not
 * re-tested by anything, so it stays long after the reason goes. Try removing
 * one occasionally.
 *
 * With nothing left to exclude this calls `addAll` rather than listing the
 * groups. The list had already drifted: it named every group `addAll` did
 * except `addMetrics`, which nothing explained and which was therefore not a
 * decision but an omission, and one no amount of reading either file would
 * have flagged.
 */
class JvmTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner) {
			crossbyte.test.TestSuites.addAll(runner);
		});
	}
}
