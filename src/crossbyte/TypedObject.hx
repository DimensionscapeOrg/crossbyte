package crossbyte;

/**
 * A typed dynamic record wrapper for loosely structured payloads that still have
 * a known structural shape.
 *
 * `TypedObject<T>` keeps direct typed field access through `T`, while also
 * supporting dynamic-style bracket access and field iteration when a computed
 * field name is more convenient.
 */
@:forward
@:generic
abstract TypedObject<T>(T) from T to T from Dynamic to Dynamic {
	public function new<T>(create:Void->T) {
		this = create();
	}

	public static inline function of<T>(value:T):TypedObject<T> {
		return cast value;
	}

	public inline function exists(field:String):Bool {
		return Reflect.hasField(this, field);
	}

	public inline function keys():Array<String> {
		var fields = Reflect.fields(this);
		return fields == null ? [] : fields;
	}

	public inline function values():Array<Dynamic> {
		return keys().map(field -> Reflect.field(this, field));
	}

	public inline function entries():Iterator<{key:String, value:Dynamic}> {
		return keys().map(field -> {
			key: field,
			value: Reflect.field(this, field)
		}).iterator();
	}

	@:arrayAccess public inline function get(field:String):Dynamic {
		return Reflect.field(this, field);
	}

	@:arrayAccess public inline function set(field:String, value:Dynamic):Dynamic {
		Reflect.setField(this, field, value);
		return value;
	}

	@:noCompletion @:dox(hide) public inline function iterator():Iterator<String> {
		return keys().iterator();
	}
}
