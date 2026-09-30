package crossbyte.db.mongodb.bson;

import haxe.Int64;

/**
	A number to be stored as a BSON int64 whatever its value.

	A `haxe.Int64` is written as an int64, with one exception: on hxcpp an
	Int64 from -1 to 255 held in a `Dynamic` is boxed as the same object as
	the `Int`, so nothing can tell the two apart, and it is written as an
	int32. Queries compare the two as equal; where the stored type matters,
	wrap the value: `{version: new BsonInt64(Int64.ofInt(1))}`.
	`ExtendedJson.parse` makes one of `{"$numberLong": ...}` for that reason.
**/
final class BsonInt64 {
	public var value(default, null):Int64;

	public function new(value:Int64) {
		this.value = value;
	}

	public function toString():String {
		return Int64.toStr(value);
	}
}
