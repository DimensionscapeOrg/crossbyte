package crossbyte.test;

import crossbyte.net.RateLimiter;
import utest.Runner;

/**
	The cases that need a server -- a listening socket, a document root, or the
	rewrite engine -- and so run on every target that can be one. Mostly HTTP,
	and not only.

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
		// The socket round trips, on every target that can listen.
		#if (cpp || neko || hl || nodejs || java || jvm)
		// Not HTTP, but the same selection criterion: it needs a listening
		// socket. It is here rather than beside the other ServerWebSocket cases
		// because those pump synchronously, which on Node blocks the event loop
		// the accept callback arrives on -- and Node is exactly the target this
		// one was written to reach.
		// Malformed traffic at a live server, which is the only way to reach
		// request parser as a peer reaches it: across reads, into a buffer
		// that persists, behind a handler that owns a socket.
		runner.addCase(new crossbyte.fuzz.HTTPWireFuzzTest());
		runner.addCase(new crossbyte.net.ServerWebSocketUpgradeReapTest());
		runner.addCase(new crossbyte.http.HTTPServerDefaultsTest());
		runner.addCase(new crossbyte.http.HTTPRequestHandlerTest());
		runner.addCase(new crossbyte.http.HTTPStreamingTest());
		runner.addCase(new crossbyte.http.HTTPServerDrainTest());
		runner.addCase(new crossbyte.http.HTTPServerMetricsTest());
		runner.addCase(new crossbyte.http.RouterServerTest());
		runner.addCase(new crossbyte.http.HTTPServerH2Test());
		#end

		// PHP stays native-only, and not for a reason the bridge shares: the
		// test drives a FastCGI backend over `crossbyte.net.ServerSocket` and
		// holds the accepted peer, which is fine on Node -- what it also does
		// is construct `PHPMode.Launch` paths through `sys.io.Process` in the
		// cases around it. The Node PHP path has its own coverage in the
		// integration program, against the same kind of fake backend.
		#if cpp
		runner.addCase(new crossbyte.http.HTTPPhpTest());
		#end

		// Registered outside the gate above: its socket case is guarded inside
		// the class, and the configuration case needs nothing and should run
		// everywhere the server does -- including Node, where `tlsEnabled`
		// decides whether a listener is secure just the same.
		runner.addCase(new crossbyte.http.HTTPServerTLSTest());

		// No socket, but a filesystem and the rewrite engine, so a page has
		// none of it.
		runner.addCase(new crossbyte.http.HTTPSupportTest());
		runner.addCase(new crossbyte.net.RateLimiterTest());
		runner.addCase(new crossbyte.net.ConcurrencyLimiterTest());
		runner.addCase(new crossbyte.http.HTTPHardeningTest());
		runner.addCase(new crossbyte.http.RouterTest());
		runner.addCase(new crossbyte._internal.php.PHPTimeoutTest());
	}
}
