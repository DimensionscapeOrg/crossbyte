/**
	The byte readers' bounds, built with `-D final` (`ci/final-tests.hxml`).

	`final` is what Lime's release builds define, and it once compiled
	`ByteArrayInput`'s checks out, so a short payload read past the end of
	its buffer natively. The suite is never built that way, so the cases that
	say a read past the end throws in every build are run here built that way.
**/
@:topologyExempt("built with -D final, to run the byte readers' bounds as a release build has them")
class FinalBuildMain {
	public static function main():Void {
		#if !final
		throw "Build this with -D final: ci/final-tests.hxml does.";
		#end
		var runner:utest.Runner = new utest.Runner();
		runner.addCase(new crossbyte.io.ByteArrayInputTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
