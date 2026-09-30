package crossbyte.db.mongodb.bson;

/**
	A BSON timestamp: MongoDB's internal replication clock, a count of seconds
	and an increment within that second. Not a date -- use `Date` or
	`BsonDateTime` for those.

	Both halves are unsigned 32-bit values carried in an `Int`, so a value
	past 2^31 - 1 reads negative here; `seconds` gives the time half as an
	unsigned number.
**/
final class BsonTimestamp {
	/** The seconds half, unsigned, carried in an `Int`. **/
	public var time(default, null):Int;

	/** The ordinal within the second, unsigned, carried in an `Int`. **/
	public var increment(default, null):Int;

	/** `time` read as unsigned. **/
	public var seconds(get, never):Float;

	public function new(time:Int, increment:Int) {
		this.time = time;
		this.increment = increment;
	}

	public function equals(other:BsonTimestamp):Bool {
		return other != null && other.time == time && other.increment == increment;
	}

	public function toString():String {
		return 'Timestamp(${__unsigned(time)}, ${__unsigned(increment)})';
	}

	private function get_seconds():Float {
		return __unsigned(time);
	}

	@:noCompletion private static inline function __unsigned(value:Int):Float {
		return value < 0 ? value + 4294967296.0 : value;
	}
}
