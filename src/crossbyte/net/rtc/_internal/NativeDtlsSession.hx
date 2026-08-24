package crossbyte.net.rtc._internal;

#if cpp
import cpp.ConstPointer;
import cpp.RawPointer;
import cpp.UInt8;

/**
	The native side of `DtlsTransport`.

	Sessions are named by an int handle rather than a pointer: nothing in Haxe
	can fabricate one, and a handle used after closing is refused rather than
	dereferenced.
**/
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/net/rtc/_internal/NativeDtlsBuild.xml"/>')
@:include("./NativeDtlsSession.h")
extern class NativeDtlsSession {
	@:native("crossbyte_dtls_open")
	static function open(isServer:Bool, certificatePem:String, privateKeyPem:String):Int;

	@:native("crossbyte_dtls_close")
	static function close(handle:Int):Void;

	@:native("crossbyte_dtls_feed")
	static function feed(handle:Int, data:ConstPointer<UInt8>, length:Int):Int;

	@:native("crossbyte_dtls_step")
	static function step(handle:Int, now:Float):Int;

	@:native("crossbyte_dtls_pending")
	static function pending(handle:Int):Int;

	@:native("crossbyte_dtls_take")
	static function take(handle:Int, out:RawPointer<UInt8>, capacity:Int):Int;

	@:native("crossbyte_dtls_write")
	static function write(handle:Int, data:ConstPointer<UInt8>, length:Int):Int;

	@:native("crossbyte_dtls_available")
	static function available(handle:Int):Int;

	@:native("crossbyte_dtls_read")
	static function read(handle:Int, out:RawPointer<UInt8>, capacity:Int):Int;

	@:native("crossbyte_dtls_peer_certificate")
	static function peerCertificate(handle:Int):Null<String>;

	@:native("crossbyte_dtls_error")
	static function error(handle:Int):Int;
}
#end
