package crossbyte._internal.http;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class HttpTestMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new HttpTest());
		Report.create(runner);
		runner.run();
	}
}
