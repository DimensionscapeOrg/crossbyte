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

	/**
		The protocol the context runs, as mbedTLS names it: `"TLSv1.2"`,
		`"TLSv1.3"`. Null for anything that is not an hxcpp TLS context.
	**/
	@:native("crossbyte_tls_peer_protocol")
	static function protocol(ssl:Dynamic):Null<String>;

	/**
		The end of the handshake the configuration under the context says it
		is: `1` for a server, `0` for a client, `-1` for anything that is not
		an hxcpp TLS context. Read through the context, as mbedTLS reads its
		configuration on every record -- which is what a test needs to see
		that the configuration lives as long as the connections on it.
	**/
	@:native("crossbyte_tls_peer_endpoint")
	static function endpoint(ssl:Dynamic):Int;

	/**
		`MBEDTLS_VERSION_NUMBER` of the mbedTLS hxcpp built this program with,
		`0x03060700` for 3.6.7: 2.28 tops out at TLS 1.2, 3.x speaks TLS 1.3.
	**/
	@:native("crossbyte_tls_mbedtls_version")
	static function mbedtlsVersion():Int;
}
#end
