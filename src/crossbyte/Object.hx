package crossbyte;

import crossbyte.ds.ListedMap.KeyValuePair;

/**
 * ActionScript's `Object`, for loosely structured values: parsed JSON, a
 * `SharedObject`'s data, an event's target.
 *
 * Its fields are read and written with a dot or with brackets. A field read
 * is `Dynamic`, so it converts, adds and compares as the value it holds
 * does, and `payload.hits++` works. A number in brackets reads an `Array`'s
 * element, or the field the number names. ActionScript's `hasOwnProperty`,
 * `propertyIsEnumerable`, `isPrototypeOf`, `valueOf`, `toString` and
 * `toLocaleString` are here, with `exists`, `remove`, `keys`, `values` and
 * `entries`, and a loop walks the fields: `for (name in object)` or
 * `for (name => value in object)`. As in ActionScript, an `Object` holding a
 * function can be called.
 *
 * ```haxe
 * var payload:Object = haxe.Json.parse('{"name":"ada","hits":3,"tags":["a","b"]}');
 * payload.hits++;
 * var hits:Int = payload.hits;
 * var tags:Object = payload.tags;
 * var first:String = tags[0];
 * if (!payload.hasOwnProperty("score")) {
 * 	payload["score"] = hits * 10;
 * }
 * for (name => value in payload) {
 * 	trace(name + " = " + value);
 * }
 * var text:String = payload.toString();
 * ```
 *
 * **The same on every target.** Of a structure (a literal, parsed JSON,
 * `new Object()`) every method answers alike everywhere, and a null
 * `Object` answers as an empty one. An `Array`, a `String`, a number, a
 * `Bool` or a function has no fields. Of a class instance each target
 * answers its own way (natively `exists` is false for a declared field and
 * `keys` lists properties too; on Neko and Node `remove` deletes a declared
 * field; on the jvm `get` of a property throws), so read a class's fields
 * through the class.
 *
 * **Conversions.** An `Object` takes any value, and on its own becomes only
 * a `Dynamic`: `var count:Int = object`, `var socket:Socket = object`,
 * `object + 1` and `if (object)` do not compile, where each target made its
 * own of them (a "12" as an `Int` was 12 natively, "12" on JavaScript and a
 * thrown cast on the jvm). Say what it is: `cast(object, Socket)` checks
 * that, and throws on every target if it is not; `cast object` does not
 * check; `toString()` gives it as text.
 *
 * **What still differs.** These are each target's own, and checking for
 * them would cost every read:
 * - A field of a null `Object` read or written with a dot is the target's
 *   null access: natively it ends the process. Brackets answer null.
 * - Called holding something that is not a function, an `Object` throws,
 *   except natively, where it answers 0.
 * - On JavaScript a null name in brackets throws a `TypeError`; a name of a
 *   member every object has there (`toString`, `valueOf`) reads that member
 *   where the object has no field of its own by that name; and an `Array`'s
 *   elements are also its fields, named by their indices.
 *
 * **A field named like a method.** `exists`, `remove`, `keys`, `values`,
 * `entries`, `get`, `set`, `iterator`, `keyValueIterator` and ActionScript's
 * methods above are methods, so a field of one of those names is read with
 * brackets: `payload["values"]`, where `payload.values` is the method.
 *
 * **What it costs.** Every field of an `Object` is looked up by its name when
 * it is read. Built from a literal such as `{name: "a", hits: 3}`, the fields
 * have fixed places, which natively makes those lookups quick; built empty
 * and filled with `obj["name"] = ...`, every field goes in a hash map. Build
 * from a literal when the fields are known, and for repeated typed access cast
 * to a class or a typed view (a typedef or `TypedObject<T>`) once, rather than
 * reading through `Object` each time.
 */
@:transitive
@:callable
@:forward
abstract Object(Dynamic) from Dynamic {
	public inline function new() {
		this = {};
	}

	/** Whether the object has a field `field`; false for a null name. **/
	public inline function exists(field:String):Bool {
		return this != null && field != null && Reflect.hasField(this, field);
	}

	/** Removes the field `field`, and says whether there was one. **/
	public inline function remove(field:String):Bool {
		return this != null && field != null && Reflect.deleteField(this, field);
	}

	/**
		Whether the object has a field `name` of its own: `exists`, by the
		name ActionScript gives it. Called through the object's own fields,
		as a field read with a dot is, it answered only on JavaScript, which
		has it on every object's prototype, and threw everywhere else.
	**/
	public inline function hasOwnProperty(name:String):Bool {
		return exists(name);
	}

	/**
		Whether a loop over the object reaches its field `name`, as
		ActionScript asks of a dynamic property: true for a field of a
		structure (a literal, parsed JSON, `new Object()`), false for a
		class instance's, which are declared as a sealed class's are, and
		for a name it does not have.
	**/
	public inline function propertyIsEnumerable(name:String):Bool {
		return exists(name) && Type.getClass(this) == null;
	}

	/**
		Whether this object is in `value`'s prototype chain, as ActionScript
		asks: never, since a Haxe value has no prototype chain to be in. To
		ask whether a value is an instance of a class, use
		`Std.isOfType(value, SomeClass)`.
	**/
	public inline function isPrototypeOf(value:Dynamic):Bool {
		return false;
	}

	/** The object itself, as ActionScript's `valueOf` gives an `Object`. **/
	public inline function valueOf():Object {
		return this;
	}

	/**
		The object as text, as `Std.string` and `trace` give it: a string as
		itself, a number or a `Bool` as it is written, and `"null"` for null.
		A structure is printed in each target's own form of
		`{name: value}`, so compare fields rather than this text.
	**/
	public inline function toString():String {
		return Std.string(this);
	}

	/** `toString()`, by the other name ActionScript gives it. **/
	public inline function toLocaleString():String {
		return Std.string(this);
	}

	/**
		The object's field names: a structure's or a class instance's. An
		`Array`, a `String`, a number, a `Bool` or a function has none, on
		every target, where each listed its own internals (`length`, `__a`,
		`value`, a string's characters); read an `Array`'s elements with
		`[i]` and `length`.
	**/
	public inline function keys():Array<String> {
		return __fieldsOf(this);
	}

	/** The fields' values, in the order `keys()` gives the fields. **/
	public function values():Array<Dynamic> {
		var fields:Array<String> = __fieldsOf(this);
		var out:Array<Dynamic> = [];
		for (field in fields) {
			out.push(__listed(this, field));
		}
		return out;
	}

	/**
		The fields as `key`/`value` pairs, each made when the iteration reaches
		it as a `KeyValuePair`, which fits where a `{key, value}` structure is
		asked for.
	**/
	public function entries():Iterator<KeyValuePair<String, Dynamic>> {
		return new ObjectEntries(this, __fieldsOf(this));
	}

	// A structure's or a class instance's field names, and none for anything
	// else. Each target's Reflect.fields lists something of its own for an
	// Array, a String or a number (natively nothing; on the jvm length and
	// __a, value and hash; on Node an Array's indices and a String's
	// characters), so those are told apart, but a structure is listed first,
	// at what Reflect.fields alone costs.
	@:noCompletion private static inline function __fieldsOf(object:Dynamic):Array<String> {
		#if cpp
		// Natively an Array, a String, a number and a function list no fields.
		var fields:Array<String> = object == null ? null : Reflect.fields(object);
		return fields != null ? fields : [];
		#elseif (jvm && !macro)
		return jvm.Jvm.instanceof(object, jvm.DynamicObject) ? (cast object : jvm.DynamicObject)._hx_getFields() : __otherFields(object);
		#elseif js
		return object != null && js.Syntax.typeof(object) == "object" && !js.Syntax.code("Array.isArray({0})", object) ? __ownKeys(object) : [];
		#else
		return __otherFields(object);
		#end
	}

	// The value of a field `keys()` listed, so one the object has: on
	// JavaScript read straight, without the catch Reflect.field reads through.
	@:noCompletion private static inline function __listed(object:Dynamic, field:String):Dynamic {
		#if js
		return js.Syntax.code("{0}[{1}]", object, field);
		#else
		return Reflect.field(object, field);
		#end
	}

	#if js
	// Object.keys, the builtin, without the two names Haxe keeps on an object
	// for itself, as Reflect.fields leaves them out with a for-in loop.
	@:noCompletion private static function __ownKeys(object:Dynamic):Array<String> {
		var keys:Array<String> = js.lib.Object.keys(object);
		for (key in keys) {
			if (key == "__id__" || key == "hx__closures__") {
				return [for (kept in keys) if (kept != "__id__" && kept != "hx__closures__") kept];
			}
		}
		return keys;
	}
	#end

	#if !(cpp || js)
	@:noCompletion private static function __otherFields(object:Dynamic):Array<String> {
		if (object == null || Std.isOfType(object, Array) || Std.isOfType(object, String) || !Reflect.isObject(object)) {
			return [];
		}
		var fields:Array<String> = Reflect.fields(object);
		return fields == null ? [] : fields;
	}
	#end

	/**
		What `for (name => value in object)` walks: the fields and their
		values, as `entries()` gives them.
	**/
	public inline function keyValueIterator():Iterator<KeyValuePair<String, Dynamic>> {
		return entries();
	}

	/**
		The field `field`, or null if there is none or the object is null. A
		null name reads null too, but on JavaScript, where it throws a
		`TypeError`. On JavaScript `__proto__` and `constructor` are read as
		the object's own fields, as everywhere else, rather than as its
		prototype and its class, through which a path of names a peer chose
		could reach `Object.prototype`.
	**/
	@:arrayAccess public inline function get(field:String):Dynamic {
		#if js
		return crossbyte._internal.js.OwnField.get(this, field);
		#else
		return field == null ? null : Reflect.field(this, field);
		#end
	}

	/**
		Sets the field `field`. On JavaScript `__proto__` is set as the
		object's own field, as everywhere else, rather than replacing its
		prototype.
		@throws ArgumentError For a null name.
	**/
	@:arrayAccess public inline function set(field:String, value:Dynamic):Dynamic {
		if (field == null) {
			__refuseNullName();
		}
		#if js
		crossbyte._internal.js.OwnField.set(this, field, value);
		#else
		Reflect.setField(this, field, value);
		#end
		return value;
	}

	@:noCompletion private static function __refuseNullName():Void {
		throw new crossbyte.errors.ArgumentError("A field is set by its name, and null was given.");
	}

	/**
		`object[index]`: of an `Array`, its element, or null outside it; of
		anything else, the field named by the number, as ActionScript reads
		`object[0]`.
	**/
	@:arrayAccess @:noCompletion @:dox(hide) public inline function __getIndex(index:Int):Dynamic {
		return __elementAt(this, index);
	}

	/**
		`object[index] = value`: of an `Array`, its element, the array
		growing to it as an `Array` does (a negative index is a
		`RangeError`); of anything else, the field named by the number.
	**/
	@:arrayAccess @:noCompletion @:dox(hide) public inline function __setIndex(index:Int, value:Dynamic):Dynamic {
		__setElementAt(this, index, value);
		return value;
	}

	@:noCompletion private static function __elementAt(object:Dynamic, index:Int):Dynamic {
		if (Std.isOfType(object, Array)) {
			var elements:Array<Dynamic> = object;
			return index >= 0 && index < elements.length ? elements[index] : null;
		}
		return object == null ? null : (object : Object).get(Std.string(index));
	}

	@:noCompletion private static function __setElementAt(object:Dynamic, index:Int, value:Dynamic):Void {
		if (Std.isOfType(object, Array)) {
			if (index < 0) {
				throw new crossbyte.errors.RangeError("An Array has no element " + index + ".");
			}
			var elements:Array<Dynamic> = object;
			elements[index] = value;
			return;
		}
		(object : Object).set(Std.string(index), value);
	}

	@:noCompletion @:dox(hide) public function iterator():Iterator<String> {
		return keys().iterator();
	}
}

/** `Object.entries()`'s iterator: each field's pair made as it is reached. **/
@:noCompletion
private final class ObjectEntries {
	private var __object:Dynamic;
	private var __fields:Array<String>;
	private var __next:Int = 0;

	public function new(object:Dynamic, fields:Array<String>) {
		__object = object;
		__fields = fields;
	}

	public inline function hasNext():Bool {
		return __next < __fields.length;
	}

	public inline function next():KeyValuePair<String, Dynamic> {
		var field:String = __fields[__next++];
		return new KeyValuePair(field, @:privateAccess Object.__listed(__object, field));
	}
}
