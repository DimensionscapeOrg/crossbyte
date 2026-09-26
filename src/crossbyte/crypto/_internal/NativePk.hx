package crossbyte.crypto._internal;

#if cpp
import cpp.ConstPointer;
import cpp.RawPointer;
import cpp.UInt8;

/**
 * The mbedTLS public-key bridge. Keys are parsed once into an opaque object the
 * GC owns and the native side frees, and wipes, when it is collected or
 * disposed of. See NativePk.h.
 */
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/crypto/_internal/NativePkBuild.xml"/>')
@:include("./NativePk.h")
extern class NativePk {
	@:native("crossbyte_pk_available")
	public static function isAvailable():Bool;

	@:native("crossbyte_pk_key_load")
	public static function load(pem:ConstPointer<UInt8>, pemLength:Int, isPrivate:Bool, error:RawPointer<Int>):Dynamic;

	@:native("crossbyte_pk_key_type")
	public static function keyType(key:Dynamic):Int;

	@:native("crossbyte_pk_key_coordinate_size")
	public static function coordinateSize(key:Dynamic):Int;

	@:native("crossbyte_pk_key_sign_sha256")
	public static function signSha256(key:Dynamic, hash:ConstPointer<UInt8>, out:RawPointer<UInt8>, outCapacity:Int, outLength:RawPointer<Int>,
		signatureFormat:Int):Int;

	@:native("crossbyte_pk_key_verify_sha256")
	public static function verifySha256(key:Dynamic, hash:ConstPointer<UInt8>, signature:ConstPointer<UInt8>, signatureLength:Int,
		signatureFormat:Int):Int;

	@:native("crossbyte_pk_key_dispose")
	public static function dispose(key:Dynamic):Void;

	@:native("crossbyte_pk_error_message")
	public static function errorMessage(code:Int):String;

	@:native("crossbyte_pk_parse_count")
	public static function parseCount():Int;
}
#else
extern class NativePk {}
#end
