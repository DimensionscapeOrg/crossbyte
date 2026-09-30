package crossbyte.db.mongodb.bson;

import haxe.Int64;

/**
	A BSON UTC datetime held exactly: milliseconds since the Unix epoch, as a
	64-bit integer.

	`Date` is the everyday form, and what documents decode to by default. It is
	exact on cpp, the jvm, the interpreter and JavaScript, but not everywhere:
	on hl and neko a `Date` holds whole seconds, and only between 1901 and
	2038, so a stored `2040-01-01T00:00:00.250Z` would come back as some other
	time. This keeps every value BSON can store. Ask for it with
	`MongoConfig.exactDates`, or `BsonReadOptions.exactDates` when decoding
	by hand; either kind encodes as a BSON date, so a TTL index acts on both.
**/
final class BsonDateTime {
	/** Milliseconds since 1970-01-01T00:00:00Z. **/
	public var millis(default, null):Int64;

	public function new(millis:Int64) {
		this.millis = millis;
	}

	/** The instant `date` names. **/
	public static function fromDate(date:Date):BsonDateTime {
		return new BsonDateTime(Int64.fromFloat(Math.ffloor(date.getTime())));
	}

	/** The instant `millis` milliseconds after the epoch. **/
	public static function fromTime(millis:Float):BsonDateTime {
		return new BsonDateTime(Int64.fromFloat(Math.ffloor(millis)));
	}

	/** Now, to the millisecond where the platform clock allows. **/
	public static function now():BsonDateTime {
		#if sys
		return fromTime(Sys.time() * 1000.0); // time of day: a datetime is an instant on the wall clock.
		#else
		// time of day: as above.
		return fromTime(Date.now().getTime());
		#end
	}

	/**
		Parses an ISO 8601 instant: `2026-09-30T12:34:56Z`, with optional
		fractional seconds and a `Z` or `+hh:mm` offset. Arithmetic on the
		calendar rather than on `Date`, so it is exact on every target.
	**/
	public static function parse(text:String):BsonDateTime {
		return new BsonDateTime(crossbyte.db.mongodb._internal.IsoDate.parse(text));
	}

	/** Milliseconds since the epoch, exact while under 2^53 in magnitude. **/
	public inline function getTime():Float {
		return crossbyte.db.mongodb._internal.Int64Float.toFloat(millis);
	}

	/** The instant as a `Date`, within what `Date` can hold on this target. **/
	public function toDate():Date {
		return Date.fromTime(getTime());
	}

	/** The instant as ISO 8601 in UTC, with milliseconds. **/
	public function toIsoString():String {
		return crossbyte.db.mongodb._internal.IsoDate.format(millis);
	}

	public function equals(other:BsonDateTime):Bool {
		return other != null && other.millis == millis;
	}

	public function toString():String {
		return toIsoString();
	}
}
