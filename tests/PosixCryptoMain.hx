import utest.Runner;

/**
 * Crypto and auth suites for Linux and macOS (`ci/posix-crypto-tests.hxml`).
 *
 * libsodium, BLAKE3 and the mbedTLS-backed public-key code are compiled from
 * source with hxcpp on every platform, and the native smoke suite covers them
 * on Windows. This target proves the same surface builds and behaves on the
 * other two, under GCC and Clang, which a Windows development machine cannot
 * show: the first run here found SIMD flags MSVC had never needed and a
 * duplicate object only GNU ld objects to.
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
