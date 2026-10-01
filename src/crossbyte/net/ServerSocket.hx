package crossbyte.net;

// Not built for the browser. A page cannot listen for inbound connections; there is no API for it and no port to bind. Run a server on Node or a native target.
#if !(js && !nodejs)

import haxe.Timer;
import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import haxe.io.Error;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import crossbyte.errors.Error as CBError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.Socket as CBSocket;
import crossbyte.io.ByteArray;
#if nodejs
import js.node.Net;
import js.node.Tls;
import js.node.net.Server as NodeServer;
import js.node.net.Socket as NodeSocket;
#else
import crossbyte._internal.socket.IPollableSocket;
import sys.net.Host;
import sys.net.Socket;
#if (java || jvm)
import crossbyte._internal.socket._jvm.JvmSsl.JvmSslSocket as SSLSocket;
#else
import sys.ssl.Socket as SSLSocket;
#end
#if cpp
import crossbyte._internal.socket.AlpnSocket;
#end
#end

/**
	The ServerSocket class allows code to act as a server for Transport Control Protocol (TCP)
	connections.
	This feature is supported on all desktop operating systems, on iOS, and on Android.
	This feature is not supported on html5. You can test for support at run time using the
	ServerSocket.isSupported property.
	A TCP server listens for incoming connections from remote clients. When a client attempts
	to connect, the ServerSocket dispatches a connect event. The ServerSocketConnectEvent object
	dispatched for the event provides a Socket object representing the TCP connection between the
	server and the client. Use this Socket object for subsequent communication with the connected
	client. You can get the client address and port from the Socket object, if needed.
	Note: Your application is responsible for maintaining a reference to the client Socket object.
	If you don't, the object is eligible for garbage collection and may be destroyed by the runtime
	without warning.
	To put a ServerSocket object into the listening state, call the listen() method. In the
	listening state, the server socket object dispatches connect events whenever a client using the
	TCP protocol attempts to connect to the bound address and port. The ServerSocket object
	continues to listen for additional connections until you call the close() method.
	TCP connections are persistent — they exist until one side of the connection closes it (or a
	serious network failure occurs). Any data sent over the connection is broken into transmittable
	packets and reassembled on the other end. All packets are guaranteed to arrive (within reason) —
	any lost packets are retransmitted. In general, the TCP protocol manages the available network
	bandwidth better than the UDP protocol. Most applications that require socket communications
	should use the ServerSocket and Socket classes rather than the DatagramSocket class.
	The ServerSocket class can only be used in targets that support TCP.
	@event close    Dispatched when the operating system closes this socket.
	@event connect  Dispatched when a remote socket seeks to connect to this server socket.
**/
// @:fileXml('tags="haxe,release"')
// @:noDebug
@:access(crossbyte.net.Socket)
class ServerSocket extends EventDispatcher {
	/**
		Indicates whether the socket is bound to a local address and port.
	**/
	public var bound(default, null):Bool;

	/**
		Indicates whether or not ServerSocket features are supported in the run-time environment.
	**/
	public static var isSupported(default, null):Bool = #if !html5 true #else false #end;

	/**
		Whether `setALPN()` reaches the TLS handshake on this target.

		ALPN rides on hxcpp's mbedTLS natively and on Node's own TLS stack.
		Elsewhere `setALPN()` is accepted and ignored, so a server can offer
		`h2` unconditionally and simply keep serving HTTP/1.1 where the
		handshake cannot advertise it.
	**/
	public static var alpnSupported(default, null):Bool = #if (cpp || nodejs || java || jvm) true #else false #end;

	/**
		Indicates whether the server socket is listening for incoming connections.
	**/
	public var listening(default, null):Bool;

	/**
		The IP address on which the socket is listening.
	**/
	public var localAddress(default, null):String;

	/**
		The port on which the socket is listening.
	**/
	public var localPort(default, null):Int;

	/**
		Indicates whether this server terminates TLS for accepted connections.
	**/
	public var secure(default, null):Bool;

	/**
		Maximum seconds an accepted TLS connection may spend completing its
		handshake before the server drops it. Guards against clients that
		open a connection and then stall, which would otherwise accumulate
		half-open sockets.
	**/
	public var handshakeTimeout:Float = 10.0;

	/**
		Most connections taken from the listen queue each time the listener is
		found to have some waiting.

		The listener sits in the runtime's poll set, so connections are taken
		as they arrive rather than at the next tick. The operating system holds
		connections that have finished their TCP handshake in the listen queue
		until they are accepted -- 200 of them on a client edition of Windows,
		128 to 4096 on Linux -- and refuses any that arrive while it is full.
		Taking one a tick, as this server used to, spent 190 ticks clearing 190
		waiting connections, and a login burst larger than the queue was
		refused by the kernel before the server saw it. The cap keeps one wake
		from being spent entirely on arrivals: what is left is taken at the
		next.

		Node accepts as connections arrive, so it has no use for this.
	**/
	public var maxAcceptsPerTick:Int = 64;

	/**
		TLS handshakes allowed in flight at once. At the limit the server stops
		taking connections from the listen queue until some finish, which leaves
		the rest waiting in the kernel rather than costing a handshake each.
		Negative disables the check.

		A connection that never sends its half of the handshake costs a socket
		for `handshakeTimeout` seconds, and draining the queue quickly is what
		would otherwise let a flood of them pile up.

		Always inert on Node, which completes its own handshakes.
	**/
	public var maxPendingHandshakes:Int = 256;

	/**
		Connections this server failed to take from the listen queue, for a
		reason other than there being none to take: the process out of
		descriptors (`EMFILE`), the system out of memory. The server goes on
		listening and trying; the connection waits in the kernel's queue
		meanwhile.

		The first failure after a success is also dispatched as an `ioError`
		event, so a run of them is reported once rather than every tick. Each
		used to be swallowed natively -- no event, no count, and a server out
		of descriptors looked idle -- or, on the jvm, closed the server.
	**/
	public var acceptFailures(default, null):Int = 0;

	/**
		TLS handshakes that failed, or were given up on at `handshakeTimeout`,
		and so never became a `connect` event. Counted rather than reported one
		by one: an open port sees a steady trickle of them from scanners and
		broken clients, and each used to be dropped without a trace. Always 0
		on a plain server.
	**/
	public var handshakeFailures(default, null):Int = 0;

	/**
		Decides, from the peer's address alone, whether a connection is taken
		at all. Called as soon as it is accepted -- before any TLS handshake,
		before a `Socket` is built for it, before a `connect` event -- so a
		refusal costs almost nothing. Return `false` and the connection is
		closed on the spot. The default admits everything.

		The address is canonical, as `Socket.remoteAddress` reports it, so a
		list written against it on one target matches on every other.

		What to decide with is the application's: a block list, a
		`RateLimiter` keyed by address, a count of connections per address,
		`ConcurrencyLimiter.available` while the server is saturated. A hook
		that throws refuses the connection.
	**/
	public dynamic function admit(address:String, port:Int):Bool {
		return true;
	}

	/**
		The backlog `listen()` asks for when given none: more than any system
		grants, so the system's own maximum is what applies -- 200 on a client
		edition of Windows, `somaxconn` on Linux, whichever value is asked.
		`0x7FFFFFF` rather than the largest Int, which neko's 31-bit integers
		cannot carry: `listen()` threw there, so no server could start.
	**/
	@:noCompletion private static inline var DEFAULT_BACKLOG:Int = 0x7FFFFFF;

	@:noCompletion private var __serverSocket:#if nodejs NodeServer #else Socket #end;
	@:noCompletion private var __closed:Bool;
	@:noCompletion private var __cbInstance:CrossByte;
	@:noCompletion private var __hasListener:Bool = false;
	#if !nodejs
	// The accept tick, as one closure kept: on eval two reads of
	// `this_onTick` do not compare equal, so removing a fresh one removed
	// nothing.
	@:noCompletion private var __acceptTick:TickEvent->Void = null;
	// The runtime the accept tick is attached to, or null while it is not.
	// One attachment however many paths ask: the runtime's dispatcher keeps
	// every add, and each remove takes one away.
	@:noCompletion private var __tickRuntime:CrossByte = null;
	// The runtime this server is accepting on, or null while it is not.
	@:noCompletion private var __acceptRuntime:CrossByte = null;
	// The runtime whose poll set the listener is in, or null while it is
	// not: guarded the same way, so it is registered once and removed once.
	@:noCompletion private var __pollRuntime:CrossByte = null;
	// What the poll set calls when the listener has connections waiting.
	@:noCompletion private var __listenerPoll:ListenerPoll = null;
	// Whether the last accept failed, so a run of failures is reported once.
	@:noCompletion private var __acceptFailing:Bool = false;
	#end
	@:noCompletion private var __hasCertificate:Bool = false;
	#if !nodejs
	@:noCompletion private var __pendingHandshakes:Array<PendingHandshake>;
	#end
	@:noCompletion private var __listenerReleased:Bool = false;
	#if nodejs
	// Collected as it arrives and handed to tls.createServer in listen(),
	// because that is the moment Node will take it.
	@:noCompletion private var __tlsCertificate:Certificate;
	@:noCompletion private var __tlsKey:Key;
	@:noCompletion private var __tlsAuthority:Certificate;
	@:noCompletion private var __tlsSni:Array<{match:String->Bool, certificate:Certificate, key:Key}> = [];
	@:noCompletion private var __tlsAlpn:Array<String>;
	#end

	/**
		Creates a ServerSocket object.

		@param secure When `true`, the server terminates TLS: a certificate
			must be installed with `setCertificate()` before `listen()`, and
			`connect` events are dispatched only after each client's handshake
			completes. Handshakes progress across ticks and never block the
			runtime loop.
		@throws  Error On the eval target, when `secure` is true: eval's `sys.ssl.Socket`
				cannot install a certificate, so a TLS server there is refused at construction
				rather than several calls later.
	**/
	public function new(secure:Bool = false) {
		super();

		#if eval
		if (secure) {
			// eval's sys.ssl.Socket implements setCertificate and
			// addSNICertificate as stubs that throw, so a TLS server there
			// cannot present a certificate and never could. Refused here, at
			// construction, rather than several calls later from inside the
			// standard library with a bare "Not implemented" and no hint that
			// the target is the reason.
			throw new CBError("Secure ServerSocket is not supported on the eval target: sys.ssl.Socket cannot install a certificate there.");
		}
		#end

		this.secure = secure;
		#if !nodejs
		__pendingHandshakes = [];
		#end

		__init();
	}

	private function __init():Void {
		#if nodejs
		// Nothing is built here. A Node TLS server takes its key, certificate,
		// CA and SNI callback when it is created, and every one of those
		// arrives after this through setCertificate(), requireClientCertificate()
		// and addSNICertificate(). So the server is made in listen(), which is
		// the same instant the native path calls "the point TLS configuration
		// is materialized" -- it just has to be literal about it here.
		__serverSocket = null;
		__closed = false;
		bound = false;
		listening = false;
		#else
		#if (java || jvm)
		// JvmSslSocket extends sys.net.Socket, so the accept and select paths
		// below do not care which of the two this is -- the same arrangement
		// sys.ssl.Socket gives every other sys target.
		__serverSocket = secure ? new SSLSocket() : new sys.net.Socket();

		if (secure) {
			// As natively, below: a server asks for client certificates only
			// once requireClientCertificate() says to. Left unset it followed
			// DEFAULT_VERIFY_CERT, which is for the connections an application
			// makes -- so turning that on made the server refuse every client
			// that had no certificate, which is every browser.
			(cast __serverSocket : SSLSocket).verifyCert = false;
		}
		#else
		// sys.ssl.Socket extends sys.net.Socket, so the accept/select paths
		// below are identical for both modes.
		#if cpp
		// AlpnSocket only adds a hook to buildSSLConfig; until setALPN() is
		// called it is an ordinary SSLSocket.
		__serverSocket = secure ? new AlpnSocket() : new sys.net.Socket();
		#else
		__serverSocket = secure ? new SSLSocket() : new sys.net.Socket();
		#end

		if (secure) {
			// sys.ssl.Socket leaves verifyCert null, which the stdlib maps to
			// mbedTLS VERIFY_REQUIRED. On a *server* config that demands a
			// client certificate, so every ordinary HTTPS client would fail
			// the handshake. Servers request client certificates only when
			// mTLS is explicitly enabled via requireClientCertificate().
			(cast __serverSocket : SSLSocket).verifyCert = false;
		}
		#end
		__serverSocket.setBlocking(false);
		__serverSocket.setFastSend(true);
		__closed = false;
		bound = false;
		listening = false;
		#end
	}

	/**
		Installs the certificate chain and private key this server presents to
		clients. Must be called on a secure server before `listen()`.

		@param cert The certificate chain to present.
		@param key The matching private key.
		@throws Error When this server was not constructed with `secure` set.
	**/
	public function setCertificate(cert:Certificate, key:Key):Void {
		__requireSecure("setCertificate");

		#if nodejs
		__tlsCertificate = cert;
		__tlsKey = key;
		#else
		(cast __serverSocket : SSLSocket).setCertificate(cert.__native, key.__native);
		#end
		__hasCertificate = true;
	}

	/**
		Adds an additional certificate selected by Server Name Indication,
		allowing one listener to serve several hostnames.

		@param serverNameMatch Predicate matching the client-offered hostname.
		@param cert The certificate chain to present on a match.
		@param key The matching private key.
	**/
	public function addSNICertificate(serverNameMatch:String->Bool, cert:Certificate, key:Key):Void {
		__requireSecure("addSNICertificate");

		#if nodejs
		__tlsSni.push({match: serverNameMatch, certificate: cert, key: key});
		#else
		(cast __serverSocket : SSLSocket).addSNICertificate(serverNameMatch, cert.__native, key.__native);
		#end
		__hasCertificate = true;
	}

	/**
		Requires connecting clients to present a certificate signed by `ca`
		(mutual TLS). Clients that present no certificate, or one outside this
		chain of trust, fail the handshake and are dropped before any
		`connect` event is dispatched.

		Must be called before `bind()`: the TLS configuration is materialized
		at bind time.

		@param ca The certificate authority that must have signed client
			certificates.
	**/
	public function requireClientCertificate(ca:Certificate):Void {
		__requireSecure("requireClientCertificate");

		if (ca == null) {
			throw new CBError("requireClientCertificate requires a certificate authority.");
		}
		if (bound) {
			throw new CBError("requireClientCertificate must be called before bind().");
		}

		#if nodejs
		__tlsAuthority = ca;
		#else
		var sslSocket:SSLSocket = cast __serverSocket;
		sslSocket.setCA(ca.__native);
		sslSocket.verifyCert = true;
		#end
	}

	/**
		Advertises `protocols` to connecting clients during the TLS handshake,
		in descending order of preference.

		Server preference wins: a client offering `["http/1.1", "h2"]` against a
		server offering `["h2", "http/1.1"]` negotiates `h2`. Read the result
		for a given client from `Socket.alpnProtocol` on the socket carried by
		the `connect` event.

		Must be called before `bind()`: the TLS configuration is materialized
		at bind time. Does nothing when `alpnSupported` is `false`.

		@param protocols Protocol names such as `["h2", "http/1.1"]`. Passing
			`null` or an empty array disables ALPN.
		@throws Error When this server was not constructed with `secure` set,
			or when it is already bound.
	**/
	public function setALPN(protocols:Null<Array<String>>):Void {
		__requireSecure("setALPN");

		#if nodejs
		__tlsAlpn = protocols;
		#elseif cpp
		(cast __serverSocket : AlpnSocket).setALPN(protocols);
		#elseif (java || jvm)
		(cast __serverSocket : SSLSocket).setALPN(protocols);
		#end
	}

	@:noCompletion private function __requireSecure(field:String):Void {
		if (!secure) {
			throw new CBError('$field is only available on a ServerSocket constructed with secure = true.');
		}
		// The underlying TLS configuration is materialized during bind(), so
		// installing material afterwards would silently have no effect.
		if (bound || listening) {
			throw new CBError('$field must be called before bind().');
		}
	}

	/**
		Binds this socket to the specified local address and port.
		@param localPort 	(default = 0) The number of the port to bind to on the local computer.
							If localPort, is set to 0 (the default), the next available system port is bound. Permission
							to connect to a port number below 1024 is subject to the system security policy. On Mac and
							Linux systems, for example, the application must be running with root privileges to connect
							to ports below 1024.
		@param localAddress (default = "0.0.0.0") The IP address on the local machine to bind
							to. This address can be an IPv4 or IPv6 address. If localAddress is set to 0.0.0.0 (the
							default), the socket listens on all available IPv4 addresses. To listen on all available IPv6
							addresses, you must specify "::" as the localAddress argument. To use an IPv6 address, the
							computer and network must both be configured to support IPv6. Furthermore, a socket bound to
							an IPv4 address cannot connect to a socket with an IPv6 address. Likewise, a socket bound to
							an IPv6 address cannot connect to a socket with an IPv4 address. The type of address must
							match.
		@throws RangeError    This error occurs when localPort is less than 0 or greater than 65535.
		@throws ArgumentError This error occurs when localAddress is not a syntactically well-formed IP address.
		@throws IOError 	  When the socket cannot be bound, such as when:
							  the underlying network socket (IP and port) is already in bound by another object or process.
							  the application is running under a user account that does not have the privileges necessary to bind to the port. Privilege issues typically occur when attempting to bind to well known ports (localPort < 1024)
							  this ServerSocket object is already bound. (Call close() before binding to a different socket.)
							  when localAddress is not a valid local address.
	**/
	public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (localPort > 65535 || localPort < 0) {
			throw new RangeError("Invalid socket port number specified.");
		}

		#if nodejs
		// Node has no bind that is separate from listening: a server takes its
		// address when it starts, and reports a refusal -- a port in use, an
		// address that is not local -- as an event once it has tried. So this
		// records the endpoint and listen() is where it is claimed, which means
		// two visible differences on Node: a bind failure arrives as a close
		// event rather than out of this call, and a port of 0 stays 0 in
		// localPort until listen() has been able to ask what was assigned.
		this.localAddress = localAddress;
		this.localPort = localPort;
		bound = true;
		#else
		try {
			var host:Host = new Host(localAddress);
			__serverSocket.bind(host, localPort);

			this.localAddress = localAddress;
			this.localPort = localPort == 0 ? __serverSocket.host().port : localPort;
			bound = true;
		} catch (e:Dynamic) {
			// Std.string rather than a bare switch on the value, and a
			// default that throws: the two cases listed here used to be the
			// only ones handled, so any other failure fell straight through
			// and bind() returned as though it had worked, leaving the
			// caller to listen on a socket that was never bound.
			switch (Std.string(e)) {
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
				default:
					// "Bind failed" included. The socket is not what was
					// invalid -- the address or the port would not take.
					throw new IOError("Could not bind to " + localAddress + ":" + localPort + ": " + Std.string(e));
			}
		}
		#end
	}

	/**
		Closes the socket and stops listening for connections.
		Closed sockets cannot be reopened. Create a new ServerSocket instance instead.
		@throws Error This error occurs if the socket could not be closed, or the socket was not open.
	**/
	#if nodejs
	/**
	 * Builds the listener, plain or TLS, and wires what both need.
	 *
	 * `tls.Server` extends `net.Server`, so from here on the two are the same
	 * object to the rest of this class -- listen, close, address and the error
	 * event are all inherited. The only thing that differs is what was handed
	 * to the constructor.
	 */
	@:noCompletion private function __makeNodeServer():Void {
		if (__serverSocket != null) {
			return;
		}

		var accept = function(connection:NodeSocket):Void {
			if (!__hasListener) {
				// Node has already accepted this; there is no way to tell it
				// not to, the way a native server leaves a connection sitting
				// in the backlog it never calls accept() on. With nobody
				// listening for `connect` the socket would be handed to no one
				// and stay open, holding a descriptor and Node's event loop
				// with it, so it is refused here instead of leaked.
				connection.destroy();
				return;
			}

			// A TLS server asks on its raw `connection` event instead, below,
			// before a handshake is spent; by the time this runs, one has been.
			if (!secure && !__nodeAdmits(connection)) {
				connection.destroy();
				return;
			}

			var socket:CBSocket = @:privateAccess CBSocket.__adoptNodeSocket(connection, __cbInstance);
			// Said, as a native server's accepted socket says it: on Node one
			// a TLS listener accepted reported false.
			socket.secure = secure;

			// Contained: this runs from Node's event loop, and a connect
			// listener that threw ended the process -- every connection the
			// server held, for a fault in handling one.
			try {
				dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
			} catch (e:Dynamic) {
				CrossByte.__socketListenerThrew(e, socket, 'A "connect" listener threw, and the connection it was handling was closed');
				try {
					socket.close();
				} catch (_:Dynamic) {}
			}
		};

		if (secure) {
			var options:Dynamic = {key: __tlsKey.__pem, cert: __tlsCertificate.__pem};

			if (__tlsKey.__passphrase != null) {
				options.passphrase = __tlsKey.__passphrase;
			}

			if (__tlsAuthority != null) {
				// Both flags, deliberately. requestCert on its own asks for a
				// certificate and then accepts a client that declines to send
				// one, which is not what requireClientCertificate() promises.
				options.ca = [__tlsAuthority.__pem];
				options.requestCert = true;
				options.rejectUnauthorized = true;
			}

			if (__tlsAlpn != null && __tlsAlpn.length > 0) {
				options.ALPNProtocols = __tlsAlpn;
			}

			if (__tlsSni.length > 0) {
				// Each name's context made once, here, with its key's
				// passphrase. It was made at every handshake for the name,
				// without the passphrase: an encrypted key -- which the default
				// certificate's could be -- failed every handshake that asked
				// for its name, and an unencrypted one was parsed again for
				// each. A key or certificate Node cannot read now throws from
				// listen(), as the default certificate's does.
				var sni:Array<{match:String->Bool, context:Dynamic}> = [];
				for (entry in __tlsSni) {
					var material:Dynamic = {key: entry.key.__pem, cert: entry.certificate.__pem};
					if (entry.key.__passphrase != null) {
						material.passphrase = entry.key.__passphrase;
					}
					sni.push({match: entry.match, context: Tls.createSecureContext(material)});
				}
				options.SNICallback = function(servername:String, callback:Dynamic):Void {
					for (entry in sni) {
						var matched:Bool = try entry.match(servername) catch (_:Dynamic) false;
						if (matched) {
							callback(null, entry.context);
							return;
						}
					}

					// An unmatched name is not a failure: the connection falls
					// back to the default certificate, which is what a native
					// server does with one too.
					callback(null, null);
				};
			}

			// Half-open, so a peer's FIN is the accepted socket's to act on,
			// by its peerShutdownPolicy, rather than Node's to answer with its
			// own.
			options.allowHalfOpen = true;
			__serverSocket = Tls.createServer(options, accept);

			// The raw TCP connection, before TLS starts on it: the point where
			// a refusal still costs nothing.
			__serverSocket.on("connection", function(raw:NodeSocket):Void {
				if (!__nodeAdmits(raw)) {
					raw.destroy();
				}
			});

			// A handshake that failed, which Node reports here and nowhere
			// else. Counted, as natively, and the connection let go.
			__serverSocket.on("tlsClientError", function(_:Dynamic, raw:NodeSocket):Void {
				handshakeFailures++;
				try {
					raw.destroy();
				} catch (_:Dynamic) {}
			});
		} else {
			__serverSocket = Net.createServer({allowHalfOpen: true}, accept);
		}

		// A port already in use, or an address that is not local, reaches a
		// Node server as an event rather than as a failed call -- see bind().
		__serverSocket.on("error", function(_):Void {
			if (__closed) {
				return;
			}

			close();
			dispatchEvent(new Event(Event.CLOSE));
		});
	}

	/**
		Asks `admit` about a connection Node has just accepted. A hook that
		throws, or a socket already gone, is a refusal.
	**/
	@:noCompletion private function __nodeAdmits(connection:NodeSocket):Bool {
		try {
			return admit(crossbyte._internal.net.IPv6.compress(connection.remoteAddress), connection.remotePort);
		} catch (_:Dynamic) {
			return false;
		}
	}
	#end

	public function close():Void {
		#if !nodejs
		__dropPendingHandshakes();
		// Out of the poll set before the listener is closed; see
		// Socket.__cleanSocket.
		__detachAcceptTick();
		#end

		// stopAccepting() may already have released the listening socket as
		// the first half of a graceful shutdown; closing it again is not an
		// error.
		if (!__listenerReleased) {
			try {
				__serverSocket.close();
			} catch (e:Dynamic) {
				throw new CBError("The listening socket could not be closed: " + Std.string(e));
			}
		}
		listening = false;
		bound = false;
		__closed = true;
		__cbInstance = null;
	}

	/**
		 Initiates listening for TCP connections on the bound IP address and port.
		The listen() method returns immediately. Once you call listen(), the ServerSocket
		object dispatches a connect event whenever a connection attempt is made. The socket
		property of the ServerSocketConnectEvent event object references a Socket object
		representing the server-client connection.
		The backlog parameter specifies how many pending connections are queued while the
		connect events are processed by your application. If the queue is full, additional
		connections are denied without a connect event being dispatched. If the default
		value of zero is specified, then the system-maximum queue length is used. This
		length varies by platform and can be configured per computer. If the specified
		value exceeds the system-maximum length, then the system-maximum length is used
		instead. No means for discovering the actual backlog value is provided. (The
		system-maximum value is determined by the SOMAXCONN setting of the TCP network
		subsystem on the host computer.)
		@throws RangeError	There is insufficient data available to read.
		@throws IOError		This error occurs if the socket is not open or bound.
							This error also occurs if the call to listen() fails for any
							other reason.
	**/
	public function listen(backlog:Int = 0):Void {
		__cbInstance = CrossByte.current();
		if (__cbInstance == null) {
			throw "ServerSocket can only be initiated in a CrossByte threaded instance";
		} else {
			if (__closed) {
				throw new IOError("Operation attempted on invalid socket.");
			}
			if (secure && !__hasCertificate) {
				throw new IOError("A secure ServerSocket requires setCertificate() before bind().");
			}
			if (backlog < 0) {
				throw new RangeError("The supplied index is out of bounds.");
			} else if (backlog == 0) {
				backlog = DEFAULT_BACKLOG;
			}

			#if nodejs
			if (!bound) {
				throw new IOError("Operation attempted on invalid socket.");
			}

			__makeNodeServer();
			__serverSocket.listen({port: localPort, host: localAddress, backlog: backlog}, function():Void {
				// Where a port of 0 becomes the port the operating system
				// picked. It cannot be known earlier: bind() only wrote the
				// request down, and nothing had asked for a port yet.
				var assigned:Dynamic = __serverSocket.address();

				if (assigned != null && assigned.port != null) {
					localPort = assigned.port;
				}
			});

			listening = true;
			#else
			__serverSocket.listen(backlog);
			/* @:privateAccess
				__cbInstance.beginSocketPolling();
				@:privateAccess
				__cbInstance.registerSocket(__serverSocket); */
			listening = true;
			if (__hasListener) {
				__attachAcceptTick();
			}
			#end
		}
	}

	#if !nodejs
	@:noCompletion private function __fromSocket(socket:sys.net.Socket):CBSocket {
		socket.setFastSend(true);
		socket.setBlocking(false);

		var cbSocket = new CBSocket();
		cbSocket.__socket = socket;
		cbSocket.__connected = true;

		// A peer accepted by a TLS listener is a TLS connection, and until now
		// nothing said so: `secure` was set only by the browser constructor, so
		// every server-side socket reported false regardless of what it was
		// carrying. Read by `registryHasBufferedInput`, which has to know
		// whether asking the TLS layer about buffered bytes is even meaningful.
		cbSocket.secure = secure;
		cbSocket.__timestamp = haxe.Timer.stamp();

		// Canonical for the same reason `Socket.localAddress` is: a peer
		// address that reads differently per target is one a whitelist written
		// on one of them silently fails to match on another.
		cbSocket.__host = crossbyte._internal.net.IPv6.compress(socket.peer().host.toString());
		cbSocket.__port = socket.peer().port;

		cbSocket.__output = new ByteArray();
		cbSocket.__output.endian = cbSocket.__endian;

		cbSocket.__input = new ByteArray();
		cbSocket.__input.endian = cbSocket.__endian;

		cbSocket.__cbInstance = __cbInstance;

		// No CLOSE is scheduled from here. One was, a tick on, for a socket no
		// longer connected by then -- and every way a socket stops being
		// connected announces CLOSE itself, so a peer that connected and hung
		// up within a tick, a load balancer's health check, was announced
		// closed twice: onDisconnect ran twice, and a live-connection count
		// fell by two for every one that went.

		socket.custom = cbSocket;

		@:privateAccess
		__cbInstance.registerSocket(socket);

		return cbSocket;
	}

	/**
		The tick a TLS server keeps: every handshake in flight is stepped once
		a tick, which ends one that has run past `handshakeTimeout` and
		finishes one whose next step the poll set cannot report -- a flight
		this side could not write all at once.

		Connections are not taken here. They were, and only here, so a server
		accepted once a tick however it was polled: 41 to 57 ms from connect
		to accept at twelve ticks a second, whatever the backend. The listener
		is in the poll set now and is read when connections are waiting, and a
		plain server has no tick at all.
	**/
	@:noCompletion private function this_onTick(e:TickEvent):Void {
		__pumpHandshakes();
	}

	/**
		The listener has connections waiting: as many as `maxAcceptsPerTick`
		are taken, and the handshakes of those that need one begin at once.
	**/
	@:noCompletion private function __onListenerReadable():Void {
		var started:Int = __pendingHandshakes == null ? 0 : __pendingHandshakes.length;
		var limit:Int = maxAcceptsPerTick < 1 ? 1 : maxAcceptsPerTick;
		for (_ in 0...limit) {
			if (!__acceptOne()) {
				break;
			}
		}

		// Once for the lot rather than once per arrival: a pump steps every
		// handshake in flight, and there may be hundreds.
		if (__pendingHandshakes != null && __pendingHandshakes.length > started) {
			__pumpHandshakes();
		}
		__syncListenerWatch();
	}

	/**
		Takes one connection from the listen queue, if one is waiting and there
		is room for it. Answers whether it is worth looking for another.
	**/
	@:noCompletion private function __acceptOne():Bool {
		try {
			if (__serverSocket == null || !listening) {
				return false;
			}
			// Full: the rest wait in the kernel's queue, costing nothing here.
			if (__handshakesFull()) {
				return false;
			}
			// Asked even though the poll said so: this is called again for
			// the next connection until none is left, and on eval, whose
			// sockets block, an accept with none waiting would wait for one.
			var ready = Socket.select([__serverSocket], [], [], 0);
			if (ready.read.length == 0 || ready.read[0] != __serverSocket) {
				return false;
			}

			var sysSocket:Socket = null;
			try {
				sysSocket = __takeConnection();
			} catch (e:Dynamic) {
				if (!__isBlockedError(e)) {
					__onAcceptFailed(e);
				}
				return false;
			}
			__acceptFailing = false;

			if (!__admits(sysSocket)) {
				return true;
			}

			if (secure) {
				// Defer the connect event: the peer is not authenticated (and
				// no application bytes are readable) until TLS completes.
				sysSocket.setBlocking(false);
				var pending:PendingHandshake = new PendingHandshake(this, sysSocket, haxe.Timer.stamp() + handshakeTimeout);
				__pendingHandshakes.push(pending);

				// In the poll set, so each flight the peer sends steps the
				// handshake as it lands. Stepped only by the tick, a handshake
				// waited up to a tick per round trip: a median of 132 ms to
				// secureConnect on the jvm at twelve ticks a second.
				sysSocket.custom = pending;
				if (__cbInstance != null) {
					pending.runtime = __cbInstance;
					@:privateAccess
					__cbInstance.registerSocket(sysSocket);
				}
				return true;
			}

			var socket:CBSocket = __fromSocket(sysSocket);
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
			return true;
		} catch (e:Error) {
			if (!__isBlockedError(e)) {
				close();
				dispatchEvent(new Event(Event.CLOSE));
			}
		} catch (e:Dynamic) {
			// Do nothing.
		}
		return false;
	}

	/** Takes one connection from the listen queue. **/
	@:noCompletion private function __takeConnection():Socket {
		return __serverSocket.accept();
	}

	/**
		A connection the system would not hand over, though one was waiting:
		counted, and reported once for a run of them. The server stays up. The
		connection stays in the kernel's queue and is asked for again next
		tick, which is all there is to do about a process out of descriptors.

		hxcpp raises this as a bare string, which the catch-all here swallowed
		without a word; the jvm raises it as an I/O error, which closed the
		server -- over a condition that passes as soon as a descriptor frees.
	**/
	@:noCompletion private function __onAcceptFailed(error:Dynamic):Void {
		acceptFailures++;

		if (__acceptFailing) {
			return;
		}
		__acceptFailing = true;

		var message:String = "Could not accept a connection waiting on port " + localPort + ": " + Std.string(error)
			+ ". The server is still listening, and takes it once the system will hand it over.";
		crossbyte.utils.Logger.warn(message);
		dispatchEvent(new crossbyte.events.IOErrorEvent(crossbyte.events.IOErrorEvent.IO_ERROR, message));
	}

	/**
		Asks `admit` about a connection just accepted, and closes it if the
		answer is no -- or if asking threw.
	**/
	@:noCompletion private function __admits(sysSocket:Socket):Bool {
		var admitted:Bool = false;
		try {
			var peer = sysSocket.peer();
			admitted = admit(crossbyte._internal.net.IPv6.compress(peer.host.toString()), peer.port);
		} catch (_:Dynamic) {
			admitted = false;
		}

		if (!admitted) {
			try {
				sysSocket.close();
			} catch (_:Dynamic) {}
		}
		return admitted;
	}

	#end

	override public function addEventListener(type:String, listener:Dynamic->Void, priority:Int = 0):Void {
		super.addEventListener(type, listener, priority);

		if (type == Event.CONNECT) {
			__hasListener = true;
			#if !nodejs
			if (listening) {
				__attachAcceptTick();
			}
			#end
		}
	}

	override public function removeEventListener(type:String, listener:Dynamic->Void):Void {
		super.removeEventListener(type, listener);

		// Only once the last one goes. Removing any one used to stop the
		// server accepting, though others were still listening for what it
		// accepted -- one part of an application unsubscribing silenced it
		// for the rest.
		if (type == Event.CONNECT && !hasEventListener(Event.CONNECT)) {
			__hasListener = false;
			#if !nodejs
			__detachAcceptTick();
			#end
		}
	}

	#if !nodejs
	/** The accept tick, the same closure every time; see __acceptTick. **/
	@:noCompletion private inline function __onAcceptTick():TickEvent->Void {
		if (__acceptTick == null) {
			__acceptTick = this_onTick;
		}
		return __acceptTick;
	}

	/**
		Starts accepting, unless it has started already: the listener joins
		the runtime's poll set, and the accept tick goes on the runtime where
		this server needs one.

		Every path that wants it running comes here -- `listen()` with a
		`connect` listener, a `connect` listener added while listening, and
		`ServerWebSocket` -- and each used to add the tick again. The runtime's
		dispatcher keeps every add and each remove takes out one, so a server
		given its listener after `listen()` held two and closing it removed
		one: the other ran on for good, calling `accept()` on the closed
		listener every frame and keeping the server alive. Natively each of
		those accepts fails on the closed socket. eval keeps a closed socket's
		descriptor number and cannot make a socket non-blocking, so there the
		accept landed on whichever socket took that number next, and waited
		for a connection on it, stopping the runtime.
	**/
	@:noCompletion private function __attachAcceptTick():Void {
		if (__acceptRuntime != null || __cbInstance == null) {
			return;
		}

		__acceptRuntime = __cbInstance;
		if (__needsAcceptTick()) {
			__tickRuntime = __acceptRuntime;
			__tickRuntime.addEventListener(TickEvent.TICK, __onAcceptTick());
		}
		__syncListenerWatch();
	}

	/**
		Stops accepting: the accept tick comes off the runtime it was put on
		and the listener leaves its poll set -- before the listener is closed,
		which every caller does after this.
	**/
	@:noCompletion private function __detachAcceptTick():Void {
		if (__acceptRuntime == null) {
			return;
		}
		__acceptRuntime = null;

		if (__tickRuntime != null) {
			var runtime:CrossByte = __tickRuntime;
			__tickRuntime = null;
			runtime.removeEventListener(TickEvent.TICK, __onAcceptTick());
		}
		__unwatchListener();
	}

	/**
		Whether this server needs the accept tick: for the deadlines of the
		TLS handshakes it has in flight. A plain server needs none, since the
		poll set reports its connections.
	**/
	@:noCompletion private function __needsAcceptTick():Bool {
		return secure;
	}

	/**
		Whether as many connections are still arriving as `maxPendingHandshakes`
		allows, so the rest are left in the kernel's queue.
	**/
	@:noCompletion private function __handshakesFull():Bool {
		return secure && maxPendingHandshakes >= 0 && __pendingHandshakes.length >= maxPendingHandshakes;
	}

	/** The socket connections are accepted from. **/
	@:noCompletion private function __listenerSocket():Socket {
		return __serverSocket;
	}

	/**
		Keeps the listener in the poll set while this server is accepting and
		has room, and out of it otherwise: at the handshake limit the listener
		stays readable with nothing taken from it, and a poll would report it
		on every pass -- a POLL loop spinning until a handshake finished.
	**/
	@:noCompletion private function __syncListenerWatch():Void {
		if (__acceptRuntime != null && !__closed && listening && !__handshakesFull()) {
			__watchListener(__acceptRuntime);
		} else {
			__unwatchListener();
		}
	}

	@:noCompletion private function __watchListener(runtime:CrossByte):Void {
		if (__pollRuntime != null) {
			return;
		}

		var listener:Socket = __listenerSocket();
		if (listener == null) {
			return;
		}

		if (__listenerPoll == null) {
			__listenerPoll = new ListenerPoll(this);
		}
		listener.custom = __listenerPoll;
		__pollRuntime = runtime;
		@:privateAccess
		runtime.registerSocket(listener);
	}

	@:noCompletion private function __unwatchListener():Void {
		if (__pollRuntime == null) {
			return;
		}

		var runtime:CrossByte = __pollRuntime;
		__pollRuntime = null;
		var listener:Socket = __listenerSocket();
		if (listener != null) {
			@:privateAccess
			runtime.deregisterSocket(listener);
		}
	}
	#end

	private function get_isSupported():Bool {
		return true;
	}

	/**
		Number of connections currently completing their TLS handshake.
		Always `0` on a plain server.
	**/
	public function pendingHandshakeCount():Int {
		#if nodejs
		// Always zero, and not because none are in flight: a Node server never
		// terminates TLS, so there is no handshake for it to be counting.
		return 0;
		#else
		return __pendingHandshakes == null ? 0 : __pendingHandshakes.length;
		#end
	}

	/**
		Stops accepting new connections while leaving already-established
		connections open and usable.

		This is the first half of a graceful shutdown: the listening socket
		is released (freeing the port for a successor process) and any
		connection still completing its TLS handshake is dropped, but
		application traffic on existing connections continues until the
		caller closes those connections itself.

		Safe to call more than once, and safe to call on a server that was
		never listening. Unlike `close()`, no `close` event is dispatched
		and the server is not marked as closed.
	**/
	public function stopAccepting():Void {
		if (!listening && !bound) {
			return;
		}

		#if !nodejs
		__dropPendingHandshakes();
		__detachAcceptTick();
		#end

		try {
			__serverSocket.close();
		} catch (_:Dynamic) {
			// The listener may already be gone; releasing it is best-effort.
		}

		listening = false;
		bound = false;
		__listenerReleased = true;
	}

	/**
		Advances every in-flight TLS handshake by one non-blocking step.

		`handshake()` on a non-blocking socket raises a blocked error until
		enough of the peer's flight has arrived. Each handshake is stepped as
		its socket turns readable; this, from the tick, is what ends one that
		has run past `handshakeTimeout`, and finishes one waiting on a flight
		of its own it could not write whole. Connections that complete are
		promoted to ordinary `connect` events; those that fail or run out of
		time are closed without ever reaching application code.
	**/
	@:noCompletion private function __pumpHandshakes():Void {
		// Node terminates its own handshakes -- tls.createServer does not hand
		// out a connection until one has completed -- so there is nothing here
		// to pump and no pending set to pump it from.
		#if !nodejs
		if (__pendingHandshakes == null || __pendingHandshakes.length == 0) {
			return;
		}

		var now:Float = haxe.Timer.stamp();
		var stillPending:Array<PendingHandshake> = [];
		var completed:Array<PendingHandshake> = [];
		var failed:Array<PendingHandshake> = [];

		for (pending in __pendingHandshakes) {
			var outcome:Int = __stepOnce(pending);
			if (outcome > 0) {
				completed.push(pending);
			} else if (outcome < 0 || now >= pending.deadline) {
				failed.push(pending);
			} else {
				stillPending.push(pending);
			}
		}

		__pendingHandshakes = stillPending;

		for (pending in failed) {
			__abandonHandshake(pending);
		}

		// Dispatch only after the pending list is settled: a listener may
		// close this server, and must not observe a half-updated queue.
		for (pending in completed) {
			__promoteHandshake(pending);
		}
		__syncListenerWatch();
		#end
	}

	#if !nodejs
	/**
		One handshake's socket is readable: its step is taken now, rather than
		at the next tick.
	**/
	@:noCompletion private function __stepHandshake(pending:PendingHandshake):Void {
		var outcome:Int = __stepOnce(pending);
		if (outcome == 0) {
			return;
		}

		__pendingHandshakes.remove(pending);
		if (outcome > 0) {
			__promoteHandshake(pending);
		} else {
			__abandonHandshake(pending);
		}
		__syncListenerWatch();
	}

	/**
		Takes one non-blocking step of `pending`'s handshake: 1 when it has
		completed, 0 when it waits on the peer, -1 when it has failed.
	**/
	@:noCompletion private function __stepOnce(pending:PendingHandshake):Int {
		try {
			(cast pending.socket : SSLSocket).handshake();
			return 1;
		} catch (e:Dynamic) {
			// One predicate for every spelling of "come back later": the
			// typed error and the bare string the TLS layer raises before
			// anything maps it.
			return __isBlockedError(e) ? 0 : -1;
		}
	}

	/** A completed handshake becomes a connection, and is announced. **/
	@:noCompletion private function __promoteHandshake(pending:PendingHandshake):Void {
		pending.settled = true;
		try {
			// Its socket stays in the poll set, answering to the connection
			// from here on.
			var cbSocket:CBSocket = __fromSocket(pending.socket);
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, cbSocket));
		} catch (_:Dynamic) {
			__closeHandshake(pending);
		}
	}

	/** A handshake that failed or ran out of time is counted and closed. **/
	@:noCompletion private function __abandonHandshake(pending:PendingHandshake):Void {
		pending.settled = true;
		handshakeFailures++;
		__closeHandshake(pending);
	}

	/** Out of the poll set, and then closed. **/
	@:noCompletion private function __closeHandshake(pending:PendingHandshake):Void {
		if (pending.runtime != null) {
			@:privateAccess
			pending.runtime.deregisterSocket(pending.socket);
		}
		try {
			pending.socket.close();
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __dropPendingHandshakes():Void {
		if (__pendingHandshakes == null) {
			return;
		}

		var dropped:Array<PendingHandshake> = __pendingHandshakes;
		__pendingHandshakes = [];
		for (pending in dropped) {
			pending.settled = true;
			__closeHandshake(pending);
		}
	}

	@:noCompletion private inline function __isBlockedError(error:Dynamic):Bool {
		return crossbyte._internal.socket.BlockedError.isBlocked(error);
	}
	#end
}

#if !nodejs
/**
	A connection a TLS listener has accepted and is still handshaking with.
	It sits in the poll set as its own socket's handler, so each flight the
	peer sends steps the handshake the moment it lands.
**/
@:noCompletion
@:access(crossbyte.net.ServerSocket)
final class PendingHandshake implements IPollableSocket {
	public var socket(default, null):Socket;
	public var deadline(default, null):Float;

	// The runtime whose poll set it is in, if it is in one.
	public var runtime:CrossByte = null;

	// Promoted, failed or dropped: nothing more for the poll set to do.
	public var settled:Bool = false;

	public var registryClosed(get, never):Bool;

	@:noCompletion private var __server:ServerSocket;

	public function new(server:ServerSocket, socket:Socket, deadline:Float) {
		__server = server;
		this.socket = socket;
		this.deadline = deadline;
	}

	@:noCompletion private inline function get_registryClosed():Bool {
		return settled;
	}

	public function registryOnReadable():Void {
		__server.__stepHandshake(this);
	}

	public function registryOnWritable():Void {}

	public function registryHasBufferedInput():Bool {
		return false;
	}
}

/**
	What the poll set calls for a listening socket: readable means there are
	connections waiting to be taken.
**/
@:noCompletion
@:access(crossbyte.net.ServerSocket)
private final class ListenerPoll implements IPollableSocket {
	public var registryClosed(get, never):Bool;

	@:noCompletion private var __server:ServerSocket;

	public function new(server:ServerSocket) {
		__server = server;
	}

	@:noCompletion private inline function get_registryClosed():Bool {
		return __server.__closed || !__server.listening;
	}

	public function registryOnReadable():Void {
		__server.__onListenerReadable();
	}

	public function registryOnWritable():Void {}

	public function registryHasBufferedInput():Bool {
		return false;
	}
}
#end
#end
