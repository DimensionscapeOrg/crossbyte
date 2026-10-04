package crossbyte._internal.serial;

#if format
import crossbyte.errors.IOError;
import format.amf.Value as AMFValue;
import format.amf3.Value as AMF3Value;
import haxe.ds.Vector;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Input;

/**
	`format`'s AMF0 reader, refusing a value nested more than `limit` deep
	before the stack does, and one holding more than `values` values before
	memory does, as `BoundedUnserializer` refuses HXSF.

	It reads a value within a value by calling itself, as `haxe.Unserializer`
	does, and natively a peer's object nested a few thousand deep overflowed
	the stack and ended the process. Every value, an object's members
	included, is read through `readWithCode`, so counting there bounds them
	all; a member's name is counted where it is read.

	A long string's length is a 32-bit count ahead of it, and `format` made
	a buffer that long before reading any of it: five bytes asked for 2 GB.
	Text here is read as it arrives; see `AMFText`.
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
	@:noCompletion private var __most:Int;
	@:noCompletion private var __left:Int;

	/**
		@param values The most values the read may hold, or zero or less
		       for no limit. `BoundedUnserializer.maxValues` unless given.
	**/
	public function new(input:Input, limit:Int = BoundedAMFReader.LIMIT, ?values:Int) {
		super(input);
		__limit = limit;
		var most:Int = values != null ? values : BoundedUnserializer.maxValues;
		__most = most > 0 ? most : 0x7FFFFFFF;
		__left = __most;
	}

	override public function readWithCode(id:Int):AMFValue {
		if (++__depth > __limit) {
			throw new IOError('nested more than $__limit levels deep');
		}
		__count();
		// A long string, read as it arrives rather than into a buffer of the
		// length it claims; otherwise as format reads it.
		var value:AMFValue = id == 0x0C ? AString(AMFText.read(i, i.readInt32())) : super.readWithCode(id);
		__depth--;
		return value;
	}

	// format's object, its members' names counted as values.
	override function readObject():Map<String, AMFValue> {
		var h:Map<String, AMFValue> = new Map();
		while (true) {
			var c1:Int = i.readByte();
			var c2:Int = i.readByte();
			var name:String = i.readString((c1 << 8) | c2);
			var k:Int = i.readByte();
			if (k == 0x09) {
				break;
			}
			__count();
			h.set(name, readWithCode(k));
		}
		return h;
	}

	@:noCompletion private inline function __count():Void {
		if (__left <= 0) {
			throw new IOError('more than $__most values');
		}
		__left--;
	}
}

/**
	`format`'s AMF3 reader, bounded as `BoundedAMFReader` is: in depth, in
	values, every value, each element of a vector, and each name and
	string read for the first time, and in what it allocates ahead of
	reading.

	A string's, a byte array's or a vector's length is a 29-bit count ahead
	of it, and `format` made a buffer or a vector that long before reading
	any of it: five bytes asked for 256 MB, or a vector of 268 million
	slots. Here text and bytes are read as they arrive, and a vector's
	elements are counted and gathered as they are read.
**/
class BoundedAMF3Reader extends format.amf3.Reader {
	@:noCompletion private var __depth:Int = 0;
	@:noCompletion private var __limit:Int;
	@:noCompletion private var __most:Int;
	@:noCompletion private var __left:Int;

	// Whether the string being read is a value, counted already as one.
	@:noCompletion private var __stringIsValue:Bool = false;

	/** See `BoundedAMFReader`. **/
	public function new(input:Input, limit:Int = BoundedAMFReader.LIMIT, ?values:Int) {
		super(input);
		__limit = limit;
		var most:Int = values != null ? values : BoundedUnserializer.maxValues;
		__most = most > 0 ? most : 0x7FFFFFFF;
		__left = __most;
	}

	override public function readWithCode(id:Int):AMF3Value {
		if (++__depth > __limit) {
			throw new IOError('nested more than $__limit levels deep');
		}
		__count();
		// A string read as a value reads nothing within it.
		__stringIsValue = id == 0x06;
		var value:AMF3Value = super.readWithCode(id);
		__stringIsValue = false;
		__depth--;
		return value;
	}

	override function readStringNoHeader(len:Int):AMF3Value {
		if (len == 0) {
			return AString("");
		}
		if (!__stringIsValue) {
			// A member's or a class's name, new to this read.
			__count();
		}
		__stringIsValue = false;
		var ret:AMF3Value = AString(AMFText.read(i, len));
		stringTable.push(ret);
		return ret;
	}

	override function readBytes():AMF3Value {
		var n:Int = readInt();
		if (n & 1 == 0) {
			return complexObjectsTable[n >> 1];
		}
		var ret:AMF3Value = ABytes(AMFText.bytes(i, n >> 1));
		complexObjectsTable.push(ret);
		return ret;
	}

	override function readIntVector():AMF3Value {
		var header:Int = readInt();
		if (header & 1 == 0) {
			return complexObjectsTable[header >> 1];
		}
		var len:Int = header >> 1;
		var fixed:Bool = i.readByte() != 0;
		var a:Array<AMF3Value> = [];
		for (_ in 0...len) {
			__count();
			a.push(AInt(i.readInt32()));
		}
		var ret:AMF3Value = fixed ? AVector(Vector.fromArrayCopy(a), "Int") : AArray(a);
		complexObjectsTable.push(ret);
		return ret;
	}

	override function readDoubleVector():AMF3Value {
		var header:Int = readInt();
		if (header & 1 == 0) {
			return complexObjectsTable[header >> 1];
		}
		var len:Int = header >> 1;
		var fixed:Bool = i.readByte() != 0;
		var a:Array<AMF3Value> = [];
		for (_ in 0...len) {
			__count();
			a.push(ANumber(i.readDouble()));
		}
		var ret:AMF3Value = fixed ? AVector(Vector.fromArrayCopy(a), "Number") : AArray(a);
		complexObjectsTable.push(ret);
		return ret;
	}

	// format's, without the traces of a peer's class name, and with its
	// elements gathered as they are read rather than into a vector of the
	// length claimed. Each is a value, and counted as one.
	override function readObjectVector():AMF3Value {
		var header:Int = readInt();
		if (header & 1 == 0) {
			return complexObjectsTable[header >> 1];
		}
		var len:Int = header >> 1;
		var fixed:Bool = i.readByte() != 0;
		var objectTypeName:String = format.amf3.Tools.decode(readString());
		var a:Array<AMF3Value> = [];
		// Referred to while its elements are read, as format's is.
		var at:Int = complexObjectsTable.length;
		complexObjectsTable.push(fixed ? AVector(new Vector(0), objectTypeName) : AArray(a));
		for (_ in 0...len) {
			a.push(read());
		}
		if (fixed) {
			complexObjectsTable[at] = AVector(Vector.fromArrayCopy(a), objectTypeName);
		}
		return complexObjectsTable[at];
	}

	@:noCompletion private inline function __count():Void {
		if (__left <= 0) {
			throw new IOError('more than $__most values');
		}
		__left--;
	}
}

/**
	Text and bytes of a length a peer gives, read as they arrive: a buffer
	grows with what is there, never to a length nothing has sent.
**/
class AMFText {
	// Read at once up to this; past it, a chunk at a time.
	private static inline var CHUNK:Int = 65536;

	/** `length` bytes of UTF-8 from `input`, as `Input.readString` reads them. **/
	public static function read(input:Input, length:Int):String {
		if (length < 0) {
			throw new IOError('malformed: a string of $length bytes');
		}
		if (length <= CHUNK) {
			return input.readString(length);
		}
		return bytes(input, length).toString();
	}

	/** `length` bytes from `input`; `haxe.io.Eof` if they are not all there. **/
	public static function bytes(input:Input, length:Int):Bytes {
		if (length < 0) {
			throw new IOError('malformed: $length bytes');
		}
		if (length <= CHUNK) {
			var whole:Bytes = Bytes.alloc(length);
			input.readFullBytes(whole, 0, length);
			return whole;
		}
		var buffer:BytesBuffer = new BytesBuffer();
		var chunk:Bytes = Bytes.alloc(CHUNK);
		var left:Int = length;
		while (left > 0) {
			var n:Int = left < CHUNK ? left : CHUNK;
			input.readFullBytes(chunk, 0, n);
			buffer.addBytes(chunk, 0, n);
			left -= n;
		}
		return buffer.getBytes();
	}
}
#end
