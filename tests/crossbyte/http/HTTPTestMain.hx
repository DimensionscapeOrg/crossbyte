package crossbyte.http;

class HTTPTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(runner -> runner.addCase(new HTTPRequestHandlerTest()));
	}
}
