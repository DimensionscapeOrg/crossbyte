package crossbyte.http;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class HTTPTestMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new HTTPRequestHandlerTest());
		Report.create(runner);
		runner.run();
	}
}
