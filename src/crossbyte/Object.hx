package crossbyte;

import crossbyte.ds.ListedMap.KeyValuePair;

/**
 * A lightweight dynamic object bag for loosely structured CrossByte payloads.
 *
 * `Object` keeps the loose feel of `Dynamic`, but gives CrossByte a named surface
 * for field-oriented payloads. It supports dot access, bracket access, field
 * iteration, and simple field introspection.
 *
 * As in ActionScript, an `Object` holding a function can be called. Called
 * holding anything else it throws, except natively, where it does not.
 *
 * **What the field helpers see.** `exists`, `remove`, `keys`, `values`,
 * `entries`, `get` and `set` ask by reflection. Of an anonymous structure (a
 * literal, parsed JSON, `new Object()`) they answer alike on every target,
 * and a null `Object` answers as an empty one. Of a class instance each
 * target answers its own way: natively `exists` is false for a declared
 * field and `keys` lists properties too, on neko and Node `remove` deletes a
 * declared field, and on the jvm `get` of a property throws. Read a class's
 * fields through the class.
 *
 * **A field named like a method.** `exists`, `remove`, `keys`, `values`,
 * `entries`, `get`, `set` and `iterator` are these methods, so a payload's
 * field of one of those names is read with brackets: `payload["values"]`,
 * where `payload.values` is the method.
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
abstract Object(Dynamic) from Dynamic to Dynamic {
	public inline function new() {
		this = {};
	}

	public inline function exists(field:String):Bool {
		return this != null && Reflect.hasField(this, field);
	}

	public inline function remove(field:String):Bool {
		return this != null && Reflect.deleteField(this, field);
	}

	public inline function keys():Array<String> {
		var fields:Array<String> = this != null ? Reflect.fields(this) : null;
		return fields == null ? [] : fields;
	}

	/**
		The fields' values, in the order `keys()` gives the fields.
	**/
	public function values():Array<Dynamic> {
		var fields:Array<String> = keys();
		var out:Array<Dynamic> = [];
		for (field in fields) {
			out.push(Reflect.field(this, field));
		}
		return out;
	}

	/**
		The fields as `key`/`value` pairs, each made when the iteration reaches
		it as a `KeyValuePair`, which fits where a `{key, value}` structure is
		asked for.
	**/
	public function entries():Iterator<KeyValuePair<String, Dynamic>> {
		return new ObjectEntries(this, keys());
	}

	/**
		The field `field`, or null if there is none. On JavaScript
		`__proto__` and `constructor` are read as the object's own fields, as
		everywhere else, rather than as its prototype and its class, through
		which a path of names a peer chose could reach `Object.prototype`.
	**/
	@:arrayAccess public inline function get(field:String):Dynamic {
		#if js
		return crossbyte._internal.js.OwnField.get(this, field);
		#else
		return Reflect.field(this, field);
		#end
	}

	/**
		Sets the field `field`. On JavaScript `__proto__` is set as the
		object's own field, as everywhere else, rather than replacing its
		prototype.
	**/
	@:arrayAccess public inline function set(field:String, value:Dynamic):Dynamic {
		#if js
		crossbyte._internal.js.OwnField.set(this, field, value);
		#else
		Reflect.setField(this, field, value);
		#end
		return value;
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
		return new KeyValuePair(field, Reflect.field(__object, field));
	}
}
