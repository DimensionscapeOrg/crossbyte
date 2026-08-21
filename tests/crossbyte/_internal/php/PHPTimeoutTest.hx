package crossbyte._internal.php;

import crossbyte._internal.php.PHPBridge;
import crossbyte._internal.php.PHPTimeout;
import haxe.io.Bytes;
import utest.Assert;

/**
 * The deadline on a FastCGI exchange.
 *
 * There was none. No socket timeout either, so a backend that accepted a
 * connection and then said nothing held the runtime thread for as long as it
 * cared to -- and a CrossByte runtime serves all of its connections from one
 * tick, so that stopped the whole server for every client at once, with no
 * recovery short of killing the process.
 *
 * The peer here is a plain listening socket that accepts and never replies,
 * which is precisely that failure and needs no PHP to reproduce. It is the
 * cheapest possible test for the most expensive possible outage.
 */
class PHPTimeoutTest extends utest.Test {
	#if (cpp || neko || hl)
	public function testABackendThatNeverAnswersFailsInsteadOfHanging():Void {
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(1);

		var port:Int = listener.host().port;
		// Deliberately short. What is under test is that a bound exchange ends
		// at all, not the accuracy of the bound.
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", port), "", ["index.php"], 0.5);

		var request:PHPRequest = {
			requestMethod: "GET",
			scriptFilename: "/tmp/index.php",
			scriptName: "/index.php",
			requestUri: "/index.php",
			queryString: "",
			contentType: "",
			remoteAddr: "127.0.0.1",
			serverName: "localhost",
			serverPort: "80",
			extraHeaders: new haxe.ds.StringMap(),
			body: Bytes.alloc(0)
		};

		var started:Float = Sys.time();
		var timedOut:Bool = false;
		var other:String = null;

		try {
			bridge.execute(request);
		} catch (e:PHPTimeout) {
			timedOut = true;
		} catch (e:Dynamic) {
			other = Std.string(e);
		}

		var elapsed:Float = Sys.time() - started;

		try {
			listener.close();
		} catch (_:Dynamic) {}

		Assert.isTrue(timedOut, other != null ? "expected a timeout, got: " + other : "the exchange did not time out");
		// The upper bound is the assertion that matters. Without a deadline
		// this call does not return at all, so any finite number here is the
		// difference between a stalled request and a stalled server.
		Assert.isTrue(elapsed < 15, "the exchange took " + elapsed + "s, which is not a deadline");
	}

	public function testTheDeadlineCanBeTurnedOff():Void {
		// Zero means no deadline, which is what this class did unconditionally
		// before. Kept configurable rather than mandatory: a deployment with a
		// legitimately slow report should be able to say so.
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", 1), "", ["index.php"], 0);
		Assert.equals(0.0, bridge.timeoutSeconds);
	}

	public function testTheDefaultIsAFiniteDeadline():Void {
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", 1), "", ["index.php"]);
		Assert.isTrue(bridge.timeoutSeconds > 0, "the default deadline is " + bridge.timeoutSeconds);
	}
	#end
}
