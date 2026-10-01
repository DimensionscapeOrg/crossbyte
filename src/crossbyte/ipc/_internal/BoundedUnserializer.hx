package crossbyte.ipc._internal;

// Not built for the browser: what reads payloads other processes wrote.
#if !js

import haxe.Unserializer;

/**
	`haxe.Unserializer` that refuses a value nested more than `limit` deep,
	before the stack does.

	Unserializing takes a frame or two per level, and natively a payload
	another process wrote nested 6,000 deep -- 12 KB, inside a region's or a
	message's limit -- overflowed the stack and ended the process reading
	it, where no catch can see it. On Windows' 1 MB thread stacks nested
	objects overflowed past 2,000 levels and arrays past 3,000, and a macOS
	worker thread has half the stack.

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
			throw 'nested more than $__limit levels deep';
		}
		var value:Dynamic = super.unserialize();
		__depth--;
		return value;
	}
}
#end
