package crossbyte._internal.socket;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class FlexSocketTestMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new FlexSocketTest());
		Report.create(runner);
		runner.run();
	}
}
