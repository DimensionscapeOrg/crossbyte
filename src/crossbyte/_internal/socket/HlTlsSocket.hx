package crossbyte._internal.socket;

#if hl
import sys.ssl.Context;

/**
	A `sys.ssl.Socket` whose waits for the network are ones HashLink's collector
	can see past.

	HashLink stops every thread to collect, and waits for each to reach a safe
	point or to have said it is blocked. Its plain socket reads say so. Its TLS
	point or to have said it is blocked. Its plain socket reads say so. Its TLS
	layer reads the network with a bare `recv` that does not (mbedTLS's
	socket callbacks in `ssl.hdll`), so a thread waiting for a slow server's
	answer on an HTTPS connection would hold every other thread for as long as
	the server took, and the collector would spin a core waiting.
	mbedTLS takes its reads and writes through callbacks, and `ssl.hdll` lets
	those be Haxe functions (`ssl_set_bio`). These hand them to the plain socket
	natives, whose reads are marked blocking, so a thread waiting on a TLS
	connection is passed over by the collector exactly as one waiting on a plain
	socket is. The handshake reads through them too. Nothing else changes:
	blocking and non-blocking use, timeouts, the handshake's failures and the
	end of the stream behave as the standard library's do, since the natives
	under them answer the same way.

	Not a wait in `select` before each read, which is the obvious fix and a
	wrong one: mbedTLS holds decrypted bytes the socket no longer has, so a
	reader taking a line a byte at a time would wait in `select` for data that
	had already arrived.

	A client socket. A server's accepted connections are the standard
	library's; the servers here drive them without blocking, where a read that
	finds nothing returns at once and there is no wait to mark.
**/
@:access(sys.net.Socket)
class HlTlsSocket extends sys.ssl.Socket {
	/**
		What mbedTLS is handed for its callbacks: this socket and the two
		functions. mbedTLS keeps it as a raw pointer, in memory the collector
		does not scan, so this field is what keeps it alive.
	**/
	@:noCompletion private var __bio:hl.NativeArray<Dynamic>;

	/** The standard library's `connect`, with the callbacks installed before the handshake. **/
	public override function connect(host:sys.net.Host, port:Int):Void {
		conf = buildConfig(false);
		ssl = new Context(conf);
		var bio = new hl.NativeArray<Dynamic>(3);
		bio[0] = this;
		bio[1] = __bioRead;
		bio[2] = __bioWrite;
		__bio = bio;
		__setBio(ssl, bio);
		handshakeDone = false;
		if (hostname == null)
			hostname = host.host;
		if (hostname != null)
			ssl.setHostname(@:privateAccess hostname.toUtf8());
		if (!sys.net.Socket.socket_connect(__s, host.ip, port))
			throw new Sys.SysError("Failed to connect on " + host.toString() + ":" + port);
		if (isBlocking)
			handshake();
	}

	/**
		mbedTLS's read, by way of `socket_recv`, which is marked blocking. A
		would-block (a timeout run out included) answers -2, which
		`ssl.hdll` turns into MBEDTLS_ERR_SSL_WANT_READ as its own callback
		does; a failure answers -1, which mbedTLS passes up as one.
	**/
	@:noCompletion private static function __bioRead(owner:Dynamic, buffer:hl.Bytes, length:Int):Int {
		var socket:sys.net.Socket = cast owner;
		var read = sys.net.Socket.socket_recv(socket.__s, buffer, 0, length);
		return read == -1 ? -2 : (read < 0 ? -1 : read);
	}

	/** mbedTLS's write, by way of `socket_send`, mapped the same way. **/
	@:noCompletion private static function __bioWrite(owner:Dynamic, buffer:hl.Bytes, length:Int):Int {
		var socket:sys.net.Socket = cast owner;
		var sent = sys.net.Socket.socket_send(socket.__s, buffer, 0, length);
		return sent == -1 ? -2 : (sent < 0 ? -1 : sent);
	}

	@:hlNative("ssl", "ssl_set_bio") @:noCompletion private static function __setBio(ssl:Context, bio:Dynamic):Void {}
}
#end
