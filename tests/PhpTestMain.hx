/**
	The suite classes that claim PHP, run on PHP.

	Bifrost, which runs on PHP, takes SQLite, BCrypt, SecureRandom,
	HMAC-SHA256, Ed25519, EdDSA tokens and Argon2id from CrossByte there, so those
	are what this runs. Naming
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
		runner.addCase(new crossbyte.crypto.password.BCryptHardeningTest());
		runner.addCase(new crossbyte.crypto.password.BCryptVectorsTest());
		runner.addCase(new crossbyte.crypto.password.BCryptByteVectorsTest());
		runner.addCase(new crossbyte.crypto.SecureRandomTest());
		runner.addCase(new crossbyte.crypto.HmacSha256Test());
		runner.addCase(new crossbyte.crypto.Ed25519VectorsTest());
		runner.addCase(new crossbyte.crypto.password.Argon2idVectorsTest());
		runner.addCase(new crossbyte.auth.jwt.EdDSAJwtTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
