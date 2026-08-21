package crossbyte._internal.php;

import crossbyte._internal.php.PHPBridge;
import crossbyte.core.CrossByte;
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
		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", port), "", ["index.php"], 0.5);

		var started:Float = Sys.time();
		var future = bridge.execute(request());
		var returned:Float = Sys.time() - started;

		// The assertion the blocking bridge could not have: execute() comes
		// back at once. It used to sit here for the whole exchange, inside the
		// tick, so a slow page stopped every other connection this runtime was
		// serving. Half a second is the deadline; returning well inside it is
		// the proof that the wait moved off the call.
		Assert.isTrue(returned < 0.25, "execute() blocked for " + returned + "s instead of returning a Future");

		var runtime = CrossByte.current();
		var deadline:Float = Sys.time() + 15;

		while (!future.completed && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0.0);
			Sys.sleep(0.005);
		}

		var elapsed:Float = Sys.time() - started;

		try {
			listener.close();
		} catch (_:Dynamic) {}

		Assert.isTrue(future.completed, "the exchange never settled");
		Assert.isFalse(future.succeeded, "a backend that said nothing produced a response");
		Assert.isTrue(future.error.indexOf("did not respond within") >= 0, "not reported as a timeout: " + future.error);
		Assert.isTrue(elapsed < 10, "the exchange took " + elapsed + "s, which is not a deadline");
	}

	public function testTheRuntimeKeepsTickingWhilePhpIsThinking():Void {
		var listener = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(1);

		var bridge = new PHPBridge(PHPMode.Connect("127.0.0.1", listener.host().port), "", ["index.php"], 0.5);
		var future = bridge.execute(request());

		// The point of the whole change, stated as a measurement: the runtime
		// goes on dispatching ticks while an exchange is outstanding. Under the
		// blocking bridge this loop could not have run at all -- execute() had
		// not returned yet.
		var runtime = CrossByte.current();
		var ticks:Int = 0;
		var onTick = function(_):Void {
			ticks++;
		};

		runtime.addEventListener(crossbyte.events.TickEvent.TICK, onTick);

		var deadline:Float = Sys.time() + 15;

		while (!future.completed && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0.0);
			Sys.sleep(0.005);
		}

		runtime.removeEventListener(crossbyte.events.TickEvent.TICK, onTick);

		try {
			listener.close();
		} catch (_:Dynamic) {}

		Assert.isTrue(ticks > 1, "the runtime ticked " + ticks + " times while PHP was thinking");
		Assert.isTrue(future.completed, "the exchange never settled");
	}

	private function request():PHPRequest {
		return {
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
