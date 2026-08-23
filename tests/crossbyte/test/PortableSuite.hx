package crossbyte.test;

import utest.Runner;

/**
	The cases that need no thread, no socket, no database and no filesystem,
	and so mean the same thing on every target CrossByte builds for --
	including the browser and Node.

	It exists because `JsTestMain` used to hand-list them. Two lists of one
	thing drift, and this one drifted: `BloomFilterTest` was in the other one,
	so the case whose index arithmetic differs between a 32-bit Int and a
	double was precisely the case not running on the target with the double.

	It is a class of its own rather than a group in `TestSuites`, and that is
	not organisation for its own sake. Naming `TestSuites` compiles all of
	`TestSuites`, including the groups that reference a listening socket and a
	thread lock -- so a JavaScript build that so much as mentioned it failed to
	compile on types it was never going to run. A file this size pulls in only
	what it lists.

	Every case here is also reached by `TestSuites.addAll`, through its own
	subsystem group; `SuiteCoverage` enforces that, so this cannot become a
	private corner where a case runs on js and nowhere else. It is not called
	from `addAll` in turn, which would run each of them twice there.
**/
class PortableSuite {
	public static function add(runner:Runner):Void {
		runner.addCase(new crossbyte.net.StunMessageTest());
		runner.addCase(new crossbyte.FutureTest());
		runner.addCase(new crossbyte.ds.CollectionsTest());
		// Not portable in the sense of needing nothing -- it needs a backend --
		// but portable in the sense that matters: the same assertions run
		// against IndexedDB here and a directory of files everywhere else, so
		// neither backend grades its own homework.
		runner.addCase(new crossbyte.io.StoreTest());
		runner.addCase(new crossbyte._internal.compression.CompressionRoundTripTest());
		runner.addCase(new crossbyte._internal.http.h2.hpack.HpackTest());
		runner.addCase(new crossbyte._internal.http.h2.H2Test());
		runner.addCase(new crossbyte._internal.http.h2.H2ServerTest());
		runner.addCase(new crossbyte.ds.BloomFilterTest());
		runner.addCase(new crossbyte.errors.ErrorsTest());
		runner.addCase(new crossbyte.math.MathTest());
		runner.addCase(new crossbyte.timer.TimerStampTest());
		runner.addCase(new crossbyte.io.ByteArrayCorrectnessTest());
		runner.addCase(new crossbyte.utils.UtilsTest());
		runner.addCase(new crossbyte.db.DBParameterBindingTest());
		runner.addCase(new crossbyte.db.PostgresWireTest());
		runner.addCase(new crossbyte.db.SchemaMigratorTest());
		runner.addCase(new crossbyte.rpc.RPCTest());
		runner.addCase(new crossbyte.rpc.RPCRobustnessTest());
	}
}
