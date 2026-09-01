package crossbyte.test;

import utest.Runner;
import utest.ui.Report;

/**
	Builds a runtime and runs a suite against it.

	## If a run comes back red once and green after

	There is an intermittent in here that has not been pinned down. It has been
	seen twice: once on node and once on the native suite, each time a small
	number of failures in a run whose neighbours were clean, and neither time
	were the failing fixture names captured -- the summary was read and the
	detail was gone. It has since survived nineteen deliberate reproduction
	attempts across both targets, six of them under concurrent build load.

	Two things follow. It is not target-specific, so a theory about node's event
	loop does not cover it; and whatever it is, it is rare enough that hunting
	it without evidence is guesswork.

	So the useful thing to do on a red run is capture, not re-run: keep the
	whole output, and the failing names with it. Building with `-D test_trace`
	prints each fixture as it starts, which is what attributes a hang or a crash
	to a method when the report never gets printed at all.
**/
@:access(crossbyte.core.CrossByte)
class TestHarness {
	public static function run(configure:Runner->Void):Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		configure(runner);
		#if test_trace
		// Build with `-D test_trace` to print each test as it starts. utest runs
		// fixtures in an order unrelated to registration, so when a native run
		// hangs this is the only way to attribute the hang to a method.
		runner.onTestStart.add(handler -> {
			var fixture = handler.fixture;
			Sys.println("[TEST] " + Type.getClassName(Type.getClass(fixture.target)) + "." + fixture.method);
			Sys.stdout().flush();
		});
		#end
		Report.create(runner);
		runner.run();
	}
}
