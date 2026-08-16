package crossbyte.crypto._internal;

#if cpp
import cpp.ConstPointer;
import cpp.RawPointer;
import cpp.UInt8;

@:buildXml('<include name="../../src/crossbyte/crypto/_internal/NativePkBuild.xml"/>')
@:include("./NativePk.h")
extern class NativePk {
	@:native("crossbyte_pk_available")
	public static function isAvailable():Bool;

	@:native("crossbyte_pk_verify_sha256")
	public static function verifySha256(publicKeyPem:ConstPointer<UInt8>, publicKeyLength:Int, hash:ConstPointer<UInt8>, signature:ConstPointer<UInt8>,
		signatureLength:Int, signatureFormat:Int):Int;

	@:native("crossbyte_pk_sign_sha256")
	public static function signSha256(privateKeyPem:ConstPointer<UInt8>, privateKeyLength:Int, hash:ConstPointer<UInt8>, out:RawPointer<UInt8>,
		outCapacity:Int, outLength:RawPointer<Int>, signatureFormat:Int):Int;

	@:native("crossbyte_pk_error_message")
	public static function errorMessage(code:Int):String;

	@:native("crossbyte_pk_key_type")
	public static function keyType(keyPem:ConstPointer<UInt8>, keyLength:Int, isPrivate:Bool):Int;

	@:native("crossbyte_pk_ec_coordinate_size")
	public static function ecCoordinateSize(keyPem:ConstPointer<UInt8>, keyLength:Int, isPrivate:Bool):Int;
}
#else
extern class NativePk {}
#end
