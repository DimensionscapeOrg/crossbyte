package crossbyte._internal.http;

// Guarded on `cpp`, as NativeAlpn is: the symbol lives in CrossByte's own
// NativeTlsPeer.cpp, which only a cpp build compiles.
#if cpp
/**
	The certificate a TLS peer presented, from an hxcpp socket's mbedTLS
	context, as DER.

	`sys.ssl.Socket.peerCertificate()` hands back a certificate that can name
	its subject and dates and nothing else: no bytes, and so no key to pin.
	mbedTLS has kept the DER all along; this reaches it, as NativeAlpn reaches
	the protocol list.
**/
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/_internal/http/NativeTlsPeerBuild.xml"/>')
@:include("./NativeTlsPeer.h")
extern class NativeTlsPeer {
	/**
		The peer's certificate as DER, or null when the handshake has not
		completed or the peer presented none. `ssl` is the context a
		`sys.ssl.Socket` keeps in its `ssl` field.
	**/
	@:native("crossbyte_tls_peer_der")
	static function der(ssl:Dynamic):Null<Array<cpp.UInt8>>;
}
#end
