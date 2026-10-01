package crossbyte.url._internal;

import crossbyte.url.URLVariables;

/**
	`URLRequest.data` as a form, the one way every client encodes it.

	A `URLVariables` is encoded as itself, and any other object, an
	anonymous structure, an instance, as its fields: a scalar as
	`name=value`, an array's items each as `name[]=item`, and an object's
	fields as `name[field]=value`, to any depth. A `String` or `haxe.io.Bytes`
	is a body of its own, and nothing here.

	It was the native client's alone. The HTTP/2 backend sent a form as
	nothing at all, and the JavaScript clients encoded a `URLVariables` only:
	an object went out as `Std.string` made it, "{ user : bob }".
**/
@:noCompletion
class FormEncoding {
	/**
		`data` encoded as `application/x-www-form-urlencoded`, or null when it
		is not form data: null, a `String`, `haxe.io.Bytes`, a `ByteArray`
		included, or a number or `Bool`.
	**/
	public static function encode(data:Dynamic):Null<String> {
		if (data == null || Std.isOfType(data, String) || Std.isOfType(data, haxe.io.Bytes) || !Reflect.isObject(data)) {
			return null;
		}

		// A URLVariables is a StringMap at run time, and its fields are the
		// map's, not the caller's: a POST of one went out with an empty body.
		var variables:Null<String> = URLVariables.encodeData(data);
		if (variables != null) {
			return variables;
		}

		var parts:Array<String> = [];
		for (field in Reflect.fields(data)) {
			__add(parts, field, Reflect.field(data, field));
		}
		return parts.join("&");
	}

	private static function __add(parts:Array<String>, key:String, value:Dynamic):Void {
		if (value == null) {
			return;
		}

		switch (Type.typeof(value)) {
			case TBool:
				parts.push(__pair(key, (value : Bool) ? "true" : "false"));
			case TInt, TFloat:
				parts.push(__pair(key, Std.string(value)));
			case TClass(String):
				parts.push(__pair(key, (value : String)));
			case TClass(Array):
				var items:Array<Dynamic> = value;
				for (item in items) {
					__add(parts, key + "[]", item);
				}
			case TObject:
				for (field in Reflect.fields(value)) {
					__add(parts, key + "[" + field + "]", Reflect.field(value, field));
				}
			default:
				parts.push(__pair(key, Std.string(value)));
		}
	}

	private static inline function __pair(key:String, value:String):String {
		return StringTools.urlEncode(key) + "=" + StringTools.urlEncode(value);
	}
}
