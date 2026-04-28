package crossbyte.net;

import crossbyte.core.CrossByte;
import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class NetTestMain {
	public static function main():Void {
		new CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		runner.addCase(new SocketTest());
		runner.addCase(new DatagramSocketTest());
		Report.create(runner);
		runner.run();
	}
}
