/**
	The portable suite, run on a JavaScript target.

	`ci/js-build.hxml` and `ci/node-build.hxml` prove that CrossByte compiles
	for the browser and for Node. Compiling is not running: a defect that
	breaks every read and write on js (a `ByteArray` adopting an
	`ArrayBuffer` where its storage is a `Uint8Array`) leaves every js build
	green, because nothing executes a byte of it.

	What runs is `PortableSuite.add`, not a list kept here, so the two cannot
	drift: a copy here could leave out the very case (`BloomFilterTest`,
	whose index arithmetic differs between a 32-bit Int and a double) that
	most needs to run on the target with the double. One list cannot
	disagree with itself.
**/
class JsTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner:utest.Runner):Void {
			crossbyte.test.PortableSuite.add(runner);
			// The server suite as well, which the browser cannot have: it
			// wants a listening socket and a document root, and Node is the
			// target most likely to be deployed as a web server.
			//
			// ServerSuite rather than TestSuites.addHttp: naming TestSuites
			// here compiles every group in it, including a poll backend and a
			// thread lock this build will never reach.
			crossbyte.test.ServerSuite.add(runner);
		});
	}
}
