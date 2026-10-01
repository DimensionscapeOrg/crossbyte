package crossbyte._internal.serial;

import crossbyte.errors.IOError;
import haxe.Unserializer;

/**
	`haxe.Unserializer` that refuses a value nested more than `limit` deep,
	before the stack does, with an `IOError`.

	Unserializing takes a frame or two per level, and natively a payload
	another process or a peer wrote nested 6,000 deep -- 12 KB, inside a
	region's, a message's or a socket's limit -- overflowed the stack and
	ended the process reading it, where no catch can see it. On Windows'
	1 MB thread stacks nested objects overflowed past 2,000 levels and
	arrays past 3,000, and a macOS worker thread has half the stack. What
	reads HXSF from elsewhere reads it through this: `ByteArray.readObject`
	(and so every socket's), `SharedObject` and `SharedChannel`.

	Every level goes through `unserialize()`, a class's own `hxUnserialize`
	included, so counting there bounds them all.
**/
class BoundedUnserializer extends Unserializer {
	/**
		Values within values, at most: deeper than any structure a program
		keeps, and well inside the smallest stack a reader runs on -- a macOS
		worker thread's, or the interpreter's, which this class's own frame
		per level ran out of near 510 levels.
	**/
	public static inline var LIMIT:Int = 256;

	@:noCompletion private var __depth:Int = 0;
	@:noCompletion private var __limit:Int;

	public function new(buffer:String, limit:Int = LIMIT) {
		super(buffer);
		__limit = limit;
	}

	/** Unserializes `buffer`, refusing a value nested more than `limit` deep. */
	public static function run(buffer:String, limit:Int = LIMIT):Dynamic {
		return new BoundedUnserializer(buffer, limit).unserialize();
	}

	override public function unserialize():Dynamic {
		if (++__depth > __limit) {
			throw new IOError('nested more than $__limit levels deep');
		}
		var value:Dynamic = super.unserialize();
		__depth--;
		return value;
	}
}
