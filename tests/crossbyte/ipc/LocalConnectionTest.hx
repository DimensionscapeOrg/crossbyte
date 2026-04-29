package crossbyte.ipc;

import crossbyte.core.CrossByte;
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

			pumpUntil(() -> server.connected && client.connected, 2.0);
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

	public function testPendingReadsFlushWhenReadEnabledBecomesTrue():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("buffered");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:String = null;

		try {
			server.onData = input -> received = input.readUTFBytes(input.length);
			server.readEnabled = false;
			server.listen(name);
			client.connect(name);

			pumpUntil(() -> server.connected && client.connected, 2.0);
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
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
		#end
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
