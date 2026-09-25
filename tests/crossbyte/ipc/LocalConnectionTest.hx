package crossbyte.ipc;

import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.NetConnection;
import crossbyte.net.Protocol;
import utest.Assert;

class LocalConnectionTest extends utest.Test {
	public function testSupportFlagMatchesTarget():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(LocalConnection.isSupported);
		#else
		Assert.isFalse(LocalConnection.isSupported);
		#end
	}

	public function testListenAndConnectThrowOnUnsupportedTargets():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(LocalConnection.isSupported);
		#else
		var server = new LocalConnection();
		var client = new LocalConnection();
		Assert.isTrue(throws(() -> server.listen("__crossbyte_test__")));
		Assert.isTrue(throws(() -> client.connect("__crossbyte_test__")));
		#end
	}

	public function testRoundTripBytesThroughLocalTransport():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("roundtrip");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:String = null;
		var readyCount = 0;

		try {
			server.onReady = () -> readyCount++;
			server.onData = input -> received = input.readUTFBytes(input.length);
			server.readEnabled = true;
			server.listen(name);

			client.onReady = () -> readyCount++;
			client.connect(name);

			// Waits for what the assertions below actually check. `connected`
			// flips before the ready callbacks have been dispatched -- they are
			// queued onto the runtime tick when they cannot run inline -- so
			// waiting on it alone let the send go out against a half-ready pair
			// and left readyCount at 1 with nothing delivered.
			pumpUntil(() -> readyCount == 2 && server.connected && client.connected, 2.0);
			client.send(bytesOf("hello local"));
			pumpUntil(() -> received != null, 2.0);

			Assert.equals(2, readyCount);
			Assert.equals("hello local", received);
			Assert.equals(Protocol.LOCAL, server.protocol);
			Assert.equals(Protocol.LOCAL, client.protocol);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(server);
		#else
		Assert.pass();
		#end
	}

	public function testReadyAndDataArriveWhileTheRuntimesListenersChange():Void {
		// The reader thread attached the tick listener that carries its
		// dispatches to this thread, and EventDispatcher is not thread-safe:
		// an attach that met a listener change made here was lost, and the
		// listening side then never saw onReady nor anything sent to it. Here
		// the listeners change as fast as this thread can change them, the way
		// timers and sockets change them all the time.
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var kept:TickEvent->Void = _ -> {};
		var churn:TickEvent->Void = _ -> {};
		runtime.addEventListener(TickEvent.TICK, kept);
		var lost:Array<String> = [];

		for (round in 0...40) {
			var server = new LocalConnection();
			var client = new LocalConnection();
			var ready = false;
			var received:String = null;
			try {
				var name = uniqueName("churn");
				server.onReady = () -> ready = true;
				server.onData = input -> received = input.readUTFBytes(input.length);
				server.readEnabled = true;
				server.listen(name);
				client.connect(name);
				client.send(bytesOf('round $round'));

				var deadline = haxe.Timer.stamp() + 2.0;
				while ((!ready || received == null) && haxe.Timer.stamp() < deadline) {
					for (_ in 0...200) {
						runtime.addEventListener(TickEvent.TICK, churn);
						runtime.removeEventListener(TickEvent.TICK, churn);
					}
					runtime.pump(1 / 60, 0);
				}
				if (!ready || received != 'round $round') {
					lost.push('round $round: ready=$ready received=$received');
				}
			} catch (e:Dynamic) {
				lost.push('round $round threw $e');
			}
			closeQuietly(client);
			closeQuietly(server);
		}

		runtime.removeEventListener(TickEvent.TICK, kept);
		Assert.equals(0, lost.length, lost.join("; "));
		#else
		Assert.pass();
		#end
	}

	public function testAConnectionWhosePeerWentAwayIsLetGoOfByTheRuntime():Void {
		// Its tick listener stays on for as long as it can deliver. It came off
		// after every drain before, so the runtime never held a dead connection;
		// held until close(), one never closed would be held for good.
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var before = tickListeners(runtime);
		var name = uniqueName("peergone");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var readyCount = 0;
		var closed = false;

		try {
			server.onReady = () -> readyCount++;
			client.onReady = () -> readyCount++;
			client.onClose = _ -> closed = true;
			server.listen(name);
			client.connect(name);
			pumpUntil(() -> readyCount == 2, 2.0);
			Assert.equals(2, readyCount);

			server.close();
			pumpUntil(() -> closed && tickListeners(runtime) == before, 2.0);

			Assert.isTrue(closed, "the client was not told its peer went away");
			Assert.equals(before, tickListeners(runtime), "the runtime still holds a connection whose peer went away");
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		#else
		Assert.pass();
		#end
	}

	public function testPendingReadsFlushWhenReadEnabledBecomesTrue():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("buffered");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:String = null;

		var readyCount = 0;

		try {
			server.onReady = () -> readyCount++;
			server.onData = input -> received = input.readUTFBytes(input.length);
			server.readEnabled = false;
			server.listen(name);

			client.onReady = () -> readyCount++;
			client.connect(name);

			// Both ends ready, not merely connected: `connected` flips before
			// the ready callbacks are dispatched, and a send against a
			// half-ready pair is lost with nothing to say so. That is what made
			// the round-trip case above fail intermittently.
			pumpUntil(() -> readyCount == 2 && server.connected && client.connected, 2.0);
			client.send(bytesOf("deferred"));
			pumpUntil(() -> true, 0.05);
			Assert.isNull(received);

			server.readEnabled = true;
			pumpUntil(() -> received != null, 2.0);
			Assert.equals("deferred", received);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(server);
		#else
		Assert.pass();
		#end
	}

	public function testNetConnectionRoundTripKeepsLocalTransport():Void {
		var local = new LocalConnection();
		var wrapped:NetConnection = local;
		var restored:LocalConnection = NetConnection.toLocalConnection(wrapped);

		Assert.equals(Protocol.LOCAL, wrapped.protocol);
		Assert.equals(local, restored);
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
		#end
	}

	private static function tickListeners(runtime:CrossByte):Int {
		var map = @:privateAccess runtime.__eventMap;
		var listeners:Array<Dynamic> = map == null ? null : cast map.get(TickEvent.TICK);
		return listeners == null ? 0 : listeners.length;
	}

	private static function closeQuietly(connection:LocalConnection):Void {
		try {
			if (connection != null) {
				connection.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function uniqueName(label:String):String {
		return '__crossbyte_local_${label}_${Std.int(Sys.time() * 1000)}_${Std.random(1000000)}';
	}

	private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
