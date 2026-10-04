package crossbyte._internal.serial;

import crossbyte.errors.IOError;
import haxe.Json;

/**
	`haxe.Json.parse` for an object read from elsewhere, bounded as HXSF is
	by `BoundedUnserializer`: refused with an `IOError` when it nests more
	than `BoundedUnserializer.LIMIT` deep or holds more than
	`BoundedUnserializer.maxValues` values, both measured on the text before
	it is parsed.

	JSON has no run of nulls, so every value costs a byte at least and what
	it makes is linear in its length; the count makes the bound one number
	whichever encoding an object came in.
**/
class BoundedJson {
	public static function parse(text:String):Dynamic {
		if (!JsonNesting.within(text, BoundedUnserializer.LIMIT)) {
			throw new IOError('nested more than ${BoundedUnserializer.LIMIT} levels deep');
		}
		var most:Int = BoundedUnserializer.maxValues;
		if (most > 0 && JsonNesting.values(text, most) > most) {
			throw new IOError('more than $most values');
		}
		return Json.parse(text);
	}
}
