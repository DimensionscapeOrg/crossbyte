package crossbyte.test;

import utest.Runner;
import utest.ui.Report;

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
