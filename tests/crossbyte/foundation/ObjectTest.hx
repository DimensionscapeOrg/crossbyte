package crossbyte.foundation;

import crossbyte.Object;
import crossbyte.TypedObject;
import crossbyte.events.Event;
import crossbyte.net.Socket;
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
		An `Object` converts on its own to the type it is assigned to, as
		ActionScript's and OpenFL's do, so `var socket:Socket = event.target`
		compiles: for a while it converted only to `Dynamic`, and that line,
		ActionScript's way to type an event's target, did not.
	**/
	public function testAnObjectConvertsToTheTypeItIsAssignedTo():Void {
		var target:Object = new Socket();
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf({
			var socket:Socket = target;
		}), "an Object did not become a Socket");
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf({
			var dispatcher:crossbyte.events.IEventDispatcher = target;
		}), "an Object did not become an interface");
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf({
			var count:Int = target;
		}), "an Object did not become an Int");
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf({
			var typed:TypedObject<{id:Int}> = target;
		}), "an Object did not become a TypedObject");
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf({
			var map = new haxe.ds.ObjectMap<{}, Int>();
			map.set(target, 1);
		}), "an Object was not taken as a key");
	}

	/**
		The idiom itself, in a listener: the target assigned to its type is
		the dispatcher, read through its type, on every target, and
		`cast(event.target, T)` checks.
	**/
	public function testAnEventsTargetIsAssignedToItsType():Void {
		var socket:Socket = new Socket();
		var seen:Socket = null;
		var current:Socket = null;
		var checked:Socket = null;
		var connected:Null<Bool> = null;
		socket.addEventListener("probe", (event:Event) -> {
			var target:Socket = event.target;
			seen = target;
			connected = target.connected;
			current = event.currentTarget;
			checked = cast(event.target, Socket);
		});
		socket.dispatchEvent(new Event("probe"));
		Assert.isTrue(seen == socket, "the target was not the socket");
		Assert.isTrue(current == socket, "the current target was not the socket");
		Assert.isTrue(checked == socket, "the checked cast was not the socket");
		Assert.isFalse(connected);
	}

	/**
		What the documentation says of an unchecked conversion: an object of
		another class is kept as it is on JavaScript, eval and Neko, is null
		natively, and throws on the jvm and HashLink, while `cast(object, T)`
		throws on every target; a "12" taken as an `Int` is 12 natively, the
		text "12" on JavaScript, eval and Neko, and throws on the jvm and
		HashLink.
	**/
	public function testAnUncheckedConversionIsEachTargetsOwn():Void {
		var instance:Object = new Sealed();
		var sealed:Sealed = instance;
		Assert.equals(1, sealed.field);

		var other:Other = null;
		var threw:Bool = false;
		try {
			other = instance;
		} catch (_:Dynamic) {
			threw = true;
		}
		#if cpp
		Assert.isFalse(threw);
		Assert.isNull(other);
		#elseif (jvm || hl)
		Assert.isTrue(threw, "an object of another class was assigned");
		#else
		Assert.isFalse(threw);
		Assert.isTrue((other : Dynamic) == (instance : Dynamic), "the object was not kept");
		#end
		Assert.raises(() -> cast(instance, Other));

		var text:Object = "12";
		var taken:Dynamic = null;
		threw = false;
		try {
			var number:Int = text;
			taken = number;
		} catch (_:Dynamic) {
			threw = true;
		}
		#if cpp
		Assert.equals(12, taken);
		#elseif (jvm || hl)
		Assert.isTrue(threw, "a String was taken as an Int");
		#else
		Assert.isTrue(Std.isOfType(taken, String), "the text was converted");
		#end
		Assert.raises(() -> cast(text, Int));
		Assert.equals(12, Std.parseInt(text.toString()));
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

	/**
		`TypedObject.entries()` gives each field as a `KeyValuePair`, as
		`Object.entries()` does, made as the walk reaches it. It built an
		anonymous structure for every field and an array of them first: a walk
		of four fields took 680 bytes natively and 248 on the jvm, where it
		takes 192 and 72. A pair still fits where `{key, value}` is asked for.
	**/
	public function testATypedObjectsEntriesArePairs():Void {
		var typed:TypedObject<{id:Int, name:String}> = haxe.Json.parse('{"id":4,"name":"t"}');
		var seen:Array<String> = [];
		for (entry in typed.entries()) {
			Assert.isTrue(Std.isOfType(entry, crossbyte.ds.ListedMap.KeyValuePair), "an entry was not a KeyValuePair: " + entry);
			seen.push(entry.key + "=" + Std.string(entry.value));
		}
		seen.sort(Reflect.compare);
		Assert.same(["id=4", "name=t"], seen);
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf({
			var walk:Iterator<{key:String, value:Dynamic}> = typed.entries();
		}), "the entries no longer fit {key, value}");
		var object:Object = haxe.Json.parse('{"id":4}');
		Assert.isNull(crossbyte.ds.TypeCheck.errorOf({
			var walk:Iterator<{key:String, value:Dynamic}> = object.entries();
		}), "an Object's entries no longer fit {key, value}");
		var nothing:TypedObject<{id:Int}> = null;
		Assert.isFalse(nothing.entries().hasNext(), "a null TypedObject had entries");
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

private class Other {
	public var other:Int = 2;

	public function new() {}
}
