package crossbyte.rpc._internal;

import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
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

	public static function writeArgs(output:ByteArrayOutput, args:Array<Dynamic>):Void {
		final values = (args == null) ? [] : args;
		output.reserve(5);
		output.writeVarUInt(values.length);
		for (value in values) {
			writeValue(output, value);
		}
	}

	public static function readArgs(input:ByteArrayInput):Array<Dynamic> {
		final count:Int = input.readVarUInt();
		final values:Array<Dynamic> = [];
		values.resize(count);
		for (i in 0...count) {
			values[i] = readValue(input);
		}
		return values;
	}

	public static function writeValue(output:ByteArrayOutput, value:Dynamic):Void {
		if (value == null) {
			output.reserve(1);
			output.writeByte(TAG_NULL);
			return;
		}

		switch (Type.typeof(value)) {
			case TBool:
				output.reserve(1);
				output.writeByte(value ? TAG_TRUE : TAG_FALSE);
			case TInt:
				output.reserve(5);
				output.writeByte(TAG_INT);
				output.writeInt(value);
			case TFloat:
				output.reserve(9);
				output.writeByte(TAG_FLOAT);
				output.writeDouble(value);
			case TClass(String):
				output.reserve(1);
				output.writeByte(TAG_STRING);
				output.writeVarUTF(value);
			case TClass(Bytes):
				final bytes:Bytes = cast value;
				output.reserve(1);
				output.writeByte(TAG_BYTES);
				output.writeVarUInt(bytes.length);
				output.reserve(bytes.length);
				output.writeBytes(bytes, 0, bytes.length);
			default:
				throw "Unsupported runtime RPC value: " + Std.string(Type.typeof(value));
		}
	}

	public static function readValue(input:ByteArrayInput):Dynamic {
		return switch (input.readByte()) {
			case TAG_NULL: null;
			case TAG_FALSE: false;
			case TAG_TRUE: true;
			case TAG_INT: input.readInt();
			case TAG_FLOAT: input.readDouble();
			case TAG_STRING: input.readVarUTF();
			case TAG_BYTES:
				final length:Int = input.readVarUInt();
				final bytes = Bytes.alloc(length);
				input.readBytes(bytes, 0, length);
				bytes;
			case tag:
				throw "Unsupported runtime RPC tag: " + tag;
		}
	}
}
