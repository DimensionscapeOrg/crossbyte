package crossbyte.net;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class SocketNativeMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new DatagramSocketTest());
		runner.addCase(new ReliableDatagramProtocolTest());
		runner.addCase(new ReliableDatagramSocketTest());
		runner.addCase(new SocketTest());
		Report.create(runner);
		runner.run();
	}
}
