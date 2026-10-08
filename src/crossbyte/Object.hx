package crossbyte;

import crossbyte.ds.ListedMap.KeyValuePair;

/**
 * A lightweight dynamic object bag for loosely structured CrossByte payloads.
 *
 * `Object` keeps the loose feel of `Dynamic`, but gives CrossByte a named surface
 * for field-oriented payloads. It supports dot access, bracket access, field
 * iteration, and simple field introspection.
 *
 * As in ActionScript, an `Object` holding a function can be called.
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
		return Reflect.hasField(this, field);
	}

	public inline function remove(field:String):Bool {
		return Reflect.deleteField(this, field);
	}

	public inline function keys():Array<String> {
		var fields = Reflect.fields(this);
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

	@:arrayAccess public inline function get(field:String):Dynamic {
		return Reflect.field(this, field);
	}

	@:arrayAccess public inline function set(field:String, value:Dynamic):Dynamic {
		Reflect.setField(this, field, value);
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
