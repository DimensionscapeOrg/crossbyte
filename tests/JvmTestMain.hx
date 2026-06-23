class JvmTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner) {
			crossbyte.test.TestSuites.addAuth(runner);
			crossbyte.test.TestSuites.addCrypto(runner);
			crossbyte.test.TestSuites.addCore(runner);
			crossbyte.test.TestSuites.addFoundation(runner);
			crossbyte.test.TestSuites.addErrors(runner);
			crossbyte.test.TestSuites.addEvents(runner);
			crossbyte.test.TestSuites.addDataStructures(runner);
			crossbyte.test.TestSuites.addMath(runner);
			crossbyte.test.TestSuites.addHttp(runner);
			crossbyte.test.TestSuites.addIO(runner);
			crossbyte.test.TestSuites.addURL(runner);
			crossbyte.test.TestSuites.addIPC(runner);
			crossbyte.test.TestSuites.addDatabase(runner);
			crossbyte.test.TestSuites.addSystem(runner);
			crossbyte.test.TestSuites.addNet(runner);
			// addRPC skipped: Haxe 4.3.7 --jvm bytecode VerifyError on RPCSession construction
			crossbyte.test.TestSuites.addResources(runner);
			crossbyte.test.TestSuites.addTimers(runner);
			crossbyte.test.TestSuites.addUtils(runner);
		});
	}
}
