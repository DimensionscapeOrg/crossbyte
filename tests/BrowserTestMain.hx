/**
	The portable suite, in a real browser.

	`JsTestMain` runs the same cases on Node, and that is not the same test.
	Node has no `window`, no `document`, and none of a page's restrictions --
	so a browser build Node runs happily can still fail to load in a page. It
	did: `Random`'s seed was a `haxe.atomic.AtomicInt`, Haxe implements that on
	js with a `SharedArrayBuffer`, and an ordinary page is not given one. Being
	a static initialiser, it threw while the bundle loaded, before any
	application code ran, and every js build stayed green.

	Registration goes through `TestHarness` like every other entry point, not
	around it: the harness establishes the primordial runtime first, and
	without that every case needing a timer or `CrossByte.current()` fails.
	Skipping it cost thirteen failures and two hundred and fifty missing
	assertions on the first run of this file.

	The result goes on `window` rather than to stdout, because a page has not
	got one. `ci/browser/run.js` reads it.
**/
class BrowserTestMain {
	public static function main():Void {
		var successes:Int = 0;
		var failures:Int = 0;

		crossbyte.test.TestHarness.run(function(runner:utest.Runner):Void {
			crossbyte.test.PortableSuite.add(runner);

			runner.onProgress.add(function(progress):Void {
				for (assertation in progress.result.assertations) {
					switch (assertation) {
						case Success(_):
							successes++;
						default:
							failures++;
					}
				}
			});

			runner.onComplete.add(function(_):Void {
				js.Syntax.code("window.__crossbyte = {done: true, successes: {0}, failures: {1}}", successes, failures);
			});
		});
	}
}
