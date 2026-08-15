package crossbyte.crypto._internal;

#if cpp
import cpp.ConstPointer;
import cpp.RawPointer;
import cpp.UInt8;

@:buildXml('<include name="../../src/crossbyte/crypto/_internal/NativeSodiumBuild.xml"/>')
@:include("./NativeSodium.h")
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

	@:native("crossbyte_crypto_aead_xchacha20poly1305_encrypt")
	public static function aeadEncrypt(out:RawPointer<UInt8>, message:ConstPointer<UInt8>, messageLength:Int, additionalData:ConstPointer<UInt8>, additionalDataLength:Int, nonce:ConstPointer<UInt8>, key:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_aead_xchacha20poly1305_decrypt")
	public static function aeadDecrypt(out:RawPointer<UInt8>, ciphertext:ConstPointer<UInt8>, ciphertextLength:Int, additionalData:ConstPointer<UInt8>, additionalDataLength:Int, nonce:ConstPointer<UInt8>, key:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_scalarmult_base")
	public static function scalarmultBase(point:RawPointer<UInt8>, scalar:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_scalarmult")
	public static function scalarmult(point:RawPointer<UInt8>, scalar:ConstPointer<UInt8>, peerPoint:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_kx_keypair")
	public static function kxKeypair(publicKey:RawPointer<UInt8>, secretKey:RawPointer<UInt8>):Int;

	@:native("crossbyte_crypto_kx_client_session_keys")
	public static function kxClientSessionKeys(rx:RawPointer<UInt8>, tx:RawPointer<UInt8>, clientPublicKey:ConstPointer<UInt8>, clientSecretKey:ConstPointer<UInt8>, serverPublicKey:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_kx_server_session_keys")
	public static function kxServerSessionKeys(rx:RawPointer<UInt8>, tx:RawPointer<UInt8>, serverPublicKey:ConstPointer<UInt8>, serverSecretKey:ConstPointer<UInt8>, clientPublicKey:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_generichash")
	public static function genericHash(out:RawPointer<UInt8>, outLength:Int, input:ConstPointer<UInt8>, inputLength:Int, key:ConstPointer<UInt8>, keyLength:Int):Int;

	@:native("crossbyte_crypto_hkdf_sha256_extract")
	public static function hkdfSha256Extract(prk:RawPointer<UInt8>, salt:ConstPointer<UInt8>, saltLength:Int, ikm:ConstPointer<UInt8>, ikmLength:Int):Int;

	@:native("crossbyte_crypto_hkdf_sha256_expand")
	public static function hkdfSha256Expand(out:RawPointer<UInt8>, outLength:Int, info:ConstPointer<UInt8>, infoLength:Int, prk:ConstPointer<UInt8>):Int;

	@:native("crossbyte_crypto_pwhash_derive")
	public static function pwhashDerive(out:RawPointer<UInt8>, outLength:Int, password:ConstPointer<UInt8>, passwordLength:Int, salt:ConstPointer<UInt8>, opslimit:Int, memlimit:Int):Int;

	@:native("crossbyte_crypto_pwhash_str")
	public static function pwhashStr(out128:RawPointer<UInt8>, password:ConstPointer<UInt8>, passwordLength:Int, opslimit:Int, memlimit:Int):Int;

	@:native("crossbyte_crypto_pwhash_str_verify")
	public static function pwhashStrVerify(hashStr:ConstPointer<UInt8>, password:ConstPointer<UInt8>, passwordLength:Int):Int;

	@:native("crossbyte_crypto_pwhash_str_needs_rehash")
	public static function pwhashStrNeedsRehash(hashStr:ConstPointer<UInt8>, opslimit:Int, memlimit:Int):Int;

	@:native("crossbyte_crypto_memcmp")
	public static function memcmp(a:ConstPointer<UInt8>, b:ConstPointer<UInt8>, length:Int):Int;

	@:native("crossbyte_crypto_memzero")
	public static function memzero(buffer:RawPointer<UInt8>, length:Int):Void;
}
#else
extern class NativeSodium {}
#end
