package crossbyte._internal.socket.poll;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class PollBackendTestMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new PollBackendRegistryTest());
		Report.create(runner);
		runner.run();
	}
}
