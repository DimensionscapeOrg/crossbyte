package crossbyte._internal.socket;

// Not built for the browser. This is a raw TCP socket with its own TLS, and a browser grants neither: it can open a WebSocket and nothing lower. Browser code reaches a ws:// or wss:// endpoint through crossbyte.net.Socket, which speaks WebSocket natively there.
#if !js

import haxe.io.Input;
import haxe.io.Output;
import sys.net.Host;
import sys.net.Socket;
#if (java || jvm)
// Haxe's sys.ssl.Socket (java.net.SslSocket) does not compile on the jvm
// target, so TLS there goes through CrossByte's own SSLEngine-based backend.
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslCertificate as Certificate;
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslKey as Key;
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket as SSLSocket;
#else
import sys.ssl.Certificate;
import sys.ssl.Key;
import sys.ssl.Socket as SSLSocket;
#end
#if cpp
import crossbyte._internal.socket.AlpnSocket;
import crossbyte._internal.socket.NativeAlpn;
#end

typedef HostInfo = {port:Int, host:Host};
typedef Sockets = {write:Array<Socket>, read:Array<Socket>, others:Array<Socket>};

@:forward
// Over sys.net.Socket, which every TLS socket here extends -- AlpnSocket,
// hl's and the jvm's -- rather than EitherType<Socket, SSLSocket>, which is
// Dynamic underneath: every forwarded call converted it back to a Socket,
// natively a type check per call.
abstract FlexSocket(Socket) from Socket to Socket from SSLSocket {
	public static var DEFAULT_CA(get, set):Null<Certificate>;

	public static var DEFAULT_VERIFY_CERT(get, set):Null<Bool>;

	/**
	 * Whether `setALPN` on a secure socket actually reaches the TLS handshake.
	 *
	 * Negotiated on cpp, through hxcpp's mbedTLS, and on jvm, through the JDK's
	 * SSLParameters. Elsewhere `setALPN` is accepted and ignored and `getALPN`
	 * stays `null`, which lets a caller offer `h2` unconditionally and fall
	 * back to HTTP/1.1 on the targets that cannot reach it.
	 */
	// True on jvm because the JDK carries ALPN in SSLParameters, so unlike cpp
	// -- where it needs a native extension built against mbedTLS, and so has to
	// be asked about at runtime -- there is nothing that can be missing.
	public static var alpnSupported(default, null):Bool = #if cpp NativeAlpn.isAvailable() #elseif (java || jvm) true #else false #end;

	private static inline function get_DEFAULT_CA():Null<Certificate> {
		return SSLSocket.DEFAULT_CA;
	}

	private static inline function set_DEFAULT_VERIFY_CERT(value:Null<Bool>):Null<Bool> {
		return SSLSocket.DEFAULT_VERIFY_CERT = value;
	}

	private static inline function get_DEFAULT_VERIFY_CERT():Null<Bool> {
		return SSLSocket.DEFAULT_VERIFY_CERT;
	}

	private static inline function set_DEFAULT_CA(value:Null<Certificate>):Null<Certificate> {
		return SSLSocket.DEFAULT_CA = value;
	}

	public static function select(read:Array<FlexSocket>, write:Array<FlexSocket>, others:Array<FlexSocket>, ?timeout:Float):Sockets {
		return Socket.select(cast read, cast write, cast others, timeout);
	}

	private static inline function __requireSSL(field:String, instance:FlexSocket):Void {
		if (!instance.isSecure) {
			throw '$field::Field only available when using a secure socket';
		}
	}

	/** The TLS socket this is; for a plain one, see `isSecure`. **/
	@:to private inline function toSSLSocket():SSLSocket {
		return cast this;
	}

	public var custom(get, set):Dynamic;

	public var input(get, never):Input;

	public var isSecure(get, never):Bool;

	public var output(get, never):Output;

	public var verifyCert(get, set):Null<Bool>;

	public inline function new(secure:Bool = false) {
		if (secure) {
			// AlpnSocket only adds a hook to buildSSLConfig, so it behaves
			// exactly like SSLSocket until setALPN is called.
			#if cpp
			this = new AlpnSocket();
			#elseif hl
			// The standard library's TLS socket reads the network without
			// telling HashLink's collector it is waiting, so a thread waiting
			// on a slow server stopped every other thread at the next
			// collection; see HlTlsSocket.
			this = new crossbyte._internal.socket.HlTlsSocket();
			#else
			this = new SSLSocket();
			#end
		} else {
			this = new Socket();
		}
	}

	/**
	 * Advertises `protocols` during the TLS handshake, most preferred first.
	 *
	 * Must be called before `connect`, which is where the TLS configuration is
	 * built. Does nothing on targets where `alpnSupported` is `false`.
	 */
	public inline function setALPN(protocols:Null<Array<String>>):Void {
		__requireSSL("setALPN", this);

		#if cpp
		(cast this : AlpnSocket).setALPN(protocols);
		#elseif (java || jvm)
		(cast this : SSLSocket).setALPN(protocols);
		#end
	}

	/**
	 * The protocol agreed during the handshake, or `null` when none was
	 * negotiated, the handshake has not completed, or the target does not
	 * support ALPN.
	 */
	public inline function getALPN():Null<String> {
		__requireSSL("getALPN", this);

		#if cpp
		return AlpnSocket.negotiated(cast this);
		#elseif (java || jvm)
		return (cast this : SSLSocket).getALPN();
		#else
		return null;
		#end
	}

	private inline function get_custom():Dynamic {
		return this.custom;
	}

	private inline function set_custom(value:Dynamic):Dynamic {
		return this.custom = value;
	}

	private inline function get_input():Input {
		return this.input;
	}

	private inline function get_isSecure():Bool {
		if (Std.isOfType(this, SSLSocket)) {
			return true;
		}

		return false;
	}

	private inline function get_output():Output {
		return this.output;
	}

	private inline function get_verifyCert():Null<Bool> {
		__requireSSL("verifyCert", this);

		return (cast this : SSLSocket).verifyCert;
	}

	private inline function set_verifyCert(value:Null<Bool>):Null<Bool> {
		__requireSSL("verifyCert", this);

		return (cast this : SSLSocket).verifyCert = value;
	}

	public inline function accept():Socket {
		return this.accept();
	}

	public inline function addSNICertificate(cbServernameMatch:String->Bool, cert:Certificate, key:Key):Void {
		__requireSSL("addSNICertificate", this);

		(cast this : SSLSocket).addSNICertificate(cbServernameMatch, cert, key);
	}

	public inline function bind(host:String, port:Int):Void {
		this.bind(new Host(host), port);
	}

	public inline function close():Void {
		this.close();
	}

	/**
		Connects to `host`, looking it up first if it is a name -- here, on the
		calling thread, for as long as the resolver takes. A caller on a
		runtime's thread looks the name up with `Resolver` and calls
		`connectHost` with the answer instead.
	**/
	public inline function connect(host:String, port:Int):Void {
		this.connect(new Host(host), port);
	}

	/** Connects to an address already resolved. **/
	public inline function connectHost(host:Host, port:Int):Void {
		this.connect(host, port);
	}

	public inline function handshake():Void {
		__requireSSL("handshake", this);

		(cast this : SSLSocket).handshake();
	}

	public inline function host():HostInfo {
		return this.host();
	}

	public inline function listen(connections:Int = 0):Void {
		// ServerSocket's default: past what any system grants, and within
		// neko's 31-bit Int, which the largest Int is not.
		if (connections == 0)
			connections = 0x7FFFFFF;
		this.listen(connections);
	}

	public inline function peer():HostInfo {
		return this.peer();
	}

	public inline function peerCertificate():Certificate {
		__requireSSL("peerCertificate", this);

		return (cast this : SSLSocket).peerCertificate();
	}

	public inline function read():String {
		return this.read();
	}

	public inline function setBlocking(value:Bool):Void {
		this.setBlocking(value);
	}

	public inline function setCA(cert:Certificate):Void {
		__requireSSL("setCA", this);

		(cast this : SSLSocket).setCA(cert);
	}

	public inline function setCertificate(cert:Certificate, key:Key):Void {
		__requireSSL("setCertificate", this);

		(cast this : SSLSocket).setCertificate(cert, key);
	}

	public inline function setFastSend(value:Bool):Void {
		this.setFastSend(value);
	}

	public inline function setHostname(name:String):Void {
		__requireSSL("setHostname", this);

		(cast this : SSLSocket).setHostname(name);
	}

	public inline function setTimeout(value:Float):Void {
		this.setTimeout(value);
	}

	public inline function shutdown(read:Bool, write:Bool):Void {
		this.shutdown(read, write);
	}

	private inline function waitForRead():Void {
		this.waitForRead();
	}

	private inline function write(content:String):Void {
		this.write(content);
	}
}
#end
