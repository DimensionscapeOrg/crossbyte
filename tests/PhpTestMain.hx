/**
	The suite classes that claim PHP, run on PHP.

	Bifrost, which runs on PHP, takes SQLite and its migrations, BCrypt,
	SecureRandom, HMAC-SHA256, Ed25519, EdDSA tokens, Argon2id, ConfigTree and
	Secret from CrossByte there, and the key/value store is built for it, so
	those are what this runs, and RPC: its
	contracts, its codec and its sessions over in-process connections, the
	ByteArray reads and writes its bytes go through, BitWriter and
	BitReader, whose layout its bit fields share, and the spatial grids a
	server picks each observer's entries with; and the rest of crossbyte.io
	that needs neither a thread nor a socket: ByteArray's other classes,
	ByteDelta, Store, FileStream (which opens a file asynchronously only to
	read there, as on Node), and File and its path arithmetic. PHP
	has no sockets in CrossByte, so the RPC cases that open one are left out
	there, each in its class; RPCSlowPeerTest has no other, and is not here.
	Naming TestSuites from here would compile every group in it, sockets,
	threads and native externs included, which PHP has none of, so the cases
	are listed here, and each is registered in its TestSuites group as well.
	They run under the harness's runtime, which RPC sessions need.
**/
@:topologyExempt("PHP compiles only the classes that claim it; naming TestSuites would compile every group")
class PhpTestMain {
	public static function main():Void {
		crossbyte.test.TestHarness.run(runner -> {
			runner.addCase(new crossbyte.db.SQLiteDriverTest());
			runner.addCase(new crossbyte.db.SQLiteStatementTest());
			runner.addCase(new crossbyte.db.SchemaMigratorPresetTest());
			runner.addCase(new crossbyte.db.SchemaMigratorTest());
			runner.addCase(new crossbyte.db.StorageModesTest());
			runner.addCase(new crossbyte.db.kv.KVKeysTest());
			runner.addCase(new crossbyte.db.kv.MemoryKVStoreTest());
			runner.addCase(new crossbyte.db.kv.KVRepoTest());
			runner.addCase(new crossbyte.db.kv.KVRepoRPCTest());
			runner.addCase(new crossbyte.db.kv.SQLiteKVStoreTest());
			runner.addCase(new crossbyte.net.RateLimitStoreTest());
			runner.addCase(new crossbyte.net.TrustedProxiesTest());
			runner.addCase(new crossbyte.db.kv.KVSupportTest());
			runner.addCase(new crossbyte.crypto.password.BCryptHardeningTest());
			runner.addCase(new crossbyte.crypto.password.BCryptVectorsTest());
			runner.addCase(new crossbyte.crypto.password.BCryptByteVectorsTest());
			runner.addCase(new crossbyte.crypto.SecureRandomTest());
			runner.addCase(new crossbyte.crypto.HmacSha256Test());
			runner.addCase(new crossbyte.crypto.Ed25519VectorsTest());
			runner.addCase(new crossbyte.crypto.password.Argon2idVectorsTest());
			runner.addCase(new crossbyte.auth.jwt.EdDSAJwtTest());
			runner.addCase(new crossbyte.auth.jwt.JWKSetTest());
			runner.addCase(new crossbyte.auth.jwt.JWTTest());
			runner.addCase(new crossbyte.auth.jwt.JWTVerifyTest());
			runner.addCase(new crossbyte.auth.jwt.JWTOptionsTest());
			runner.addCase(new crossbyte.auth.jwt.JWTClaimsTest());
			runner.addCase(new crossbyte.auth.jwt.JWTRevocationTest());
			runner.addCase(new crossbyte.auth.SecretTest());
			runner.addCase(new crossbyte.core.ConfigTreeTest());
			runner.addCase(new crossbyte.utils.UtilsTest());
			runner.addCase(new crossbyte.io.ByteArrayIOTest());
			runner.addCase(new crossbyte.io.ByteArrayCorrectnessTest());
			runner.addCase(new crossbyte.io.ByteArrayInputTest());
			runner.addCase(new crossbyte.io.ByteArrayTest());
			runner.addCase(new crossbyte.io.ByteArrayOutputTest());
			runner.addCase(new crossbyte.io.ByteDeltaTest());
			runner.addCase(new crossbyte.io.BitPackingTest());
			runner.addCase(new crossbyte.io.StoreTest());
			runner.addCase(new crossbyte.io.FilePathTest());
			runner.addCase(new crossbyte.io.FileTest());
			runner.addCase(new crossbyte.io.FileStreamTest());
			runner.addCase(new crossbyte.io.FileStreamContractTest());
			runner.addCase(new crossbyte.io.FileStreamAsyncRefusalTest());
			runner.addCase(new crossbyte.ds.SpatialGridTest());
			runner.addCase(new crossbyte.ds.SparseSpatialGridTest());
			addRPC(runner);
		});
	}

	/** The RPC classes, as TestSuites.addRPC lists them, but RPCSlowPeerTest. **/
	static function addRPC(runner:utest.Runner):Void {
		runner.addCase(new crossbyte.rpc.RPCTest());
		runner.addCase(new crossbyte.rpc.RPCRobustnessTest());
		runner.addCase(new crossbyte.rpc.RPCContractTest());
		runner.addCase(new crossbyte.rpc.RPCCallHookTest());
		runner.addCase(new crossbyte.rpc.RPCAsyncTest());
		runner.addCase(new crossbyte.rpc.RPCSharedHandlerTest());
		runner.addCase(new crossbyte.rpc.RPCNullReturnTest());
		runner.addCase(new crossbyte.rpc.RPCHeartbeatTest());
		runner.addCase(new crossbyte.rpc.RPCDeadlineTest());
		runner.addCase(new crossbyte.rpc.RPCUnhandledCallTest());
		runner.addCase(new crossbyte.rpc.RPCUnsendableCallTest());
		runner.addCase(new crossbyte.rpc.RPCReadyAgainTest());
		runner.addCase(new crossbyte.rpc.RPCPeerCloseCodeTest());
		runner.addCase(new crossbyte.rpc.RPCFrameTest());
		runner.addCase(new crossbyte.rpc.RPCSignatureTest());
		runner.addCase(new crossbyte.rpc.RPCMethodNamesTest());
		runner.addCase(new crossbyte.rpc.RPCTypedSessionTest());
		runner.addCase(new crossbyte.rpc.RPCCallControlTest());
		runner.addCase(new crossbyte.rpc.RPCCallDataTest());
		runner.addCase(new crossbyte.rpc.RPCDeliveryTest());
		runner.addCase(new crossbyte.rpc.RPCEdgesTest());
		runner.addCase(new crossbyte.rpc.RPCRefusalTest());
		runner.addCase(new crossbyte.rpc.RPCReliableStreamTest());
		runner.addCase(new crossbyte.rpc.RPCChunkTest());
		runner.addCase(new crossbyte.rpc.RPCOversizeTest());
		runner.addCase(new crossbyte.rpc.RPCHelloTest());
		runner.addCase(new crossbyte.rpc.RPCRuntimeCodecTest());
		runner.addCase(new crossbyte.rpc.RPCPendingCallsTest());
		runner.addCase(new crossbyte.rpc.RPCArrayTest());
		runner.addCase(new crossbyte.rpc.RPCMapTest());
		runner.addCase(new crossbyte.rpc.RPCCompactTest());
		runner.addCase(new crossbyte.rpc.RPCVarIntTest());
		runner.addCase(new crossbyte.rpc.RPCPatchTest());
		runner.addCase(new crossbyte.rpc.RPCMapPatchTest());
		runner.addCase(new crossbyte.rpc.RPCPatchSizeTest());
		runner.addCase(new crossbyte.rpc.RPCMapBudgetTest());
		runner.addCase(new crossbyte.rpc.RPCBitsTest());
		runner.addCase(new crossbyte.rpc.RPCReuseTest());
		runner.addCase(new crossbyte.rpc.RPCStructTest());
		runner.addCase(new crossbyte.rpc.RPCEnumTest());
		runner.addCase(new crossbyte.rpc.RPCNullTypesTest());
		runner.addCase(new crossbyte.rpc.RPCCallWriterTest());
		runner.addCase(new crossbyte.rpc.RPCArgsTest());
		runner.addCase(new crossbyte.rpc.RPCReceiverTest());
		runner.addCase(new crossbyte.rpc.RPCLargeSurfaceTest());
		runner.addCase(new crossbyte.rpc.RPCWideSurfaceTest());
		runner.addCase(new crossbyte.rpc.RPCConnectionEndTest());
		runner.addCase(new crossbyte.rpc.RPCDialTest());
		runner.addCase(new crossbyte.rpc.RPCTransportTest());
	}
}
