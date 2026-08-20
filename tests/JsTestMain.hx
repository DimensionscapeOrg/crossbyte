/**
	The portable suite, run on a JavaScript target.

	`ci/js-build.hxml` and `ci/node-build.hxml` prove that CrossByte compiles
	for the browser and for Node. Compiling is not running, and the difference
	has already cost twice: `ByteArray.__setData` adopted an `ArrayBuffer` where
	the storage is a `Uint8Array`, so every read and write on js was broken --
	and every js build was green, because nothing executed a byte of it.

	Only cases that need no threads, no listening socket and no database belong
	here. What they exercise is the part meant to be identical everywhere: the
	collections, the numbers, the byte buffer, the event graph, the crypto and
	the driver-agnostic database logic.
**/
class JsTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(function(runner:utest.Runner):Void {
			runner.addCase(new crossbyte.ds.CollectionsTest());
			runner.addCase(new crossbyte.errors.ErrorsTest());
			runner.addCase(new crossbyte.math.MathTest());
			runner.addCase(new crossbyte.io.ByteArrayCorrectnessTest());
			runner.addCase(new crossbyte.utils.UtilsTest());
			runner.addCase(new crossbyte.db.DBParameterBindingTest());
			runner.addCase(new crossbyte.db.PostgresWireTest());
			runner.addCase(new crossbyte.db.SchemaMigratorTest());
		});
	}
}
