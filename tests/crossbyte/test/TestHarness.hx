package crossbyte.test;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class TestHarness {
	public static function run(configure:Runner->Void):Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		configure(runner);
		Report.create(runner);
		runner.run();
	}
}
