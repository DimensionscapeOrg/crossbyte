package crossbyte._internal.socket;

// Guarded on `cpp` rather than `(cpp || hxcpp)`: these resolve to symbols in
// CrossByte's own NativeAlpn.cpp, and the hxcpp haxelib defines `hxcpp` on
// targets that never compile it.
#if cpp
/**
 * ALPN (RFC 7301) for the TLS sockets hxcpp already provides.
 *
 * `sys.ssl.Socket` exposes no way to advertise a protocol list, which is what
 * TLS needs before an `h2` connection can be negotiated at all. mbedTLS has
 * carried the support all along -- hxcpp ships it with `MBEDTLS_SSL_ALPN`
 * enabled -- so this only reaches what was already linked.
 *
 * Implemented here rather than as a patch to hxcpp's `SSL.cpp`. A patch would
 * mean every CrossByte build needed a forked hxcpp, and would fail to *link*
 * against a stock one rather than merely lose the feature. The same change is
 * worth having upstream, and the symbols are named `crossbyte_*` so both can
 * exist at once when it lands.
 */
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/_internal/socket/NativeAlpnBuild.xml"/>')
@:include("./NativeAlpn.h")
extern class NativeAlpn {
	/** Whether the mbedTLS in this build has ALPN compiled in. */
	@:native("crossbyte_alpn_available")
	static function isAvailable():Bool;

	/**
	 * Advertises `protocols` on `conf`, in descending order of preference.
	 *
	 * Must be called before the handshake reads the config. An empty or null
	 * list clears any previous one. Returns 0 on success; negative when the
	 * handle is not an SSL config, when allocation fails, or when mbedTLS
	 * rejects a name as empty or over 255 bytes.
	 */
	@:native("crossbyte_alpn_set")
	static function set(conf:Dynamic, protocols:Null<Array<String>>):Int;

	/**
	 * Releases the list installed for `conf`.
	 *
	 * mbedTLS stores the list by reference and never owns it, so this has to
	 * be called when the socket is done or the allocation outlives it.
	 */
	@:native("crossbyte_alpn_release")
	static function release(conf:Dynamic):Void;

	/**
	 * The protocol agreed during the handshake, or `null` when the handshake
	 * has not completed or the peer declined to negotiate one.
	 */
	@:native("crossbyte_alpn_selected")
	static function selected(ctx:Dynamic):Null<String>;
}
#end
