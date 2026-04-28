package crossbyte.ipc;

import crossbyte.core.CrossByte;
import haxe.Serializer;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import utest.Assert;
#if (cpp || neko || hl)
import sys.thread.Thread;
#end

@:access(crossbyte.ipc.LocalConnection)
@:access(crossbyte.core.CrossByte)
class LocalConnectionTest extends utest.Test {
	public function testSupportFlagMatchesTarget():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(LocalConnection.isSupported);
		#else
		Assert.isFalse(LocalConnection.isSupported);
		#end
	}

	public function testConnectThrowsOnUnsupportedTargets():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(LocalConnection.isSupported);
		#else
		var connection = new LocalConnection();
		Assert.isTrue(throws(function() {
			connection.connect("__crossbyte_test__");
		}));
		#end
	}

	public function testCloseClearsRunningState():Void {
		var connection = new LocalConnection();
		connection.__running = true;

		connection.close();

		Assert.isFalse(connection.__running);
	}

	public function testValidFrameInvokesClientMethod():Void {
		var connection = new LocalConnection();
		var receiver = new LocalConnectionReceiver();
		connection.client = receiver;

		connection.__onData(frame("receive", ["hello", 42]));

		Assert.equals("hello", receiver.lastMessage);
		Assert.equals(42, receiver.lastValue);
		Assert.equals(1, receiver.calls);
	}

	public function testMalformedFramesAreIgnored():Void {
		var connection = new LocalConnection();
		var receiver = new LocalConnectionReceiver();
		connection.client = receiver;

		connection.__onData(Bytes.ofString(""));
		connection.__onData(frameWithLengths(257, 0));
		connection.__onData(frameWithLengths(5, 1024 * 1024 + 1));

		Assert.equals(0, receiver.calls);
	}

	public function testCorruptSerializedPayloadIsIgnored():Void {
		var connection = new LocalConnection();
		var receiver = new LocalConnectionReceiver();
		connection.client = receiver;

		connection.__onData(frameSerialized("receive", "!not-haxe-serialized-data"));

		Assert.equals(0, receiver.calls);
	}

	public function testOversizedFrameIsIgnored():Void {
		var connection = new LocalConnection();
		var receiver = new LocalConnectionReceiver();
		connection.client = receiver;

		connection.__onData(Bytes.alloc(LocalConnection.MAX_MESSAGE_SIZE + 1));

		Assert.equals(0, receiver.calls);
	}

	public function testUnknownOrNonFunctionMethodsAreIgnored():Void {
		var connection = new LocalConnection();
		var receiver = new LocalConnectionReceiver();
		connection.client = receiver;

		connection.__onData(frame("missing", []));
		connection.__onData(frame("label", []));

		Assert.equals(0, receiver.calls);
	}

	public function testNullClientIgnoresData():Void {
		var connection = new LocalConnection();
		connection.__onData(frame("receive", ["ignored", 1]));

		Assert.pass();
	}

	public function testForeignThreadDeliveryWaitsForOwningRuntimePump():Void {
		#if (cpp && (windows || linux || mac || macos))
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);
		var connection = new LocalConnection();
		var receiver = new LocalConnectionReceiver();
		connection.client = receiver;

		Thread.create(() -> connection.__dispatchReceivedData(frame("receive", ["hello", 42])));
		Sys.sleep(0.01);

		Assert.equals(0, receiver.calls);
		primordial.pump(1 / 60, 0);
		Assert.equals(0, receiver.calls);

		pumpRuntimeUntil(child, () -> receiver.calls == 1);

		Assert.equals(1, receiver.calls);
		Assert.equals("hello", receiver.lastMessage);
		Assert.equals(42, receiver.lastValue);
		Assert.equals(child, receiver.runtime);
		connection.close();
		child.exit();
		#else
		Assert.pass();
		#end
	}

	private static function frame(method:String, args:Array<Dynamic>):Bytes {
		var methodBytes = Bytes.ofString(method);
		var serialized = Serializer.run(args);
		var serializedBytes = Bytes.ofString(serialized);
		var buffer = new BytesBuffer();
		buffer.addInt32(methodBytes.length);
		buffer.addBytes(methodBytes, 0, methodBytes.length);
		buffer.addInt32(serializedBytes.length);
		buffer.addBytes(serializedBytes, 0, serializedBytes.length);
		return buffer.getBytes();
	}

	private static function frameSerialized(method:String, serialized:String):Bytes {
		var methodBytes = Bytes.ofString(method);
		var serializedBytes = Bytes.ofString(serialized);
		var buffer = new BytesBuffer();
		buffer.addInt32(methodBytes.length);
		buffer.addBytes(methodBytes, 0, methodBytes.length);
		buffer.addInt32(serializedBytes.length);
		buffer.addBytes(serializedBytes, 0, serializedBytes.length);
		return buffer.getBytes();
	}

	private static function frameWithLengths(methodLength:Int, serializationLength:Int):Bytes {
		var buffer = new BytesBuffer();
		buffer.addInt32(methodLength);
		buffer.addInt32(serializationLength);
		return buffer.getBytes();
	}

	private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}

	private static function pumpRuntimeUntil(runtime:CrossByte, done:Void->Bool, timeoutSeconds:Float = 2.0):Void {
		#if (cpp || neko || hl)
		var deadline = Sys.time() + timeoutSeconds;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
		#end
	}
}

private class LocalConnectionReceiver {
	public var calls:Int = 0;
	public var label:String = "not callable";
	public var lastMessage:String = null;
	public var lastValue:Int = 0;
	public var runtime:CrossByte = null;

	public function new() {}

	public function receive(message:String, value:Int):Void {
		calls++;
		lastMessage = message;
		lastValue = value;
		runtime = CrossByte.current();
	}
}
