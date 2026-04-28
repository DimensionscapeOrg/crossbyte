package crossbyte.integration;

import crossbyte.core.CrossByte;
import crossbyte.ipc.LocalConnection;
import haxe.Serializer;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

@:access(crossbyte.core.CrossByte)
@:access(crossbyte.ipc.LocalConnection)
class LocalConnectionIntegrationMain {
	private static inline var WAIT_SECONDS:Float = 5;

	public static function main():Void {
		#if (cpp && (windows || linux || mac || macos))
		new CrossByte(true, DEFAULT, true);

		var name:String = "__crossbyte_lc_integration_" + Std.int(Sys.time() * 1000) + "_" + Std.random(1000000);
		var receiver = new LocalConnection();
		var client = new ReceiverClient();
		receiver.client = client;

		var sender:LocalConnection = null;
		var reconnectSender:LocalConnection = null;
		var finalSender:LocalConnection = null;
		var rawPipe:Dynamic = null;

		try {
			receiver.connect(name);

			sender = new LocalConnection();
			sender.send(name, "receive", cast "first", cast 1, cast {kind: "primitive"});
			waitFor(() -> client.calls == 1, "first message");
			assertEquals("first", client.lastMessage, "first message text");
			assertEquals(1, client.lastValue, "first message value");
			assertEquals("primitive", Reflect.field(client.lastPayload, "kind"), "first payload kind");

			sender.close();
			sender = null;

			reconnectSender = new LocalConnection();
			reconnectSender.send(name, "receive", cast "second", cast 2, cast {kind: "reconnect"});
			waitFor(() -> client.calls == 2, "reconnected sender message");
			assertEquals("second", client.lastMessage, "second message text");
			assertEquals(2, client.lastValue, "second message value");
			assertEquals("reconnect", Reflect.field(client.lastPayload, "kind"), "second payload kind");

			rawPipe = LocalConnection.__connect(name);
			if (rawPipe == null) {
				throw "raw pipe connect failed";
			}
			if (!LocalConnection.__write(rawPipe, Bytes.ofString("bad-frame").getData(), 9)) {
				throw "raw malformed frame write failed";
			}
			LocalConnection.__close(rawPipe);
			rawPipe = null;

			finalSender = new LocalConnection();
			finalSender.send(name, "receive", cast "third", cast 3, cast {kind: "after-malformed"});
			waitFor(() -> client.calls == 3, "valid message after malformed frame");
			assertEquals("third", client.lastMessage, "third message text");
			assertEquals(3, client.lastValue, "third message value");
			assertEquals("after-malformed", Reflect.field(client.lastPayload, "kind"), "third payload kind");

			receiver.close();
			reconnectSender.close();
			finalSender.close();
			Sys.println("LocalConnection integration OK");
		} catch (e:Dynamic) {
			if (rawPipe != null) {
				LocalConnection.__close(rawPipe);
			}
			if (sender != null) {
				sender.close();
			}
			if (reconnectSender != null) {
				reconnectSender.close();
			}
			if (finalSender != null) {
				finalSender.close();
			}
			receiver.close();
			throw e;
		}
		#else
		Sys.println("LocalConnection integration skipped: native cpp IPC not supported on this target");
		#end
	}

	private static function waitFor(predicate:Void->Bool, label:String):Void {
		var deadline:Float = Sys.time() + WAIT_SECONDS;
		while (Sys.time() < deadline) {
			if (predicate()) {
				return;
			}
			Sys.sleep(0.01);
		}
		throw 'Timed out waiting for $label';
	}

	private static function assertEquals(expected:Dynamic, actual:Dynamic, label:String):Void {
		if (expected != actual) {
			throw '$label: expected $expected, got $actual';
		}
	}
}

private class ReceiverClient {
	public var calls:Int = 0;
	public var lastMessage:String;
	public var lastValue:Int = -1;
	public var lastPayload:Dynamic;

	public function new() {}

	public function receive(message:String, value:Int, payload:Dynamic):Void {
		calls++;
		lastMessage = message;
		lastValue = value;
		lastPayload = payload;
	}
}
