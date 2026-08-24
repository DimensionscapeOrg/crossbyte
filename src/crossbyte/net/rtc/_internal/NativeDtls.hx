package crossbyte.net.rtc._internal;

#if cpp
/**
	The native side of `DtlsCertificate`.

	Native only. mbedTLS is what hxcpp already links for `sys.ssl`, and nothing
	on the other targets offers certificate generation -- Node has no DTLS at
	all, and a browser makes its own certificates inside `RTCPeerConnection`
	where nothing can reach them.
**/
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/net/rtc/_internal/NativeDtlsBuild.xml"/>')
@:include("./NativeDtls.h")
extern class NativeDtls {
	@:native("crossbyte_dtls_available")
	static function isAvailable():Bool;

	@:native("crossbyte_dtls_last_error")
	static function lastError():Int;

	@:native("crossbyte_dtls_generate")
	static function generate(commonName:String, notBefore:String, notAfter:String):Null<Array<String>>;

	@:native("crossbyte_dtls_fingerprint")
	static function fingerprint(certificatePem:String):Null<String>;
}
#end
