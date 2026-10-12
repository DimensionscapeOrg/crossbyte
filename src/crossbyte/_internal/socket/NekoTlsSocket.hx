package crossbyte._internal.socket;

#if neko
/**
	neko's TLS socket, whose listener gives each connection it accepts a TLS
	configuration of its own.

	The standard library's `accept()` sets every connection up on the
	listener's configuration, and the listener's `close()` frees it
	(`mbedtls_ssl_config_free`), under connections still using it: mbedTLS
	needs a configuration to outlive every connection set up on it. So a
	connection still open when its server closed, as a draining server's
	are, failed at its next read, and one still in its handshake read freed
	memory (on neko 2.3 on Windows, an access violation). Here each accepted
	connection is set up on a configuration built as the listener's was,
	which only that connection holds and its own `close()` frees, after its
	context.

	Natively the configuration is shared and counted instead (CrossByte's
	hxcpp); neko's `ssl.ndll` has no way to count, and a configuration of a
	connection's own costs a few microseconds against its handshake's
	milliseconds.
**/
@:access(sys.net.Socket)
@:access(sys.ssl.Socket)
class NekoTlsSocket extends sys.ssl.Socket {
	public override function accept():sys.ssl.Socket {
		var accepted:sys.ssl.Socket = super.accept();
		try {
			// buildSSLContext puts the server-name callback it makes in a
			// field, and the listener's own configuration still calls the one
			// there now.
			var listenersCallback:Dynamic = sniCallback;
			var conf = buildSSLContext(true);
			accepted.sniCallback = sniCallback;
			sniCallback = listenersCallback;

			// accept() set the connection up on the listener's configuration;
			// nothing has been sent on it yet.
			sys.ssl.Socket.ssl_close(accepted.ssl);
			accepted.ssl = null;
			accepted.ssl = sys.ssl.Socket.ssl_new(conf);
			sys.ssl.Socket.ssl_set_socket(accepted.ssl, accepted.__s);
			accepted.ctx = conf;

			// What the configuration points at, kept as long as it is.
			accepted.ownCert = ownCert;
			accepted.ownKey = ownKey;
			accepted.altSNIContexts = altSNIContexts;
		} catch (e:Dynamic) {
			try {
				accepted.close();
			} catch (_:Dynamic) {}
			neko.Lib.rethrow(e);
		}
		return accepted;
	}
}
#end
