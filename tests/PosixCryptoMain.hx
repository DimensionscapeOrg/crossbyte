import utest.Runner;

/**
 * Crypto suite built against a system libsodium
 * (`ci/posix-crypto-tests.hxml`).
 *
 * The Windows build links a vendored static libsodium, so the native smoke
 * suite already covers it there. This target exists to prove the same
 * surface works on Linux and macOS, where libsodium comes from the system
 * package manager — a path that cannot be exercised on a Windows
 * development machine.
 */
@:access(crossbyte.core.CrossByte)
class PosixCryptoMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		crossbyte.test.TestSuites.addCrypto(runner);
		crossbyte.test.TestSuites.addAuth(runner);
		utest.ui.Report.create(runner);
		runner.run();
	}
}
