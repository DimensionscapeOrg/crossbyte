package crossbyte.test;

import crossbyte.net.RateLimiter;
import utest.Runner;

/**
	The cases that need a server, a listening socket, a document root, or the
	rewrite engine, and so run on every target that can be one. Mostly HTTP,
	and not only.

	That set now includes Node, and did not before. `TestSuites.addHttp` gated
	its server cases behind `#if cpp`, which was written when the HTTP server
	was native-only; the server has since shipped on Node, so the target most
	likely to be deployed as a web server was the one whose web server no test
	had ever executed. The gate outlived its reason by an entire port.

	A class of its own for the same reason `PortableSuite` is one: naming
	`TestSuites` from a JavaScript build compiles all of `TestSuites`, including
	groups that reference a thread lock and a poll backend, and the build fails
	on types it was never going to run. That is not hypothetical, it is what
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
		// the accept callback arrives on, and Node is exactly the target this
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
		// One server's connections on several runtimes; its cases are the
		// threaded targets' (on Node a spread server is refused).
		runner.addCase(new crossbyte.http.HTTPServerSpreadTest());
		runner.addCase(new crossbyte.http.HTTPServerMetricsTest());
		runner.addCase(new crossbyte.http.RouterServerTest());
		runner.addCase(new crossbyte.http.HTTPServerH2Test());
		runner.addCase(new crossbyte.http.HTTPStaticPathTest());
		runner.addCase(new crossbyte.http.HTTPRequestFramingTest());
		runner.addCase(new crossbyte.http.HTTPRateLimitTest());
		runner.addCase(new crossbyte.http.HTTPResponseStreamTest());
		// What the server compresses, and what its answers say about it.
		runner.addCase(new crossbyte.http.HTTPCompressionTest());
		// What a listener takes and what it refuses, on every target that can
		// listen, Node included, whose TLS server asks on a different event.
		runner.addCase(new crossbyte.net.ServerSocketAdmissionTest());
		// The same for the WebSocket server, which accepts through a loop of
		// its own and so has to be proved separately.
		runner.addCase(new crossbyte.net.ServerWebSocketAdmissionTest());
		#end

		// PHP end to end runs natively, on the jvm, and on hl and neko, whose
		// servers are the same code; its body compiled for all five and was
		// registered for three, so on hl and neko it ran nowhere. Not eval,
		// where none of the server cases above run; the bridge itself is
		// driven on eval by PHPExchangeTest, now that it reads only what the
		// poll set reports rather than draining a socket that cannot be made
		// non-blocking. Not Node either, and not for a reason the bridge shares:
		// the test drives a FastCGI backend over `crossbyte.net.ServerSocket`
		// and holds the accepted peer, which is fine on Node, what it also
		// does is construct `PHPMode.Launch` paths through `sys.io.Process` in
		// the cases around it. The Node PHP path has its own coverage in the
		// integration program, against the same kind of fake backend.
		#if (cpp || hl || neko || java || jvm)
		runner.addCase(new crossbyte.http.HTTPPhpTest());
		#end

		// Registered outside the gate above: its socket case is guarded inside
		// the class, and the configuration case needs nothing and should run
		// everywhere the server does, including Node, where `tlsEnabled`
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
		runner.addCase(new crossbyte._internal.php.PHPExchangeTest());

		#if nodejs
		// URLLoader over Node's own http client, against Node's http server:
		// the one client that did not decode a content coding.
		runner.addCase(new crossbyte.url.URLLoaderNodeTest());
		#end
	}
}
