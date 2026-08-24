package crossbyte._internal.socket;

#if cpp
import sys.ssl.Socket as SSLSocket;

/**
 * A `sys.ssl.Socket` that can negotiate an application protocol over TLS.
 *
 * ALPN is what makes `h2` reachable: an HTTPS client has to advertise it
 * during the handshake, because there is no in-band upgrade to HTTP/2 on a
 * TLS connection the way `h2c` upgrades a cleartext one.
 *
 * The std class builds its SSL config inside `connect()` and `bind()` and
 * hands it straight to the handshake, so there is no window in which a caller
 * could configure it. Overriding `buildSSLConfig` is that window -- and it is
 * why this is a subclass rather than a shadow of `sys.ssl.Socket` under
 * `src/sys/ssl/`: a shadow would have to be re-copied from `_std` on every
 * Haxe release, and stubbed for the five targets that do not use the cpp
 * implementation. This adds one hook and inherits the rest.
 *
 * Client:
 * ```haxe
 * var socket = new AlpnSocket();
 * socket.setALPN(["h2", "http/1.1"]);
 * socket.connect(new Host("example.com"), 443);
 * trace(socket.getALPN()); // "h2"
 * ```
 *
 * Server: call `setALPN` before `bind()`. Sockets returned by `accept()` are
 * plain `sys.ssl.Socket` instances created by the std implementation, so read
 * their negotiated protocol with `AlpnSocket.negotiated(accepted)`.
 */
class AlpnSocket extends SSLSocket {
	@:noCompletion private var __alpn:Null<Array<String>>;

	public function new() {
		super();
	}

	/**
	 * Advertises `protocols` on the next handshake, most preferred first.
	 *
	 * Has no effect once the config exists, so call this before `connect()` on
	 * a client or before `bind()` on a server. Passing `null` or an empty
	 * array disables ALPN.
	 */
	public function setALPN(protocols:Null<Array<String>>):Void {
		__alpn = protocols;
	}

	/**
	 * The protocol agreed during this socket's handshake, or `null` if the
	 * handshake has not completed or the peer negotiated nothing.
	 *
	 * `connect()` completes the handshake on a blocking socket, so the result
	 * is available as soon as it returns. A non-blocking socket reports `null`
	 * until a retried `handshake()` stops throwing `Blocked`.
	 */
	public function getALPN():Null<String> {
		return negotiated(this);
	}

	/**
	 * The protocol agreed on any `sys.ssl.Socket`, including one returned by
	 * `accept()`, which the std implementation builds as a bare
	 * `sys.ssl.Socket` rather than as this subclass.
	 */
	public static function negotiated(socket:SSLSocket):Null<String> {
		if (socket == null) {
			return null;
		}

		var context:Dynamic = @:privateAccess socket.ssl;
		return context == null ? null : NativeAlpn.get_alpn(context);
	}

	@:noCompletion private override function buildSSLConfig(server:Bool):Dynamic {
		var conf:Dynamic = super.buildSSLConfig(server);

		if (__alpn != null && __alpn.length > 0) {
			NativeAlpn.conf_set_alpn(conf, __alpn);
		}

		return conf;
	}
}
#end
