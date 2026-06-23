/**
 * JVM smoke test entry point.
 *
 * Runs the target-agnostic, non-networking portion of the suite on the jvm
 * target. The full suite (net/http/ipc/rpc/crypto) additionally needs the jvm
 * NIO socket backend, native crypto fallbacks, and a Haxe-jvm bytecode
 * workaround, which are tracked separately.
 */
class JvmSmokeMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner) {
			crossbyte.test.TestSuites.addDataStructures(runner);
			crossbyte.test.TestSuites.addIO(runner);
			crossbyte.test.TestSuites.addMath(runner);
			crossbyte.test.TestSuites.addUtils(runner);
			crossbyte.test.TestSuites.addErrors(runner);
			crossbyte.test.TestSuites.addFoundation(runner);
			crossbyte.test.TestSuites.addEvents(runner);
			crossbyte.test.TestSuites.addTimers(runner);
		});
	}
}
