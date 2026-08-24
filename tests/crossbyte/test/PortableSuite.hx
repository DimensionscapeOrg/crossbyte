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
		// Arithmetic and ordering with no socket in it, so it belongs here for
		// the same reason the STUN codec does -- and it belongs on the browser
		// especially, which is the one target that will be talking ICE to a
		// stack it did not write.
		runner.addCase(new crossbyte.net.ice.IceCandidateTest());
		// The one guarded entry here, and not the kind of guard that makes a
		// case run nowhere: it still runs on Node through this list and on cpp,
		// jvm and the interpreter through `addNet`. The browser is excluded
		// because `LocalAddress` does not exist there at all, along with the
		// rest of the UDP family, so there is no branch of it to execute.
		//
		// It is worth having on Node specifically. That is where its least
		// ordinary code lives: `DatagramSocket` emulates connect() rather than
		// calling it, so `LocalAddress` reaches past it to the real one, and
		// nothing else covers that path. It binds an ephemeral socket and
		// closes it -- no listener, no peer, and no traffic, because asking the
		// routing table sends none.
		#if !(js && !nodejs)
		runner.addCase(new crossbyte.net.LocalAddressTest());
		#end
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
