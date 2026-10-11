package crossbyte._internal.js;

#if js
/**
	A field read and written by name on JavaScript as on every other target:
	`__proto__` and `constructor` as the object's own fields.

	JavaScript reads `o["__proto__"]` as the object's prototype and
	`o["constructor"]` as its class, which on a plain object is `Object`,
	whose `prototype` is every plain object's. So code that walks a path of
	names a peer chose (`a.b.c=1` in a query, a JSON patch) through
	`Object.get` and then sets the last one could reach `Object.prototype`
	and give every object in the process that field. Elsewhere those names
	are fields like any other, and a read of one an object does not have is
	null. Writing `__proto__` likewise replaced the object's prototype; it is
	defined as the object's own field instead, as `JSON.parse` makes it.

	Only these two names are checked, by length first, since a read through
	`Object.get` is otherwise one property read.
**/
@:noCompletion
class OwnField {
	public static inline function get(object:Dynamic, field:String):Dynamic {
		return (field.length == 9 || field.length == 11) && (field == "__proto__" || field == "constructor") ? __own(object, field) : Reflect.field(object,
			field);
	}

	public static inline function set(object:Dynamic, field:String, value:Dynamic):Void {
		if (field.length == 9 && field == "__proto__") {
			__define(object, value);
		} else {
			Reflect.setField(object, field, value);
		}
	}

	@:noCompletion private static function __own(object:Dynamic, field:String):Dynamic {
		return object != null && js.lib.Object.prototype.hasOwnProperty.call(object, field) ? js.Syntax.code("{0}[{1}]", object, field) : null;
	}

	@:noCompletion private static function __define(object:Dynamic, value:Dynamic):Void {
		var kind:String = js.Syntax.typeof(object);
		if (object == null || (kind != "object" && kind != "function")) {
			Reflect.setField(object, "__proto__", value);
			return;
		}
		js.lib.Object.defineProperty(object, "__proto__", {
			value: value,
			writable: true,
			enumerable: true,
			configurable: true
		});
	}
}
#end
