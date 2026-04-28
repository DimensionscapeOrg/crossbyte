package crossbyte._internal.http;

class HttpTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(runner -> runner.addCase(new HttpTest()));
	}
}
