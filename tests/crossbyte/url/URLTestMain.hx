package crossbyte.url;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class URLTestMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new URLTest());
		runner.addCase(new URLLoaderHttpTest());
		runner.addCase(new URLLoaderTest());
		runner.addCase(new URLVariablesTest());
		Report.create(runner);
		runner.run();
	}
}
