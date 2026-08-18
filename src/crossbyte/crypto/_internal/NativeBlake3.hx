package crossbyte.crypto._internal;

#if cpp
import cpp.ConstPointer;
import cpp.RawPointer;
import cpp.UInt8;

@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/crypto/_internal/NativeBlake3Build.xml"/>')
@:include("./NativeBlake3.h")
extern class NativeBlake3 {
	@:native("crossbyte_crypto_blake3_hash")
	public static function hash(input:ConstPointer<UInt8>, inputLength:Int, output:RawPointer<UInt8>, outputLength:Int):Int;

	@:native("crossbyte_crypto_blake3_simd_degree")
	public static function simdDegree():Int;
}
#else
extern class NativeBlake3 {}
#end
