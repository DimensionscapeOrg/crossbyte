package crossbyte.crypto._internal;

#if php
/**
	PHP's sodium extension, which `Ed25519` and `Argon2id` use there. It is
	libsodium, the library the native builds compile in, so keys, signatures
	and hash strings are the same bytes on both. Byte strings are PHP strings:
	pass `Bytes.getData()`, and wrap what comes back with `Bytes.ofData`.
**/
@:noCompletion
@:phpGlobal
extern class PhpSodium {
	static function extension_loaded(name:String):Bool;

	static function sodium_crypto_sign_keypair():String;
	static function sodium_crypto_sign_seed_keypair(seed:String):String;
	static function sodium_crypto_sign_secretkey(keypair:String):String;
	static function sodium_crypto_sign_publickey(keypair:String):String;
	static function sodium_crypto_sign_detached(message:String, secretKey:String):String;
	static function sodium_crypto_sign_verify_detached(signature:String, message:String, publicKey:String):Bool;

	static function sodium_crypto_pwhash_str(password:String, opslimit:Int, memlimit:Int):String;
	static function sodium_crypto_pwhash_str_verify(hash:String, password:String):Bool;
	static function sodium_crypto_pwhash_str_needs_rehash(hash:String, opslimit:Int, memlimit:Int):Bool;
	static function sodium_crypto_pwhash(length:Int, password:String, salt:String, opslimit:Int, memlimit:Int, algo:Int):String;

	static var SODIUM_CRYPTO_PWHASH_ALG_ARGON2ID13:Int;
}

/** Whether PHP has the sodium extension, and what to say when it does not. **/
@:noCompletion
class PhpSodiumStatus {
	/** Whether the extension is loaded. **/
	public static inline function loaded():Bool {
		return PhpSodium.extension_loaded("sodium");
	}

	/** Why `feature` cannot run: the extension is not loaded. **/
	public static function reason(feature:String):String {
		return feature + " on PHP needs the sodium extension (extension=sodium in php.ini), which is not loaded.";
	}

	/** The error a member of `feature` throws when the extension is not loaded. **/
	public static function error(feature:String):crossbyte.errors.IllegalOperationError {
		return new crossbyte.errors.IllegalOperationError(reason(feature));
	}
}
#end
