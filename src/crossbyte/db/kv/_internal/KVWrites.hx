package crossbyte.db.kv._internal;

import crossbyte.db.kv.KVError;
import crossbyte.db.kv.KVErrorKind;
import crossbyte.db.kv.KVOptions;
import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;

/**
	What every store refuses alike.
**/
@:noCompletion
class KVWrites {
	/** Refuses a key that is not one, and a value that is null or past `maxValueBytes`. **/
	public static function checkWrite(key:String, value:Bytes, options:KVOptions):Void {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);

		if (value == null) {
			throw new ArgumentError('The value for $key is null: an empty value is Bytes.alloc(0).');
		}

		if (value.length > options.maxValueBytes) {
			throw new ArgumentError('The value for $key is ${value.length} bytes, past the store\'s maxValueBytes of ${options.maxValueBytes}.');
		}
	}

	/** Refuses an expected revision that is not one: a whole number, of 1 or more where a record must be there. **/
	public static function checkExpected(expected:Float, mustBeRecord:Bool):Void {
		if (!(expected >= (mustBeRecord ? 1 : 0)) || expected != Math.ffloor(expected) || expected > 9007199254740992.0) {
			throw new ArgumentError('$expected is not a revision: a whole number of ${mustBeRecord ? 1 : 0} or more.');
		}
	}

	/** Refuses a stored value past `maxValue`, which is not read. **/
	public static inline function checkSize(key:String, size:Float, maxValue:Int):Void {
		if (size > maxValue) {
			throw new KVError(TooLarge, key,
				'$key holds ${Std.int(size)} bytes, past the store\'s maxValueBytes of $maxValue: it is refused, and was not read.');
		}
	}
}
