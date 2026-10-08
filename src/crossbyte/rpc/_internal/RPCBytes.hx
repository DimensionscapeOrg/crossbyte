package crossbyte.rpc._internal;

import haxe.io.Bytes;

/**
	Little-endian numbers at a place in a `Bytes`, with no check of the
	place: for code that has checked, once, that a run of values lies
	within the bytes, an array of numbers, whose count was checked
	against its frame, written into a frame made room for all of it.

	Natively, a 32-bit or 16-bit integer is one load or store, where
	`Bytes.getInt32` and `setInt32` are four bounds-checked byte accesses
	each, and a float skips the check `getDouble` makes; elsewhere each is
	the `Bytes` accessor it stands for.
**/
@:noCompletion
class RPCBytes {
	public static inline function getI32(data:Bytes, at:Int):Int {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_i32(data.getData(), at);
		#else
		return data.getInt32(at);
		#end
	}

	public static inline function setI32(data:Bytes, at:Int, value:Int):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_i32(data.getData(), at, value);
		#else
		data.setInt32(at, value);
		#end
	}

	public static inline function getF64(data:Bytes, at:Int):Float {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_double(data.getData(), at);
		#else
		return data.getDouble(at);
		#end
	}

	public static inline function setF64(data:Bytes, at:Int, value:Float):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_double(data.getData(), at, value);
		#else
		data.setDouble(at, value);
		#end
	}

	public static inline function getF32(data:Bytes, at:Int):Float {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_float(data.getData(), at);
		#else
		return data.getFloat(at);
		#end
	}

	public static inline function setF32(data:Bytes, at:Int, value:Float):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_float(data.getData(), at, value);
		#else
		data.setFloat(at, value);
		#end
	}

	/** An unsigned 16-bit integer, 0 to 65535. **/
	public static inline function getU16(data:Bytes, at:Int):Int {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_ui16(data.getData(), at);
		#else
		return data.getUInt16(at);
		#end
	}

	/** A signed 16-bit integer, -32768 to 32767. **/
	public static inline function getI16(data:Bytes, at:Int):Int {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_i16(data.getData(), at);
		#else
		return (data.getUInt16(at) << 16) >> 16;
		#end
	}

	/** The low sixteen bits of `value`. **/
	public static inline function set16(data:Bytes, at:Int, value:Int):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_i16(data.getData(), at, value);
		#else
		data.setUInt16(at, value & 0xFFFF);
		#end
	}

	public static inline function getU8(data:Bytes, at:Int):Int {
		#if cpp
		return untyped __global__.__hxcpp_memory_get_byte(data.getData(), at) & 0xFF;
		#else
		return data.get(at);
		#end
	}

	/** The low eight bits of `value`. **/
	public static inline function set8(data:Bytes, at:Int, value:Int):Void {
		#if cpp
		untyped __global__.__hxcpp_memory_set_byte(data.getData(), at, value);
		#else
		data.set(at, value);
		#end
	}
}
