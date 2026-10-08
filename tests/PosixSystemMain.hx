import utest.Runner;

/**
 * System suite on Linux and macOS (`ci/posix-system-tests.hxml`).
 *
 * `crossbyte.sys.System` reaches a different implementation on every native
 * platform (`WinNativeSystem`, `LinuxNativeSystem`, `MacNativeSystem`), and
 * the group that covers it runs from the native smoke suite, which is a
 * Windows job. This runs the same group against the two POSIX
 * implementations, on the runners the crypto job already sets up, so
 * neither ships without anything compiling it (a macOS reporting zero
 * processors, say).
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
