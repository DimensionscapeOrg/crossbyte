package crossbyte._internal.socket.poll;

class PollBackendTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(runner -> runner.addCase(new PollBackendRegistryTest()));
	}
}
