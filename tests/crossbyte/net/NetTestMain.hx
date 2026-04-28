package crossbyte.net;

class NetTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(runner -> {
			#if cpp
			runner.addCase(new SocketTest());
			#end
			runner.addCase(new DatagramSocketTest());
		});
	}
}
