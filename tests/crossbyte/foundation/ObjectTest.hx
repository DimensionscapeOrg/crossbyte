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
		`object[i]` reads and writes an `Array`'s elements, the array growing
		to a write past its end as an `Array` does, and of anything else names
		the field, as ActionScript's `object[0]` does. It did not compile: an
		`Object` took a `String` in brackets and nothing else.
	**/
	public function testAnObjectIsIndexedByANumber():Void {
		var list:Object = haxe.Json.parse("[7,8,9]");
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf(list[1]), "an Object could not be indexed by a number");
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf(list[1] = 2), "an Object could not be written by a number");
	}

	public function testAnArrayIsReadAndWrittenByIndex():Void {
		var list:Object = haxe.Json.parse("[7,8,9]");
		Assert.equals(8, list[1]);
		Assert.isNull(list[3], "an element past the end was read");
		Assert.isNull(list[-1]);
		list[1] = 80;
		list[4] = 10;
		Assert.equals(80, list[1]);
		Assert.equals(5, list.length);
		Assert.same([7, 80, 9, null, 10], [for (i in 0...list.length) list[i]]);
		Assert.raises(() -> list[-1] = 0, crossbyte.errors.RangeError);

		// An Array<Int>, which HashLink keeps as an array of its own kind.
		var numbers:Object = [1, 2, 3];
		Assert.equals(2, numbers[1]);
		Assert.isNull(numbers[3], "an Array<Int> was read past its end");

		var record:Object = haxe.Json.parse('{"0":"zero"}');
		Assert.equals("zero", record[0]);
		record[1] = "one";
		Assert.equals("one", record["1"]);
		Assert.isNull(record[2]);
		var nothing:Object = null;
		Assert.isNull(nothing[0]);
	}

	/**
		A null name has no field: `get` reads null, `exists` and `remove`
		answer false, and `set` throws an `ArgumentError`. Natively each
		ended the process; elsewhere each target answered its own way (a
		thrown "Null Access" on eval, "Invalid field access" on Neko, a
		`set` that did nothing on the jvm).
	**/
	public function testANullNameHasNoField():Void {
		var payload:Object = haxe.Json.parse('{"a":1,"null":2}');
		var name:Null<String> = null;
		#if !js
		Assert.isNull(payload.get(name), "a null name read a field");
		#end
		Assert.isFalse(payload.exists(name));
		Assert.isFalse(payload.remove(name));
		Assert.raises(() -> payload.set(name, 3), crossbyte.errors.ArgumentError);
		Assert.raises(() -> payload[name] = 3, crossbyte.errors.ArgumentError);
		var keys:Array<String> = payload.keys();
		keys.sort(Reflect.compare);
		Assert.same(["a", "null"], keys, "a null name changed the fields");
		Assert.equals(2, payload["null"]);
	}

	/**
		The same of a `TypedObject`, whose `get`, `exists` and `set` ended the
		process natively for a null name, and on Node threw from `get` and
		`set` a `TypeError`.
	**/
	public function testANullNameHasNoFieldOfATypedObject():Void {
		var typed:TypedObject<{id:Int}> = haxe.Json.parse('{"id":1,"null":2}');
		var name:Null<String> = null;
		#if !js
		Assert.isNull(typed[name], "a null name read a field");
		#end
		Assert.isFalse(typed.exists(name));
		Assert.raises(() -> typed[name] = 3, crossbyte.errors.ArgumentError);
		Assert.equals(1, typed.id);
		Assert.equals(2, typed["null"]);
	}

	/**
		An `Object` converts on its own to `Dynamic` and to nothing else, and
		its own arithmetic does not compile. It converted to anything,
		unchecked, and each target made its own of that: one holding "12" as
		an `Int` was "12" on eval, Neko and Node (so `n + 1` was "121"), 12
		natively, and a cast that threw on the jvm and HashLink; `if (object)`
		of 3 was taken natively, on Node and HashLink, not on eval or Neko,
		and threw on the jvm. Its fields are `Dynamic`, as they were; a value
		is taken as a type with `cast`, and as text with `toString()`.
	**/
	public function testAnObjectConvertsOnlyToDynamic():Void {
		var number:Object = "12";
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf({
			var n:Int = number;
		}), "an Object became an Int");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf({
			var f:Float = number;
		}), "an Object became a Float");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf({
			var b:Bool = number;
		}), "an Object became a Bool");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf({
			var d:Date = number;
		}), "an Object became a Date without a cast");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf(number + 1), "an Object was added to");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf(number * 2), "an Object was multiplied");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf(-number), "an Object was negated");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf(if (number) 1 else 0), "an Object was a condition");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf({
			var s:String = number;
		}), "an Object became a String without a cast");
		Assert.notNull(crossbyte.ds.TypeCheck.errorOf({
			var structure:{} = number;
		}), "an Object became a structure without a cast");

		var three:Object = 3;
		Assert.equals("3", three.toString());
		Assert.equals(12, Std.parseInt(number.toString()));
		var loose:Dynamic = three;
		Assert.equals(3, loose);
		var payload:Object = haxe.Json.parse('{"hits":3}');
		var hits:Int = payload.hits;
		Assert.equals(4, hits + 1);
		var instance:Object = new Sealed();
		var sealed:Sealed = cast instance;
		Assert.equals(1, sealed.field);
		Assert.equals(1, cast(instance, Sealed).field);
	}

	/** The documentation's example, as written there, run. **/
	public function testTheDocumentedExample():Void {
		var seen:Array<String> = [];
		var payload:Object = haxe.Json.parse('{"name":"ada","hits":3,"tags":["a","b"]}');
		payload.hits++;
		var hits:Int = payload.hits;
		var tags:Object = payload.tags;
		var first:String = tags[0];
		if (!payload.hasOwnProperty("score")) {
			payload["score"] = hits * 10;
		}
		for (name => value in payload) {
			seen.push(name + " = " + value);
		}
		var text:String = payload.toString();
		Assert.equals(4, hits);
		Assert.equals("a", first);
		Assert.equals(40, payload["score"]);
		Assert.equals(4, seen.length);
		for (line in ["hits = 4", "name = ada", "score = 40"]) {
			Assert.isTrue(seen.indexOf(line) >= 0, line + " not in " + seen);
		}
		Assert.isTrue(text.indexOf("ada") >= 0, text);
	}

	/**
		What Haxe keeps on an object for itself is not a field of it: on
		JavaScript an object used as a key in an `ObjectMap` is given an
		`__id__`.
	**/
	public function testKeysLeaveOutWhatHaxeKeepsOnAnObject():Void {
		var payload:Object = haxe.Json.parse('{"a":1,"b":2}');
		var map = new haxe.ds.ObjectMap<{}, Int>();
		map.set(cast payload, 1);
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
