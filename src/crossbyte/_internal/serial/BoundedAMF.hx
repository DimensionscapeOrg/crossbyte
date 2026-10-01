package crossbyte._internal.serial;

#if format
import crossbyte.errors.IOError;
import format.amf.Value as AMFValue;
import format.amf3.Value as AMF3Value;

/**
	`format`'s AMF0 reader, refusing a value nested more than `limit` deep
	before the stack does.

	It reads a value within a value by calling itself, as `haxe.Unserializer`
	does, and natively a peer's object nested a few thousand deep overflowed
	the stack and ended the process. Every value, an object's members
	included, is read through `readWithCode`, so counting there bounds them
	all.
**/
class BoundedAMFReader extends format.amf.Reader {
	/**
		Values within values, at most: half `BoundedUnserializer.LIMIT`,
		because an AMF level takes more stack than an HXSF one, the
		interpreter ran out at about 250 AMF0 levels, where HXSF lasts to
		about 510.
	**/
	public static inline var LIMIT:Int = 128;

	@:noCompletion private var __depth:Int = 0;
	@:noCompletion private var __limit:Int;

	public function new(input:haxe.io.Input, limit:Int = BoundedAMFReader.LIMIT) {
		super(input);
		__limit = limit;
	}

	override public function readWithCode(id:Int):AMFValue {
		if (++__depth > __limit) {
			throw new IOError('nested more than $__limit levels deep');
		}
		var value:AMFValue = super.readWithCode(id);
		__depth--;
		return value;
	}
}

/** `format`'s AMF3 reader, bounded the same way: see `BoundedAMFReader`. **/
class BoundedAMF3Reader extends format.amf3.Reader {
	@:noCompletion private var __depth:Int = 0;
	@:noCompletion private var __limit:Int;

	public function new(input:haxe.io.Input, limit:Int = BoundedAMFReader.LIMIT) {
		super(input);
		__limit = limit;
	}

	override public function readWithCode(id:Int):AMF3Value {
		if (++__depth > __limit) {
			throw new IOError('nested more than $__limit levels deep');
		}
		var value:AMF3Value = super.readWithCode(id);
		__depth--;
		return value;
	}
}
#end
