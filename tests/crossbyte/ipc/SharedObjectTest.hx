package crossbyte.ipc;

import haxe.Timer;
import utest.Assert;

@:access(crossbyte.ipc.SharedObject)
class SharedObjectTest extends utest.Test {
	public function testSupportFlagMatchesTarget():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(SharedObject.isSupported);
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testConstructingUnsupportedTargetThrows():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(SharedObject.isSupported);
		#else
		var name:String = "crossbyte_sharedobject_test_" + Std.int(Timer.stamp() * 1000);
		Assert.isTrue(throws(function() {
			new SharedObject(name);
		}));
		#end
	}

	public function testSharedObjectRoundTrip():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name:String = uniqueName("roundtrip");
		var writer = null;
		var reader = null;
		try {
			writer = new SharedObject(name, 8192);
			writer.data = {message: "hello", value: 42, active: true};
			writer.flush();

			reader = new SharedObject(name, 8192);
			Assert.equals("hello", reader.data.message);
			Assert.equals(42, reader.data.value);
			Assert.equals(true, reader.data.active);

			reader.data.value = 99;
			reader.flush();
			writer.sync();

			Assert.equals(99, writer.data.value);

			writer.clear();
			Assert.equals(0, Reflect.fields(writer.data).length);
		} catch (e:Dynamic) {
			if (reader != null) {
				reader.close();
			}
			if (writer != null) {
				writer.close();
			}
			throw e;
		}
		if (reader != null) {
			reader.close();
		}
		if (writer != null) {
			writer.close();
		}
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testSanitizedNameCollisionsStayIsolated():Void {
		#if (cpp && (windows || linux || mac || macos))
		var base:String = uniqueName("alias");
		var first:SharedObject = null;
		var second:SharedObject = null;
		var third:SharedObject = null;
		try {
			first = new SharedObject(base + "/same", 8192);
			second = new SharedObject(base + ":same", 8192);
			third = new SharedObject(base + "_same", 8192);

			first.data = {value: "slash"};
			second.data = {value: "colon"};
			third.data = {value: "underscore"};
			first.flush();
			second.flush();
			third.flush();

			first.sync();
			second.sync();
			third.sync();
			Assert.equals("slash", first.data.value);
			Assert.equals("colon", second.data.value);
			Assert.equals("underscore", third.data.value);
		} catch (e:Dynamic) {
			closeIfOpen(first);
			closeIfOpen(second);
			closeIfOpen(third);
			throw e;
		}
		closeIfOpen(first);
		closeIfOpen(second);
		closeIfOpen(third);
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testOversizedPayloadThrows():Void {
		#if (cpp && (windows || linux || mac || macos))
		var shared:SharedObject = null;
		try {
			shared = new SharedObject(uniqueName("oversized"), 32);
			shared.data = {message: "this payload should be much larger than the tiny shared object capacity"};
			Assert.isTrue(throws(function() {
				shared.flush();
			}));
		} catch (e:Dynamic) {
			closeIfOpen(shared);
			throw e;
		}
		closeIfOpen(shared);
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	public function testClosedSharedObjectRejectsOperations():Void {
		#if (cpp && (windows || linux || mac || macos))
		var shared = new SharedObject(uniqueName("closed"), 8192);
		shared.close();
		Assert.isTrue(throws(function() {
			shared.flush();
		}));
		Assert.isTrue(throws(function() {
			shared.sync();
		}));
		Assert.isTrue(throws(function() {
			shared.clear();
		}));
		#else
		Assert.isFalse(SharedObject.isSupported);
		#end
	}

	private static function uniqueName(label:String):String {
		return "crossbyte_sharedobject_" + label + "_" + Std.int(Timer.stamp() * 1000) + "_" + Std.random(1000000);
	}

	private static function closeIfOpen(shared:SharedObject):Void {
		if (shared != null) {
			shared.close();
		}
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
