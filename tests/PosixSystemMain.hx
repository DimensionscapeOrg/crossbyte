import utest.Runner;

/**
 * System suite on Linux and macOS (`ci/posix-system-tests.hxml`).
 *
 * `crossbyte.sys.System` reaches a different implementation on every native
 * platform -- `WinNativeSystem`, `LinuxNativeSystem`, `MacNativeSystem` -- and
 * only the Windows one was ever exercised by CI, because the group that covers
 * it runs from the native smoke suite and that is a Windows job. So the two
 * POSIX implementations shipped without anything compiling them, which is how
 * macOS came to report zero processors.
 *
 * This runs the same group against both, on the runners the crypto job already
 * sets up.
 */
@:access(crossbyte.core.CrossByte)
class PosixSystemMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		crossbyte.test.TestSuites.addSystem(runner);
		utest.ui.Report.create(runner);
		runner.run();
	}
}
