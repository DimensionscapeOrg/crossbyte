package crossbyte.core;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class CoreTestMain {
	public static function main():Void {
		new CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		runner.addCase(new CrossByteTest());
		Report.create(runner);
		runner.run();
	}
}
