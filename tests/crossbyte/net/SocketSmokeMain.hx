package crossbyte.net;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class SocketSmokeMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new SocketSingleCase());
		Report.create(runner);
		runner.run();
	}
}
