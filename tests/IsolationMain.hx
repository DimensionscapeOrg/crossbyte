class IsolationMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner) {
			crossbyte.test.TestSuites.addNativeSmoke(runner);
			#if subset_auth
			crossbyte.test.TestSuites.addAuth(runner);
			#end
			#if subset_foundation
			crossbyte.test.TestSuites.addFoundation(runner);
			#end
			#if subset_ds
			crossbyte.test.TestSuites.addDataStructures(runner);
			#end
			#if subset_math
			crossbyte.test.TestSuites.addMath(runner);
			#end
			#if subset_io
			crossbyte.test.TestSuites.addIO(runner);
			#end
			#if subset_url
			crossbyte.test.TestSuites.addURL(runner);
			#end
			#if subset_ipc
			crossbyte.test.TestSuites.addIPC(runner);
			#end
			#if subset_db
			crossbyte.test.TestSuites.addDatabase(runner);
			#end
			#if subset_resources
			crossbyte.test.TestSuites.addResources(runner);
			#end
			#if subset_utils
			crossbyte.test.TestSuites.addUtils(runner);
			#end
		});
	}
}
