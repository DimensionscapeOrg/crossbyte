package crossbyte.foundation;

import crossbyte.Object;
import crossbyte.TypedObject;
import utest.Assert;

/**
	`Object` used as an ActionScript or JavaScript programmer uses one, and
	answering the same on every target.
**/
class ObjectTest extends utest.Test {
	/**
		ActionScript's `Object` methods answer the same on every target.
		Called through the object's own fields, as they were, they answered
		only on JavaScript, where every object's prototype has them, and threw
		on every other target (natively, on a null `Object`, the process
		ended).
	**/
	public function testActionScriptsMethodsAnswerTheSameEverywhere():Void {
		var payload:Object = haxe.Json.parse('{"a":1,"b":null}');
		Assert.isTrue(payload.hasOwnProperty("a"));
		Assert.isTrue(payload.hasOwnProperty("b"), "a field holding null is the object's own");
		Assert.isFalse(payload.hasOwnProperty("c"));
		Assert.isFalse(payload.hasOwnProperty("toString"), "a prototype's method was taken for a field");
		Assert.isTrue(payload.propertyIsEnumerable("a"));
		Assert.isFalse(payload.propertyIsEnumerable("c"));
		Assert.isFalse(payload.isPrototypeOf({}));
		Assert.isTrue(payload.valueOf() == payload);
		var number:Object = 3;
		Assert.equals("3", number.toString());
		Assert.equals("3", number.toLocaleString());
		var text:Object = "x";
		Assert.equals("x", text.toString());
		Assert.isTrue(number.valueOf() == 3);

		var instance:Object = new Sealed();
		Assert.isFalse(instance.propertyIsEnumerable("field"), "a class instance's field was enumerable");
		Assert.isFalse(instance.isPrototypeOf(new Sealed()));
	}

	/**
		`for (name => value in object)` walks an `Object`'s fields, and a
		`TypedObject`'s, as it does a map's. It compiled on an `Object`, and
		on every target threw as it began: the loop looked for
		`keyValueIterator` among the object's fields.
	**/
	public function testAKeyAndValueLoopWalksTheFields():Void {
		var payload:Object = haxe.Json.parse('{"a":1,"b":"two","c":null}');
		var seen:Array<String> = [];
		var walked:Dynamic = null;
		try {
			for (name => value in payload) {
				seen.push(name + "=" + Std.string(value));
			}
		} catch (e:Dynamic) {
			walked = e;
		}
		Assert.isNull(walked, "the loop threw " + walked);
		seen.sort(Reflect.compare);
		Assert.same(["a=1", "b=two", "c=null"], seen);

		var nothing:Object = null;
		var none:Int = 0;
		try {
			for (name => value in nothing) {
				none++;
			}
		} catch (_:Dynamic) {
			none = -1;
		}
		Assert.equals(0, none, "a null Object's loop threw");

		var typed:TypedObject<{id:Int, name:String}> = {id: 4, name: "t"};
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf(for (name => value in typed) {}), "a TypedObject could not be walked by a key and value loop");
		var typedSeen:Array<String> = [for (name => value in typed) name + "=" + Std.string(value)];
		typedSeen.sort(Reflect.compare);
		Assert.same(["id=4", "name=t"], typedSeen);
	}

	/**
		An `Array`, a `String`, a number, a `Bool` or a function has no fields
		to list or walk, on every target. Each listed its own: an `Array`'s
		`length` on eval, `length` and `__a` on the jvm, `__a` on Neko, `array`
		and `allowReinterpret` on HashLink and its indices on Node; a
		`String`'s `length` on eval, `value` and `hash` on the jvm, `__s` on
		Neko and its characters on Node; an `Int`'s `value` on the jvm, where
		eval threw.
	**/
	public function testAValueThatIsNotAnObjectHasNoFields():Void {
		var values:Array<Object> = [haxe.Json.parse("[7,8,9]"), [1, 2, 3], "ab", 5, 1.5, true, function() return 1];
		for (value in values) {
			var shown:String = Std.string(value);
			var keys:Array<String> = [];
			var walked:Array<String> = [];
			var found:Array<Dynamic> = [];
			var entries:Int = -1;
			try {
				keys = value.keys();
				walked = [for (key in value) key];
				found = value.values();
				entries = 0;
				for (_ in value.entries()) {
					entries++;
				}
			} catch (e:Dynamic) {
				Assert.fail(shown + " threw " + e);
			}
			Assert.same([], keys, shown + " had fields");
			Assert.same([], walked, shown + " was walked");
			Assert.same([], found, shown + " had values");
			Assert.equals(0, entries, shown + " had entries");
		}
		var list:Object = [7, 8];
		Assert.equals(2, list.length);
	}

	/**
		What Haxe keeps on an object for itself is not a field of it: on
		JavaScript an object used as a key in an `ObjectMap` is given an
		`__id__`.
	**/
	public function testKeysLeaveOutWhatHaxeKeepsOnAnObject():Void {
		var payload:Object = haxe.Json.parse('{"a":1,"b":2}');
		var map = new haxe.ds.ObjectMap<{}, Int>();
		map.set(payload, 1);
		var keys:Array<String> = payload.keys();
		keys.sort(Reflect.compare);
		Assert.same(["a", "b"], keys);
		Assert.same(2, payload.values().length);
		var walked:Int = 0;
		for (_ in payload.entries()) {
			walked++;
		}
		Assert.equals(2, walked);
	}

	/** The same of a null `Object`: no fields, and `"null"` as text. **/
	public function testActionScriptsMethodsOfANullObject():Void {
		var nothing:Object = null;
		Assert.isFalse(nothing.hasOwnProperty("a"));
		Assert.isFalse(nothing.propertyIsEnumerable("a"));
		Assert.isFalse(nothing.isPrototypeOf({}));
		Assert.isNull(nothing.valueOf());
		Assert.equals("null", nothing.toString());
	}
}

private class Sealed {
	public var field:Int = 1;

	public function new() {}
}
