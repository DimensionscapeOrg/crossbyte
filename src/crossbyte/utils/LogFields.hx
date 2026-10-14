package crossbyte.utils;

/**
	A log record's structured fields: a `Map<String, String>`, or an array
	of `LogField`s, which `Logger` writes in the order given.

	```haxe
	Logger.info("realm started", [{key: "realmId", value: "eu-1"}, {key: "port", value: 7000}]);
	Logger.info("request served", ["status" => "200"]);
	```

	A `Map` keeps no order (a `StringMap` gives its keys in whatever order its
	hashing leaves them, which differs by target), so where the order of the
	fields matters to whoever reads the log, pass the array. Either converts
	to this type by itself and is kept as it was given, not copied: passing
	fields costs nothing more than building them, and passing none costs
	nothing at all.

	The array may repeat a key; each is written, in turn. `get` and `exists`
	read the first.
**/
abstract LogFields(Any) {
	/** Fields given as a map, written in the map's order. **/
	@:from public static inline function ofMap(map:Map<String, String>):LogFields {
		return cast map;
	}

	/** Fields given as an array, written in the array's order. **/
	@:from public static inline function ofPairs(pairs:Array<LogField>):LogFields {
		return cast pairs;
	}

	/** The value of the field named `key`, as text, or null. **/
	@:arrayAccess public function get(key:String):Null<String> {
		var pairs:Null<Array<LogField>> = __pairs();
		if (pairs == null) {
			return __map().get(key);
		}
		for (field in pairs) {
			if (field != null && field.key == key) {
				return __text(field.value);
			}
		}
		return null;
	}

	/** Whether a field is named `key`. **/
	public function exists(key:String):Bool {
		var pairs:Null<Array<LogField>> = __pairs();
		if (pairs == null) {
			return __map().exists(key);
		}
		for (field in pairs) {
			if (field != null && field.key == key) {
				return true;
			}
		}
		return false;
	}

	/** The fields' names, in the order they are written. **/
	public function keys():Iterator<String> {
		var pairs:Null<Array<LogField>> = __pairs();
		if (pairs == null) {
			return __map().keys();
		}
		return [for (field in pairs) if (field != null) field.key].iterator();
	}

	/** The fields' values as text, in the order they are written. **/
	public function iterator():Iterator<Null<String>> {
		var pairs:Null<Array<LogField>> = __pairs();
		if (pairs == null) {
			return __map().iterator();
		}
		return [for (field in pairs) if (field != null) __text(field.value)].iterator();
	}

	/** Each name and value as text, in the order they are written. **/
	public function keyValueIterator():KeyValueIterator<String, Null<String>> {
		var pairs:Null<Array<LogField>> = __pairs();
		if (pairs == null) {
			return __map().keyValueIterator();
		}
		return [for (field in pairs) if (field != null) {key: field.key, value: __text(field.value)}].iterator();
	}

	/**
		The fields as a map: the map they were given as, or a new one made
		from the array, where a repeated key keeps its last value.
	**/
	@:to public function toMap():Map<String, String> {
		var pairs:Null<Array<LogField>> = __pairs();
		if (pairs == null) {
			return __map();
		}
		var map:Map<String, String> = new Map();
		for (field in pairs) {
			if (field != null) {
				map.set(field.key, __text(field.value));
			}
		}
		return map;
	}

	/** The array given, or null when a map was. **/
	@:noCompletion public inline function __pairs():Null<Array<LogField>> {
		return Std.isOfType(this, Array) ? cast this : null;
	}

	/** The map given; only when `__pairs()` is null. **/
	@:noCompletion public inline function __map():Map<String, String> {
		return cast this;
	}

	/** A field's value as it is written: text, or null. **/
	@:noCompletion public static inline function __text(value:Dynamic):Null<String> {
		return value == null ? null : (Std.isOfType(value, String) ? (value : String) : Std.string(value));
	}
}
