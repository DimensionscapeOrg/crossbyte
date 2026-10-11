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
	public function new(create:Void->T) {
		this = create();
	}

	public static inline function of<T>(value:T):TypedObject<T> {
		return cast value;
	}

	public inline function exists(field:String):Bool {
		return this != null && Reflect.hasField(this, field);
	}

	public inline function keys():Array<String> {
		var fields:Array<String> = this != null ? Reflect.fields(this) : null;
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

	/** The field `field`, or null; on JavaScript as `Object.get` reads it. **/
	@:arrayAccess public inline function get(field:String):Dynamic {
		#if js
		return crossbyte._internal.js.OwnField.get(this, field);
		#else
		return Reflect.field(this, field);
		#end
	}

	/** Sets the field `field`; on JavaScript as `Object.set` does. **/
	@:arrayAccess public inline function set(field:String, value:Dynamic):Dynamic {
		#if js
		crossbyte._internal.js.OwnField.set(this, field, value);
		#else
		Reflect.setField(this, field, value);
		#end
		return value;
	}

	@:noCompletion @:dox(hide) public inline function iterator():Iterator<String> {
		return keys().iterator();
	}
}
