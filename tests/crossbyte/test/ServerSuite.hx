package crossbyte.test;

import utest.Runner;

/**
	The HTTP cases that need a server -- a listening socket, a document root, or
	the rewrite engine -- and so run on every target that can be one.

	That set now includes Node, and did not before. `TestSuites.addHttp` gated
	its server cases behind `#if cpp`, which was written when the HTTP server
	was native-only; the server has since shipped on Node, so the target most
	likely to be deployed as a web server was the one whose web server no test
	had ever executed. The gate outlived its reason by an entire port.

	A class of its own for the same reason `PortableSuite` is one: naming
	`TestSuites` from a JavaScript build compiles all of `TestSuites`, including
	groups that reference a thread lock and a poll backend, and the build fails
	on types it was never going to run. That is not hypothetical -- it is what
	happened on the first attempt to call `TestSuites.addHttp` from `JsTestMain`.

	Not the browser. A page cannot listen, and no amount of gating changes that;
	the cases here are server cases, not JavaScript cases.

	Every case is also reached by `TestSuites.addAll` through `addHttp`, which
	calls this; `SuiteCoverage` enforces that nothing runs here and nowhere else.
**/
class ServerSuite {
	public static function add(runner:Runner):Void {
		// The socket round trips. Still cpp-only for the four heaviest, which
		// is honest rather than settled: they are written against a
		// synchronous pump and have to be converted case by case, and a
		// conversion that compiles but never calls `async.done()` times out
		// rather than fails -- so each is worth landing under its own green
		// run rather than in one sweep.
		#if cpp
		runner.addCase(new crossbyte.http.HTTPStreamingTest());
		runner.addCase(new crossbyte.http.HTTPServerDrainTest());
		runner.addCase(new crossbyte.http.HTTPServerMetricsTest());
		runner.addCase(new crossbyte.http.HTTPPhpTest());
		#end

		#if (cpp || neko || hl || nodejs)
		runner.addCase(new crossbyte.http.HTTPRequestHandlerTest());
		runner.addCase(new crossbyte.http.RouterServerTest());
		#end

		// No socket, but a filesystem and the rewrite engine, so a page has
		// none of it.
		runner.addCase(new crossbyte.http.HTTPSupportTest());
		runner.addCase(new crossbyte.http.RateLimiterTest());
		runner.addCase(new crossbyte.http.HTTPHardeningTest());
		runner.addCase(new crossbyte.http.RouterTest());
		runner.addCase(new crossbyte._internal.php.PHPTimeoutTest());
	}
}
