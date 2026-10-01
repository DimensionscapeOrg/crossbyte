@:access(crossbyte.core.CrossByte)
class NativeSmokeMain {
	public static function main():Void {
		// Run as a child by a test that needs a CrossByte process of its own
		// to watch from outside: see LoggerTest.
		if (Sys.args().indexOf("--crossbyte-child=logger") >= 0) {
			loggerChild();
			return;
		}
		// The first reads of a process-wide registry: see MetricsTest.
		if (Sys.args().indexOf(crossbyte.metrics.MetricsTest.FIRST_READ_CHILD) >= 0) {
			crossbyte.metrics.MetricsTest.firstReadChild();
			return;
		}

		crossbyte.test.TestHarness.run(crossbyte.test.TestSuites.addNativeSmoke);
	}

	// Logs one INFO record, runs one frame, and waits long enough that the
	// record arriving before the exit is told from one arriving at it.
	private static function loggerChild():Void {
		var runtime = new crossbyte.core.CrossByte(false, DEFAULT, true);
		crossbyte.utils.Logger.info("logged-info");
		runtime.pump(1 / 60, 0);
		crossbyte.sys.System.sleep(4.0);
		runtime.exit();
	}
}
