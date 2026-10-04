package crossbyte.rpc._internal;

import crossbyte.io.ByteArrayInput;
import haxe.io.Bytes;

/**
 * Small self-describing codec used by the optional runtime RPC lane.
 *
 * The compile-time RPC path continues to use generated readers/writers and does
 * not flow through this codec.
 */
class RPCRuntimeCodec {
	public static inline final TAG_NULL:Int = 0;
	public static inline final TAG_FALSE:Int = 1;
	public static inline final TAG_TRUE:Int = 2;
	public static inline final TAG_INT:Int = 3;
	public static inline final TAG_FLOAT:Int = 4;
	public static inline final TAG_STRING:Int = 5;
	public static inline final TAG_BYTES:Int = 6;

	/** What `tagOf` answers for a value the lane does not carry. **/
	public static inline final NOT_CARRIED:Int = -1;

	public static function writeArgs(output:RPCFrame, args:Array<Dynamic>):Void {
		if (args == null) {
			output.putVarUInt(0);
			return;
		}
		output.putVarUInt(args.length);
		for (value in args) {
			writeValue(output, value);
		}
	}

	/** Reads a call's arguments, none of them past `end`. **/
	public static function readArgs(input:ByteArrayInput, end:Int):Array<Dynamic> {
		final count:Int = input.readVarUInt();
		RPCWire.requireRoom(input, end, count);
		final values:Array<Dynamic> = [];
		values.resize(count);
		for (i in 0...count) {
			values[i] = readValue(input, end);
		}
		return values;
	}

	/**
		@throws String For a value of a type the lane does not carry, of which
		        nothing has been written.
	**/
	public static function writeValue(output:RPCFrame, value:Dynamic):Void {
		switch (tagOf(value)) {
			case TAG_NULL:
				output.putByte(TAG_NULL);
			case TAG_FALSE:
				output.putByte(TAG_FALSE);
			case TAG_TRUE:
				output.putByte(TAG_TRUE);
			case TAG_INT:
				output.putByte(TAG_INT);
				output.putInt(value);
			case TAG_FLOAT:
				output.putByte(TAG_FLOAT);
				output.putDouble(value);
			case TAG_STRING:
				output.putByte(TAG_STRING);
				output.putString(value);
			case TAG_BYTES:
				// A subclass of Bytes is bytes all the same, a ByteArray is one
				// at run time, and goes as its own length, not its buffer's.
				output.putByte(TAG_BYTES);
				output.putBytes(cast value);
			case _:
				throw "Unsupported runtime RPC value: " + Std.string(Type.typeof(value));
		}
	}

	/**
		The tag `value` goes under, or `NOT_CARRIED`, without allocating:
		`Type.typeof` made a `TClass` for every String and Bytes it was asked
		about, on every call.

		The answer `Type.typeof` gave, on every target. A number is an Int or a
		Float as `Type.typeof` says, which is not the same everywhere: on
		JavaScript, the jvm and HashLink a whole number held as a Float, 2.0,
		is an Int, natively and on the interpreter and neko a Float; a whole
		number past an Int's range is a Float on all of them. `null` is
		`TAG_NULL`, and a `ByteArray` is `TAG_BYTES`.
	**/
	public static function tagOf(value:Dynamic):Int {
		if (value == null) {
			return TAG_NULL;
		}
		#if cpp
		// What Type.typeof switches on: vtBool, vtInt, vtFloat and vtString;
		// anything else is Bytes, a class instance, or not carried.
		return switch ((untyped value.__GetType() : Int)) {
			case 2:
				(value : Bool) ? TAG_TRUE : TAG_FALSE;
			case 0xFF:
				TAG_INT;
			case 1:
				TAG_FLOAT;
			case 3:
				TAG_STRING;
			case _:
				Std.isOfType(value, Bytes) ? TAG_BYTES : NOT_CARRIED;
		}
		#else
		// A String or Bytes was a TClass, the one answer that allocated; a test
		// of its class answers the same. A number's or a Bool's answer is a
		// constant, which allocates nothing, and is still Type.typeof's.
		if ((value is String)) {
			return TAG_STRING;
		}
		if ((value is Bytes)) {
			return TAG_BYTES;
		}
		return switch (Type.typeof(value)) {
			case TBool:
				(value : Bool) ? TAG_TRUE : TAG_FALSE;
			case TInt:
				TAG_INT;
			case TFloat:
				TAG_FLOAT;
			case _:
				NOT_CARRIED;
		}
		#end
	}

	/** Reads one value, not past `end`. **/
	public static function readValue(input:ByteArrayInput, end:Int):Dynamic {
		return switch (input.readByte()) {
			case TAG_NULL: null;
			case TAG_FALSE: false;
			case TAG_TRUE: true;
			case TAG_INT: input.readInt();
			case TAG_FLOAT: input.readDouble();
			case TAG_STRING: input.readVarUTF();
			case TAG_BYTES:
				final length:Int = input.readVarUInt();
				RPCWire.requireRoom(input, end, length);
				final bytes = Bytes.alloc(length);
				input.readBytes(bytes, 0, length);
				bytes;
			case tag:
				throw "Unsupported runtime RPC tag: " + tag;
		}
	}
}
