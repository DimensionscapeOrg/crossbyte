package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.http.HTTPTestSupport;
import utest.Assert;
import utest.Async;

/**
 * `ServerWebSocket` accepts through a loop of its own, so the admission it
 * inherits from `ServerSocket` has to be proved here separately: before,
 * `admit` set on one compiled and was never asked, and it took one
 * connection a tick.
 */
class ServerWebSocketAdmissionTest extends utest.Test {
	private static function pending(server:ServerWebSocket):Int {
		return @:privateAccess server.__pendingUpgrades.length;
	}

	private static function closeQuietly(socket:Socket):Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}

	@:timeout(5000)
	public function testARefusedPeerIsClosedBeforeAnyUpgradeWork(async:Async):Void {
		var server = new ServerWebSocket();
		var asked:Array<String> = [];
		var everPending:Bool = false;
		server.admit = (address, _) -> {
			asked.push(address);
			return false;
		};
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new Socket();
		var ended:Bool = false;
		client.addEventListener(Event.CLOSE, _ -> ended = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, _ -> ended = true);

		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, _ -> {
			client.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> {
				if (pending(server) > 0) {
					everPending = true;
				}
				return ended;
			}, 3.0, closed -> {
				Assert.isTrue(closed, "the refused peer was never closed");
				Assert.same(["127.0.0.1"], asked);
				Assert.isFalse(everPending, "a refused peer was taken on as a session");
				Assert.equals(0, server.clientCount);
				closeQuietly(client);
				server.close();
				async.done();
			});
		});
	}

	@:timeout(5000)
	public function testAnAdmittedPeerBecomesASessionWaitingToUpgrade(async:Async):Void {
		var server = new ServerWebSocket();
		var asked:Array<String> = [];
		server.admit = (address, _) -> {
			asked.push(address);
			return true;
		};
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new Socket();
		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, _ -> {
			client.connect("127.0.0.1", server.localPort);
			HTTPTestSupport.pumpUntilAsync(() -> pending(server) > 0, 3.0, recorded -> {
				Assert.isTrue(recorded, "the admitted peer never became a session");
				Assert.same(["127.0.0.1"], asked);
				closeQuietly(client);
				server.close();
				async.done();
			});
		});
	}

	#if !nodejs
	/**
		A hundred connections queued before the first tick, as in
		ServerSocketAdmissionTest; each becomes a session waiting to upgrade.
	**/
	private static function ticksToTake(count:Int, perTick:Int):Int {
		var runtime = CrossByte.current();
		var server = new ServerWebSocket();
		server.maxAcceptsPerTick = perTick;
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
			while (pending(server) < count && ticks < 1000) {
				runtime.pump(1 / 60, 0);
				ticks++;
			}
		} catch (e:Dynamic) {
			Assert.fail("the burst could not be set up: " + Std.string(e));
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
		var ticks:Int = ticksToTake(100, 64);
		Assert.isTrue(ticks <= 3, 'a hundred waiting connections took $ticks ticks');
	}

	public function testTheRateIsTheOneAskedFor():Void {
		var ticks:Int = ticksToTake(100, 10);
		Assert.isTrue(ticks >= 10 && ticks <= 13, 'ten a tick took $ticks ticks for a hundred');
	}

	public function testSessionsStillUpgradingAreCapped():Void {
		var runtime = CrossByte.current();
		var server = new ServerWebSocket();
		server.maxPendingHandshakes = 5;
		server.bind(0, "127.0.0.1");
		server.listen();

		// Twenty connections that never ask to upgrade.
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
			Assert.equals(5, pending(server));

			// The rest were left in the kernel's queue, not refused.
			server.maxPendingHandshakes = 100;
			for (_ in 0...10) {
				runtime.pump(1 / 60, 0);
			}
			Assert.equals(20, pending(server));
		} catch (e:Dynamic) {
			Assert.fail("the silent connections could not be set up: " + Std.string(e));
		}

		for (raw in silent) {
			try {
				raw.close();
			} catch (_:Dynamic) {}
		}
		server.close();
	}
	#end

	#if nodejs
	@:timeout(5000)
	public function testOnNodeAPeerPastTheBoundIsRefused(async:Async):Void {
		// Node accepts as connections arrive, so there is no kernel queue to
		// leave the third one in: past the bound it is refused.
		var server = new ServerWebSocket();
		server.maxPendingHandshakes = 2;
		server.bind(0, "127.0.0.1");
		server.listen();

		var clients:Array<Socket> = [];
		var ended:Int = 0;
		HTTPTestSupport.pumpUntilAsync(() -> server.localPort != 0, 2.0, _ -> {
			for (_ in 0...3) {
				var client = new Socket();
				client.addEventListener(Event.CLOSE, _ -> ended++);
				client.addEventListener(IOErrorEvent.IO_ERROR, _ -> ended++);
				client.connect("127.0.0.1", server.localPort);
				clients.push(client);
			}
			HTTPTestSupport.pumpUntilAsync(() -> ended >= 1 && pending(server) == 2, 3.0, settled -> {
				Assert.isTrue(settled, 'pending ${pending(server)}, ended $ended');
				Assert.equals(2, pending(server));
				Assert.equals(1, ended);
				for (client in clients) {
					closeQuietly(client);
				}
				server.close();
				async.done();
			});
		});
	}
	#end
}
