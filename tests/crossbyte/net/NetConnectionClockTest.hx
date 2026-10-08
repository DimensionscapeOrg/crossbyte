package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import utest.Async;

/**
	A `NetConnection` stamps what it sends and receives with the uptime of
	the runtime its socket runs on: `outTimestamp` and `inTimestamp`, which an
	`RPCSession`'s heartbeat reads against that runtime's clock.

	The reliable and WebSocket connections do not ask `CrossByte.current()`
	for the runtime on every message, which would be a thread-local lookup a
	message, both ways, on the path every message takes, and on JavaScript
	the wrong runtime: a socket's callbacks run there as the application's,
	so a child runtime's connection that received anything, or sent from a
	callback, would be stamped with the application's clock instead of its own.

	On Node the connections run in a child runtime, where the two clocks
	differ; elsewhere in the runtime the suite runs on, where the case holds
	the stamps to that runtime's clock.
**/
@:access(crossbyte.core.CrossByte)
class NetConnectionClockTest extends utest.Test {
	private static inline var DEADLINE:Float = 10.0;

	@:timeout(20000)
	public function testAReliableConnectionIsStampedWithItsRuntimesClock(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}
		__exchange("rudp", async);
	}

	@:timeout(20000)
	public function testAWebSocketConnectionIsStampedWithItsRuntimesClock(async:Async):Void {
		// A WebSocket client draws its key from a secure random source.
		if (!crossbyte.crypto.SecureRandom.isSupported) {
			Assert.isFalse(crossbyte.crypto.SecureRandom.isSupported);
			async.done();
			return;
		}
		__exchange("ws", async);
	}

	/**
		A host and a client of `scheme` in one runtime (a child on Node), the
		client sending from `onReady` and the host's connection receiving:
		both from a socket's callback. Each stamp is compared with the
		runtime's uptime where it was taken.
	**/
	private static function __exchange(scheme:String, async:Async):Void {
		var host:NetHost = null;
		var client:NetConnection = null;
		var failure:String = null;
		var sentStamp:Float = -1;
		var sentClock:Float = -1;
		var heardStamp:Float = -1;
		var heardClock:Float = -1;
		var runtime:CrossByte = null;

		function listen():Void {
			host = new NetHost(scheme + "://127.0.0.1:0", function(connection:INetConnection):Void {
				connection.onData = function(_):Void {
					if (heardStamp < 0) {
						heardStamp = connection.inTimestamp;
						heardClock = runtime.uptime;
					}
				};
				connection.readEnabled = true;
			}, null, reason -> failure = "the host: " + Std.string(reason), true);
		}

		// Once the host has a port, which on Node is a turn after it listens.
		function dial():Void {
			if (client != null || host == null || host.localPort == 0) {
				return;
			}
			client = new NetConnection(scheme + "://127.0.0.1:" + host.localPort, null, function():Void {
				var message = new ByteArray();
				message.writeUTFBytes("what time is it");
				message.position = 0;
				client.send(message);
				sentStamp = client.outTimestamp;
				sentClock = runtime.uptime;
			}, null, reason -> failure = "the client: " + Std.string(reason));
		}

		function finish():Void {
			Assert.isNull(failure, failure);
			Assert.isTrue(sentStamp >= 0, "the client never became ready");
			Assert.isTrue(heardStamp >= 0, "the host's connection heard nothing");
			Assert.equals(sentClock, sentStamp, "what the client sent was stamped " + sentStamp + ", another runtime's clock than its own " + sentClock);
			Assert.equals(heardClock, heardStamp, "what the host heard was stamped " + heardStamp + ", another runtime's clock than its own " + heardClock);
		}

		function close():Void {
			try {
				if (client != null) {
					client.close();
				}
			} catch (_:Dynamic) {}
			try {
				if (host != null) {
					host.close();
				}
			} catch (_:Dynamic) {}
		}

		#if js
		// A child, whose clock is not the application's, and whose sockets'
		// callbacks run as the application's all the same.
		runtime = CrossByte.make(DEFAULT, HEAP, configured -> {
			configured.tps = 100;
			configured.addEventListener(Event.INIT, _ -> listen());
			configured.addEventListener(TickEvent.TICK, _ -> dial());
		});

		NetPump.until(() -> failure != null || heardStamp >= 0, DEADLINE, function(_) {
			finish();
			var child = runtime;
			child.post(function():Void {
				close();
				child.exit();
			});
			NetPump.until(() -> child.__didExit, DEADLINE, _ -> async.done());
		});
		#else
		runtime = CrossByte.current();
		var onTick = (_:TickEvent) -> dial();
		runtime.addEventListener(TickEvent.TICK, onTick);
		listen();

		NetPump.until(() -> failure != null || heardStamp >= 0, DEADLINE, function(_) {
			runtime.removeEventListener(TickEvent.TICK, onTick);
			finish();
			close();
			async.done();
		});
		#end
	}
}
