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

	public static function writeValue(output:RPCFrame, value:Dynamic):Void {
		if (value == null) {
			output.putByte(TAG_NULL);
			return;
		}

		switch (Type.typeof(value)) {
			case TBool:
				output.putByte(value ? TAG_TRUE : TAG_FALSE);
			case TInt:
				output.putByte(TAG_INT);
				output.putInt(value);
			case TFloat:
				output.putByte(TAG_FLOAT);
				output.putDouble(value);
			case TClass(String):
				output.putByte(TAG_STRING);
				output.putString(value);
			case TClass(Bytes):
				__writeBytes(output, cast value);
			case TClass(_) if (Std.isOfType(value, Bytes)):
				// A subclass of Bytes is bytes all the same: a ByteArray is one
				// at run time, and was refused here. Its own length, not its
				// buffer's.
				__writeBytes(output, cast value);
			default:
				throw "Unsupported runtime RPC value: " + Std.string(Type.typeof(value));
		}
	}

	private static inline function __writeBytes(output:RPCFrame, bytes:Bytes):Void {
		output.putByte(TAG_BYTES);
		output.putBytes(bytes);
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
