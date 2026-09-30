package crossbyte.db.mongodb.bson;

/**
	A BSON document that keeps its fields in the order they were added.

	Anonymous objects do not keep their order on most targets: a literal's
	fields come back sorted on cpp, the jvm, hl, neko and the interpreter,
	and fields set with `Reflect.setField` come back hashed on cpp and neko.
	Where MongoDB reads the order, that matters. A sort on
	`{lastName: 1, firstName: 1}` sorts by whichever field the target happened
	to put first, and so does an index made from those keys. Use this there:

	```haxe
	import crossbyte.db.mongodb.MongoConnection;

	// Given connection:MongoConnection.
	var byName = new BsonDocument().add("lastName", 1).add("firstName", 1);
	connection.find("people", {city: "Oslo"}, {sort: byName});
	```

	Anywhere order does not matter -- a filter, a projection, a document to
	insert -- an anonymous object is fine, and is what the driver returns.
**/
class BsonDocument {
	/** How many fields the document has. **/
	public var length(get, never):Int;

	@:noCompletion private var __keys:Array<String>;
	@:noCompletion private var __values:Array<Dynamic>;

	public function new() {
		__keys = [];
		__values = crossbyte.db.mongodb._internal.ValueArray.create();
	}

	/**
		A document of `pairs`, read as name, value, name, value:
		`BsonDocument.of(["lastName", 1, "firstName", 1])`.
	**/
	public static function of(pairs:Array<Dynamic>):BsonDocument {
		if (pairs.length % 2 != 0) {
			throw new crossbyte.errors.ArgumentError("BsonDocument.of takes a name and a value for each field, so an even number of items.");
		}

		var out:BsonDocument = new BsonDocument();
		var i:Int = 0;

		while (i < pairs.length) {
			out.set(Std.string(pairs[i]), pairs[i + 1]);
			i += 2;
		}

		return out;
	}

	/**
		A document with the fields of an anonymous object, in whatever order
		the target reports them -- which is the order this type exists to
		control, so use it for documents where order does not matter.
	**/
	public static function fromObject(object:Dynamic):BsonDocument {
		var out:BsonDocument = new BsonDocument();

		if (object == null) {
			return out;
		}

		for (name in Reflect.fields(object)) {
			out.add(name, Reflect.field(object, name));
		}

		return out;
	}

	/**
		Appends a field without looking for one of the same name, and returns
		this document so calls chain. BSON allows repeated names, but MongoDB
		reads only one of them; use `set` unless the name is known to be new.
	**/
	public function add(name:String, value:Dynamic):BsonDocument {
		__keys.push(name);
		__values.push(value);
		return this;
	}

	/** Replaces the field named `name`, or appends it; returns this document. **/
	public function set(name:String, value:Dynamic):BsonDocument {
		var index:Int = __keys.indexOf(name);

		if (index >= 0) {
			__values[index] = value;
		} else {
			__keys.push(name);
			__values.push(value);
		}

		return this;
	}

	/** The value of the field named `name`, or `null` when there is none. **/
	public function get(name:String):Dynamic {
		var index:Int = __keys.indexOf(name);
		return index >= 0 ? __values[index] : null;
	}

	public function exists(name:String):Bool {
		return __keys.indexOf(name) >= 0;
	}

	/** Removes the field named `name`; answers whether there was one. **/
	public function remove(name:String):Bool {
		var index:Int = __keys.indexOf(name);

		if (index < 0) {
			return false;
		}

		__keys.splice(index, 1);
		__values.splice(index, 1);
		return true;
	}

	/** The name of the field at `index`, in order. **/
	public inline function keyAt(index:Int):String {
		return __keys[index];
	}

	/** The value of the field at `index`, in order. **/
	public inline function valueAt(index:Int):Dynamic {
		return __values[index];
	}

	/** The field names, in order, as a new array. **/
	public function keys():Array<String> {
		return __keys.copy();
	}

	/**
		The fields as an anonymous object. Nested `BsonDocument`s, including
		those inside arrays, become anonymous objects too.
	**/
	public function toObject():Dynamic {
		var out:Dynamic = {};

		for (i in 0...__keys.length) {
			Reflect.setField(out, __keys[i], __plain(__values[i]));
		}

		return out;
	}

	public function toString():String {
		return ExtendedJson.stringify(this);
	}

	@:noCompletion private static function __plain(value:Dynamic):Dynamic {
		if (Std.isOfType(value, BsonDocument)) {
			return (value : BsonDocument).toObject();
		}

		if (Std.isOfType(value, Array)) {
			var items:Array<Dynamic> = value;
			var out:Array<Dynamic> = crossbyte.db.mongodb._internal.ValueArray.create();

			for (item in items) {
				out.push(__plain(item));
			}

			return out;
		}

		return value;
	}

	private inline function get_length():Int {
		return __keys.length;
	}
}
