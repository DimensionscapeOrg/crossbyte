package crossbyte.io;

class FileStreamTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(runner -> runner.addCase(new FileStreamTest()));
	}
}
