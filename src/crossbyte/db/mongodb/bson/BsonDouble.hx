package crossbyte.db.mongodb.bson;

/**
	A number to be stored as a BSON double whatever its value.

	A number whose value is a whole number in the 32-bit range is written as a
	BSON int32, and any other as a double. The value is what decides, not the
	Haxe type, because the type is not there to read: on cpp, the jvm, hl and
	JavaScript, `5.0` held in a `Dynamic` is indistinguishable from `5`. Queries
	compare numbers across the two, so this rarely matters; where it does
	(a schema that validates `bsonType: "double"`), wrap the value:
	`{price: new BsonDouble(5)}`.

	The same holds in reverse: a stored double of `5.0` reads back as a
	number equal to `5`, and is written back as an int32 unless wrapped.
**/
final class BsonDouble {
	public var value(default, null):Float;

	public function new(value:Float) {
		this.value = value;
	}

	public function toString():String {
		return Std.string(value);
	}
}
