package crossbyte.db.mongodb._internal;

import crossbyte.errors.ArgumentError;
import haxe.Int64;

/**
	ISO 8601 instants to and from milliseconds since the epoch, by calendar
	arithmetic alone.

	Not through `Date`: on hl and neko a `Date` holds whole seconds between
	1901 and 2038, and `Date.toString` on a negative time ends a native Windows
	process. Days are counted with the proleptic Gregorian calendar (Howard
	Hinnant's days-from-civil), which is exact for any year a millisecond
	count below 2^53 can reach.
**/
class IsoDate {
	@:noCompletion private static inline var MS_PER_DAY:Float = 86400000.0;

	/**
		Parses `YYYY-MM-DDTHH:MM:SS[.fff][Z|+hh:mm|-hh:mm]`; the seconds and
		the zone may be left out (a missing zone reads as UTC), and a space may
		stand for the `T`.

		@throws ArgumentError When `text` is not such an instant.
	**/
	public static function parse(text:String):Int64 {
		if (text == null) {
			throw new ArgumentError("Not an ISO 8601 date: null.");
		}

		var cursor:IsoCursor = new IsoCursor();
		var year:Int = __number(text, cursor, 4, 4);
		__expect(text, cursor, "-".code);
		var month:Int = __number(text, cursor, 2, 2);
		__expect(text, cursor, "-".code);
		var day:Int = __number(text, cursor, 2, 2);

		var hours:Int = 0;
		var minutes:Int = 0;
		var seconds:Int = 0;
		var millis:Int = 0;
		var offsetMinutes:Int = 0;

		if (cursor.pos < text.length) {
			var separator:Int = StringTools.fastCodeAt(text, cursor.pos);

			if (separator != "T".code && separator != "t".code && separator != " ".code) {
				__fail(text);
			}

			cursor.pos++;
			hours = __number(text, cursor, 2, 2);
			__expect(text, cursor, ":".code);
			minutes = __number(text, cursor, 2, 2);

			if (cursor.pos < text.length && StringTools.fastCodeAt(text, cursor.pos) == ":".code) {
				cursor.pos++;
				seconds = __number(text, cursor, 2, 2);

				if (cursor.pos < text.length && StringTools.fastCodeAt(text, cursor.pos) == ".".code) {
					cursor.pos++;
					var start:Int = cursor.pos;
					var fraction:Int = 0;
					var places:Int = 0;

					while (cursor.pos < text.length) {
						var c:Int = StringTools.fastCodeAt(text, cursor.pos);

						if (c < "0".code || c > "9".code) {
							break;
						}

						// Past milliseconds is finer than BSON keeps; dropped.
						if (places < 3) {
							fraction = fraction * 10 + (c - "0".code);
							places++;
						}

						cursor.pos++;
					}

					if (cursor.pos == start) {
						__fail(text);
					}

					while (places < 3) {
						fraction *= 10;
						places++;
					}

					millis = fraction;
				}
			}

			if (cursor.pos < text.length) {
				var zone:Int = StringTools.fastCodeAt(text, cursor.pos);

				if (zone == "Z".code || zone == "z".code) {
					cursor.pos++;
				} else if (zone == "+".code || zone == "-".code) {
					cursor.pos++;
					var zoneHours:Int = __number(text, cursor, 2, 2);
					var zoneMinutes:Int = 0;

					if (cursor.pos < text.length && StringTools.fastCodeAt(text, cursor.pos) == ":".code) {
						cursor.pos++;
					}

					if (cursor.pos < text.length) {
						zoneMinutes = __number(text, cursor, 2, 2);
					}

					offsetMinutes = (zoneHours * 60 + zoneMinutes) * (zone == "-".code ? -1 : 1);
				} else {
					__fail(text);
				}
			}
		}

		if (cursor.pos != text.length || month < 1 || month > 12 || day < 1 || day > __daysInMonth(year, month) || hours > 23 || minutes > 59
			|| seconds > 60) {
			__fail(text);
		}

		var total:Float = daysFromCivil(year, month, day) * MS_PER_DAY + ((hours * 60 + minutes - offsetMinutes) * 60 + seconds) * 1000.0 + millis;
		return Int64.fromFloat(total);
	}

	/**
		`YYYY-MM-DDTHH:MM:SS.fffZ` for an instant in years 0 to 9999, which is
		all that form can write.

		@throws ArgumentError For an instant outside those years.
	**/
	public static function format(millis:Int64):String {
		var total:Float = crossbyte.db.mongodb._internal.Int64Float.toFloat(millis);
		var days:Float = Math.ffloor(total / MS_PER_DAY);
		var inDay:Int = Std.int(total - days * MS_PER_DAY);
		var civil:Array<Int> = civilFromDays(Std.int(days));

		if (civil[0] < 0 || civil[0] > 9999) {
			throw new ArgumentError('Year ${civil[0]} cannot be written as an ISO 8601 date.');
		}

		var out:StringBuf = new StringBuf();
		out.add(__pad(civil[0], 4));
		out.add("-");
		out.add(__pad(civil[1], 2));
		out.add("-");
		out.add(__pad(civil[2], 2));
		out.add("T");
		out.add(__pad(Std.int(inDay / 3600000), 2));
		out.add(":");
		out.add(__pad(Std.int(inDay / 60000) % 60, 2));
		out.add(":");
		out.add(__pad(Std.int(inDay / 1000) % 60, 2));
		out.add(".");
		out.add(__pad(inDay % 1000, 3));
		out.add("Z");
		return out.toString();
	}

	/** Whether `format` can write the instant `millis`. **/
	public static function formattable(millis:Int64):Bool {
		var total:Float = crossbyte.db.mongodb._internal.Int64Float.toFloat(millis);
		// 0000-01-01 and 10000-01-01.
		return total >= -62167219200000.0 && total < 253402300800000.0;
	}

	/** Days from 1970-01-01 to the given date in the proleptic Gregorian calendar. **/
	public static function daysFromCivil(year:Int, month:Int, day:Int):Int {
		var y:Int = month <= 2 ? year - 1 : year;
		var era:Int = Std.int((y >= 0 ? y : y - 399) / 400);
		var yearOfEra:Int = y - era * 400;
		var dayOfYear:Int = Std.int((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1;
		var dayOfEra:Int = yearOfEra * 365 + Std.int(yearOfEra / 4) - Std.int(yearOfEra / 100) + dayOfYear;
		return era * 146097 + dayOfEra - 719468;
	}

	/** Year, month and day for a count of days from 1970-01-01. **/
	public static function civilFromDays(days:Int):Array<Int> {
		var z:Int = days + 719468;
		var era:Int = Std.int((z >= 0 ? z : z - 146096) / 146097);
		var dayOfEra:Int = z - era * 146097;
		var yearOfEra:Int = Std.int((dayOfEra - Std.int(dayOfEra / 1460) + Std.int(dayOfEra / 36524) - Std.int(dayOfEra / 146096)) / 365);
		var dayOfYear:Int = dayOfEra - (365 * yearOfEra + Std.int(yearOfEra / 4) - Std.int(yearOfEra / 100));
		var mp:Int = Std.int((5 * dayOfYear + 2) / 153);
		var day:Int = dayOfYear - Std.int((153 * mp + 2) / 5) + 1;
		var month:Int = mp < 10 ? mp + 3 : mp - 9;
		var year:Int = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);
		return [year, month, day];
	}

	@:noCompletion private static function __daysInMonth(year:Int, month:Int):Int {
		return switch (month) {
			case 2: (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28;
			case 4 | 6 | 9 | 11: 30;
			default: 31;
		}
	}

	@:noCompletion private static function __number(text:String, cursor:IsoCursor, min:Int, max:Int):Int {
		var value:Int = 0;
		var count:Int = 0;

		while (cursor.pos < text.length && count < max) {
			var c:Int = StringTools.fastCodeAt(text, cursor.pos);

			if (c < "0".code || c > "9".code) {
				break;
			}

			value = value * 10 + (c - "0".code);
			count++;
			cursor.pos++;
		}

		if (count < min) {
			__fail(text);
		}

		return value;
	}

	@:noCompletion private static function __expect(text:String, cursor:IsoCursor, code:Int):Void {
		if (cursor.pos >= text.length || StringTools.fastCodeAt(text, cursor.pos) != code) {
			__fail(text);
		}

		cursor.pos++;
	}

	@:noCompletion private static function __pad(value:Int, width:Int):String {
		var text:String = Std.string(value);

		while (text.length < width) {
			text = "0" + text;
		}

		return text;
	}

	@:noCompletion private static function __fail(text:String):Void {
		throw new ArgumentError('Not an ISO 8601 date: "$text".');
	}
}

/**
	Where a parse has got to in its text. A class, so its position is a
	field rather than looked up by name in an anonymous object, about
	thirty times a date.
**/
private class IsoCursor {
	public var pos:Int = 0;

	public function new() {}
}
