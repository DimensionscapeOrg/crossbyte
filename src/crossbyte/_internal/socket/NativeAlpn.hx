package crossbyte._internal.socket;

// Guarded on `cpp` rather than `(cpp || hxcpp)`: these resolve to symbols in
// hxcpp's SSL.cpp, and the hxcpp haxelib defines `hxcpp` on targets that never
// link it.
#if cpp
/**
 * ALPN (RFC 7301) entry points added to hxcpp's SSL library.
 *
 * `sys.ssl.Socket` exposes no way to advertise a protocol list, which is what
 * TLS needs before an `h2` connection can be negotiated at all. mbedtls has
 * carried the support all along -- hxcpp ships it with `MBEDTLS_SSL_ALPN`
 * enabled -- so this only surfaces what was already linked.
 */
// No @:buildXml here. These symbols live in the same SSL.cpp that
// `cpp.NativeSsl` already pulls in, and AlpnSocket cannot be reached without
// `sys.ssl.Socket` dragging that in first. Declaring the include a second time
// adds the object file twice and the linker warns (LNK4042).
extern class NativeAlpn {
	/**
	 * Advertises `protos` on `conf`, in descending order of preference.
	 *
	 * Must be called before the handshake reads the config. Passing `null` or
	 * an empty array clears the list. Throws if a name is empty or longer than
	 * 255 bytes, or if the encoded list exceeds 65535 bytes.
	 */
	@:native("_hx_ssl_conf_set_alpn")
	static function conf_set_alpn(conf:Dynamic, protos:Null<Array<String>>):Void;

	/**
	 * The protocol agreed during the handshake, or `null` when the handshake
	 * has not completed or the peer declined to negotiate one.
	 */
	@:native("_hx_ssl_get_alpn")
	static function get_alpn(ctx:Dynamic):Null<String>;
}
#end
