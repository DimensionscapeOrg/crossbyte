/**
	The portable suite, run on a JavaScript target.

	`ci/js-build.hxml` and `ci/node-build.hxml` prove that CrossByte compiles
	for the browser and for Node. Compiling is not running, and the difference
	has already cost twice: `ByteArray.__setData` adopted an `ArrayBuffer` where
	the storage is a `Uint8Array`, so every read and write on js was broken --
	and every js build was green, because nothing executed a byte of it.

	What runs is `PortableSuite.add`, not a list kept here. This file used
	to carry its own copy, and the two drifted: `BloomFilterTest` was in the
	other one, so the case whose index arithmetic differs between a 32-bit Int
	and a double was precisely the case not running on the target with the
	double. One list cannot disagree with itself.
**/
class JsTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner:utest.Runner):Void {
			crossbyte.test.PortableSuite.add(runner);
			// The server suite as well, which the browser cannot have: it
			// wants a listening socket and a document root. It ran only on cpp
			// before, behind a gate older than the Node server itself, so the
			// target most likely to be deployed as a web server was the one
			// whose web server no test had ever executed.
			//
			// ServerSuite rather than TestSuites.addHttp: naming TestSuites
			// here compiles every group in it, and the first attempt died on a
			// poll backend and a thread lock this build will never reach.
			crossbyte.test.ServerSuite.add(runner);
		});
	}
}
