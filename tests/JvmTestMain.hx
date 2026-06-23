/**
 * JVM test entry point.
 *
 * Runs the suite on the jvm target, excluding the cases that trip a Haxe 4.3.7
 * `--jvm` bytecode bug (VerifyError: inconsistent stackmap on new+conditional /
 * switch-table patterns): RPCTest, CollectionsTest, and CompressionRoundTripTest.
 * That compiler defect is fixed by a Haxe upgrade (or restructuring each
 * trigger); it is not a CrossByte logic issue.
 */
class JvmTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner) {
			crossbyte.test.TestSuites.addAuth(runner);
			crossbyte.test.TestSuites.addCrypto(runner);
			crossbyte.test.TestSuites.addCore(runner);
			crossbyte.test.TestSuites.addFoundation(runner);
			crossbyte.test.TestSuites.addErrors(runner);
			crossbyte.test.TestSuites.addEvents(runner);
			// addDataStructures minus the two VerifyError cases (Collections, Compression):
			runner.addCase(new crossbyte.ds.Array2DTest());
			runner.addCase(new crossbyte.ds.BloomFilterTest());
			runner.addCase(new crossbyte.ds.OrderedMapTest());
			runner.addCase(new crossbyte.ds.BitmapDataTest());
			crossbyte.test.TestSuites.addMath(runner);
			crossbyte.test.TestSuites.addHttp(runner);
			crossbyte.test.TestSuites.addIO(runner);
			crossbyte.test.TestSuites.addURL(runner);
			crossbyte.test.TestSuites.addIPC(runner);
			crossbyte.test.TestSuites.addDatabase(runner);
			crossbyte.test.TestSuites.addSystem(runner);
			crossbyte.test.TestSuites.addNet(runner);
			// addRPC skipped: Haxe 4.3.7 --jvm VerifyError crashes the verifier.
			crossbyte.test.TestSuites.addResources(runner);
			crossbyte.test.TestSuites.addTimers(runner);
			crossbyte.test.TestSuites.addUtils(runner);
		});
	}
}
