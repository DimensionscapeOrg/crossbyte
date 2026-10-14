/**
	The suite classes that claim PHP, run on PHP.

	Bifrost, which runs on PHP, takes SQLite and its migrations, BCrypt,
	SecureRandom, HMAC-SHA256, Ed25519, EdDSA tokens, Argon2id, ConfigTree and
	Secret from CrossByte there, and the key/value store is built for it, so
	those are what this runs. Naming
	TestSuites from here would compile every group in it, sockets, threads
	and native externs included, which PHP has none of, so the cases are
	listed here, and each is registered in its TestSuites group as well.
**/
@:topologyExempt("PHP compiles only the classes that claim it; naming TestSuites would compile every group")
class PhpTestMain {
	public static function main():Void {
		var runner:utest.Runner = new utest.Runner();
		runner.addCase(new crossbyte.db.SQLiteDriverTest());
		runner.addCase(new crossbyte.db.SQLiteStatementTest());
		runner.addCase(new crossbyte.db.SchemaMigratorPresetTest());
		runner.addCase(new crossbyte.db.SchemaMigratorTest());
		runner.addCase(new crossbyte.db.StorageModesTest());
		runner.addCase(new crossbyte.db.kv.KVKeysTest());
		runner.addCase(new crossbyte.db.kv.MemoryKVStoreTest());
		runner.addCase(new crossbyte.db.kv.KVRepoTest());
		runner.addCase(new crossbyte.db.kv.SQLiteKVStoreTest());
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
		runner.addCase(new crossbyte.auth.SecretTest());
		runner.addCase(new crossbyte.core.ConfigTreeTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
