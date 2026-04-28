package crossbyte;

/**
 * A lightweight dynamic object bag for loosely structured CrossByte payloads.
 *
 * `Object` keeps the loose feel of `Dynamic`, but gives CrossByte a named surface
 * for field-oriented payloads. It supports dot access, bracket access, field
 * iteration, and simple field introspection.
 */
@:transitive
@:callable
@:generic
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

	@:noCompletion @:dox(hide) public function iterator():Iterator<String> {
		return keys().iterator();
	}
}
