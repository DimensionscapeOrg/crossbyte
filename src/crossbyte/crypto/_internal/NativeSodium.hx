package crossbyte.crypto._internal;

import cpp.ConstPointer;
import cpp.RawPointer;
import cpp.UInt8;

@:include("./NativeSodium.cpp")
extern class NativeSodium {
	@:native("crossbyte_crypto_sodium_available")
	public static function isAvailable():Bool;

	@:native("crossbyte_crypto_sodium_status_message")
	public static function statusMessage():String;

	@:native("crossbyte_crypto_ed25519_keypair")
	public static function ed25519Keypair(publicKey:RawPointer<UInt8>, secretKey:RawPointer<UInt8>):Int;

	@:native("crossbyte_crypto_ed25519_sign_detached")
	public static function ed25519SignDetached(signature:RawPointer<UInt8>, message:ConstPointer<UInt8>, messageLength:Int, secretKey:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_ed25519_verify_detached")
	public static function ed25519VerifyDetached(signature:ConstPointer<UInt8>, message:ConstPointer<UInt8>, messageLength:Int, publicKey:ConstPointer<UInt8>):Int;
}
