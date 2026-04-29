package crossbyte.integration;

import crossbyte.core.CrossByte;
import crossbyte.ipc.LocalConnection;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;

@:access(crossbyte.core.CrossByte)
@:access(crossbyte.ipc.LocalConnection)
class LocalConnectionIntegrationMain {
	private static inline var WAIT_SECONDS:Float = 5;

	public static function main():Void {
		#if (cpp && (windows || linux || mac || macos))
		new CrossByte(true, DEFAULT, true);

		var name:String = "__crossbyte_lc_integration_" + Std.int(Sys.time() * 1000) + "_" + Std.random(1000000);
		var receiver = new LocalConnection();
		var state = new ReceiverState();
		receiver.onData = input -> {
			state.calls++;
			state.lastMessage = input.readUTF();
			state.lastValue = input.readInt();
		};
		receiver.readEnabled = true;

		var sender:LocalConnection = null;
		var reconnectSender:LocalConnection = null;
		var finalSender:LocalConnection = null;
		var rawPipe:Dynamic = null;

		try {
			receiver.listen(name);

			sender = new LocalConnection();
			sender.connect(name);
			waitFor(() -> receiver.connected && sender.connected, "first connection");
			sender.send(message("first", 1));
			waitFor(() -> state.calls == 1, "first message");
			assertEquals("first", state.lastMessage, "first message text");
			assertEquals(1, state.lastValue, "first message value");

			sender.close();
			sender = null;

			reconnectSender = new LocalConnection();
			reconnectSender.connect(name);
			waitFor(() -> receiver.connected && reconnectSender.connected, "reconnected sender connection");
			reconnectSender.send(message("second", 2));
			waitFor(() -> state.calls == 2, "reconnected sender message");
			assertEquals("second", state.lastMessage, "second message text");
			assertEquals(2, state.lastValue, "second message value");

			rawPipe = LocalConnection.__connect(name);
			if (rawPipe == null) {
				throw "raw pipe connect failed";
			}
			var malformed = Bytes.ofString("bad-frame");
			if (!LocalConnection.__write(rawPipe, malformed.getData(), malformed.length)) {
				throw "raw malformed frame write failed";
			}
			LocalConnection.__close(rawPipe);
			rawPipe = null;

			finalSender = new LocalConnection();
			finalSender.connect(name);
			waitFor(() -> receiver.connected && finalSender.connected, "final sender connection");
			finalSender.send(message("third", 3));
			waitFor(() -> state.calls == 3, "valid message after malformed frame");
			assertEquals("third", state.lastMessage, "third message text");
			assertEquals(3, state.lastValue, "third message value");

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

	private static function message(text:String, value:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTF(text);
		bytes.writeInt(value);
		bytes.position = 0;
		return bytes;
	}
}

private class ReceiverState {
	public var calls:Int = 0;
	public var lastMessage:String;
	public var lastValue:Int = -1;

	public function new() {}
}
