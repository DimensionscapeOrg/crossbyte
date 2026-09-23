package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.http.HTTPTestSupport;
import utest.Assert;
import utest.Async;

/**
 * What a listener takes, how fast, and what it refuses before paying for it.
 */
class ServerSocketAdmissionTest extends utest.Test {
	private static function closeQuietly(socket:Socket):Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}

	// The harness's runtime is driven by whoever pumps it -- a loop here on
	// native, event loop turns on Node -- so every wait below is a pump.
	private static function afterListening(server:ServerSocket, then:Void->Void):Void {
		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, _ -> then());
	}

	private function refusedByAHook(async:Async, hook:(String, Int) -> Bool, check:(Array<String>, Int) -> Void):Void {
		var server = new ServerSocket();
		var asked:Array<String> = [];
		var connected:Int = 0;

		server.admit = (address, port) -> {
			asked.push(address);
			return hook(address, port);
		};
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			connected++;
			closeQuietly(cast event.socket);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new Socket();
		var ended:Bool = false;
		client.addEventListener(Event.CLOSE, _ -> ended = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, _ -> ended = true);

		afterListening(server, () -> {
			client.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> ended, 3.0, closed -> {
				// A few more turns, for a connect event that should not come.
				HTTPTestSupport.pumpMoreAsync(10, () -> {
					Assert.isTrue(closed, "the refused client was never closed");
					check(asked, connected);
					closeQuietly(client);
					server.close();
					async.done();
				});
			});
		});
	}

	@:timeout(5000)
	public function testARefusedPeerNeverBecomesAConnection(async:Async):Void {
		refusedByAHook(async, (_, _) -> false, (asked, connected) -> {
			Assert.same(["127.0.0.1"], asked);
			Assert.equals(0, connected);
		});
	}

	@:timeout(5000)
	public function testAHookThatThrowsRefuses(async:Async):Void {
		refusedByAHook(async, (_, _) -> throw "the hook's own bug", (asked, connected) -> {
			Assert.equals(1, asked.length);
			Assert.equals(0, connected);
		});
	}

	@:timeout(5000)
	public function testAnAdmittedPeerConnectsAndTheHookSawIt(async:Async):Void {
		var server = new ServerSocket();
		var asked:Array<String> = [];
		var client = new Socket();
		var accepted:Socket = null;

		server.admit = (address, port) -> {
			asked.push('$address:$port');
			return true;
		};
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> accepted = cast event.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		afterListening(server, () -> {
			client.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> accepted != null, 3.0, arrived -> {
				Assert.isTrue(arrived, "the admitted peer never became a connection");
				if (arrived) {
					// Canonical, and the port the peer really has.
					Assert.same(['127.0.0.1:${accepted.remotePort}'], asked);
					closeQuietly(accepted);
				}
				closeQuietly(client);
				server.close();
				async.done();
			});
		});
	}

	#if !nodejs
	/**
		Connections that have finished their TCP handshake and are waiting in
		the listen queue, made with blocking connects so that every one is there
		before the first tick. A hundred, under the smallest queue this runs
		against: macOS keeps 128.
	**/
	private static function ticksToAccept(count:Int, perTick:Int):Int {
		var runtime = CrossByte.current();
		var server = new ServerSocket();
		server.maxAcceptsPerTick = perTick;
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> accepted.push(cast event.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var waiting:Array<sys.net.Socket> = [];
		var ticks:Int = 0;
		try {
			for (_ in 0...count) {
				var raw = new sys.net.Socket();
				raw.connect(new sys.net.Host("127.0.0.1"), server.localPort);
				waiting.push(raw);
			}
			while (accepted.length < count && ticks < 1000) {
				runtime.pump(1 / 60, 0);
				ticks++;
			}
		} catch (e:Dynamic) {
			Assert.fail("the burst could not be set up: " + Std.string(e));
		}

		for (socket in accepted) {
			closeQuietly(socket);
		}
		for (raw in waiting) {
			try {
				raw.close();
			} catch (_:Dynamic) {}
		}
		server.close();
		return ticks;
	}

	public function testAQueuedBurstIsTakenInAFewTicks():Void {
		// One a tick, as it was, this took a hundred ticks.
		var ticks:Int = ticksToAccept(100, 64);
		Assert.isTrue(ticks <= 3, 'a hundred waiting connections took $ticks ticks');
	}

	public function testTheRateIsTheOneAskedFor():Void {
		var ticks:Int = ticksToAccept(100, 10);
		Assert.isTrue(ticks >= 10 && ticks <= 13, 'ten a tick took $ticks ticks for a hundred');
	}
	#end

	#if (cpp || java || jvm)
	public function testHandshakesInFlightAreCapped():Void {
		var fixture = TLSTestFixture.selfSigned();
		if (fixture == null) {
			// No certificate toolchain on this machine.
			Assert.pass();
			return;
		}

		var runtime = CrossByte.current();
		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.maxPendingHandshakes = 5;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> closeQuietly(cast event.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		// Twenty connections that never say hello.
		var silent:Array<sys.net.Socket> = [];
		try {
			for (_ in 0...20) {
				var raw = new sys.net.Socket();
				raw.connect(new sys.net.Host("127.0.0.1"), server.localPort);
				silent.push(raw);
			}

			for (_ in 0...10) {
				runtime.pump(1 / 60, 0);
			}
			Assert.equals(5, server.pendingHandshakeCount());

			// The rest were left waiting in the kernel, not refused: with room,
			// they are taken.
			server.maxPendingHandshakes = 100;
			for (_ in 0...10) {
				runtime.pump(1 / 60, 0);
			}
			Assert.equals(20, server.pendingHandshakeCount());
		} catch (e:Dynamic) {
			Assert.fail("the silent handshakes could not be set up: " + Std.string(e));
		}

		for (raw in silent) {
			try {
				raw.close();
			} catch (_:Dynamic) {}
		}
		server.close();
	}
	#end
}
