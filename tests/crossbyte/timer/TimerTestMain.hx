package crossbyte.timer;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class TimerTestMain {
	public static function main():Void {
		var crossByte = new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new HaxeTimerTest());
		runner.addCase(new TimerHeapTest());
		Report.create(runner);
		runner.run();
	}
}
