package crossbyte._internal.socket._jvm;

/**
 * Compile-time stand-ins for the `sys.ssl.*` types on the java/jvm target.
 *
 * Haxe's `sys.ssl.Socket` (java.net.SslSocket) does not currently compile on the
 * jvm target, so CrossByte aliases the SSL surface used by `FlexSocket` /
 * `ServerWebSocket` to these stubs. Plain (non-TLS) sockets are fully supported;
 * any attempt to actually create or use a secure socket throws clearly. A real
 * jvm TLS backend (javax.net.ssl) can replace these later.
 */
class JvmSslSocket {
	public static var DEFAULT_CA:Null<JvmSslCertificate>;
	public static var DEFAULT_VERIFY_CERT:Null<Bool>;

	public var verifyCert:Null<Bool>;

	public function new() {
		throw __unsupported();
	}

	public function handshake():Void {
		throw __unsupported();
	}

	public function addSNICertificate(cbServernameMatch:String->Bool, cert:JvmSslCertificate, key:JvmSslKey):Void {
		throw __unsupported();
	}

	public function peerCertificate():JvmSslCertificate {
		throw __unsupported();
	}

	public function setCA(cert:JvmSslCertificate):Void {
		throw __unsupported();
	}

	public function setCertificate(cert:JvmSslCertificate, key:JvmSslKey):Void {
		throw __unsupported();
	}

	public function setHostname(name:String):Void {
		throw __unsupported();
	}

	static inline function __unsupported():String {
		return "TLS sockets are not yet supported on the jvm target.";
	}
}

class JvmSslCertificate {
	public function new() {}
}

class JvmSslKey {
	public function new() {}
}
