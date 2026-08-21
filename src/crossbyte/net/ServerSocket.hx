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
import js.node.net.Server as NodeServer;
import js.node.net.Socket as NodeSocket;
#else
import sys.net.Host;
import sys.net.Socket;
#if (!java && !jvm)
import sys.ssl.Socket as SSLSocket;
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
	bandwidth better than the UDP protocol. Most AIR applications that require socket communications
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

	@:noCompletion private var __serverSocket:#if nodejs NodeServer #else Socket #end;
	@:noCompletion private var __closed:Bool;
	@:noCompletion private var __cbInstance:CrossByte;
	@:noCompletion private var __hasListener:Bool = false;
	@:noCompletion private var __hasCertificate:Bool = false;
	#if !nodejs
	@:noCompletion private var __pendingHandshakes:Array<PendingHandshake>;
	#end
	@:noCompletion private var __listenerReleased:Bool = false;

	/**
		Creates a ServerSocket object.

		@param secure When `true`, the server terminates TLS: a certificate
			must be installed with `setCertificate()` before `listen()`, and
			`connect` events are dispatched only after each client's handshake
			completes. Handshakes progress across ticks and never block the
			runtime loop.
		@throws  SecurityError This error occurs ff the calling content is running outside the AIR
				application security sandbox.
	**/
	public function new(secure:Bool = false) {
		super();

		#if (java || jvm)
		if (secure) {
			throw new CBError("Secure ServerSocket is not supported on the jvm target yet.");
		}
		#elseif nodejs
		if (secure) {
			throw new CBError("A secure ServerSocket is not implemented on Node yet. Nothing is in the way of it: Node terminates TLS through tls.createServer, and crossbyte.net.Certificate and Key already carry PEM there. What is missing is only that this listener is a js.node.net.Server, where a secure one would be a js.node.tls.Server built from that PEM. Until it is written, put a TLS terminator in front, or run the server on a native target.");
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
		__serverSocket = Net.createServer(function(connection:NodeSocket):Void {
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

			var socket:CBSocket = @:privateAccess CBSocket.__adoptNodeSocket(connection, __cbInstance);
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
		});

		// A port already in use, or an address that is not local, reaches a
		// Node server as an event rather than as a failed call -- see bind().
		__serverSocket.on("error", function(_):Void {
			if (__closed) {
				return;
			}

			close();
			dispatchEvent(new Event(Event.CLOSE));
		});

		__closed = false;
		bound = false;
		listening = false;
		#else
		#if (java || jvm)
		__serverSocket = new sys.net.Socket();
		#else
		// sys.ssl.Socket extends sys.net.Socket, so the accept/select paths
		// below are identical for both modes.
		__serverSocket = secure ? new SSLSocket() : new sys.net.Socket();

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

	#if (!java && !jvm && !nodejs)
	/**
		Installs the certificate chain and private key this server presents to
		clients. Must be called on a secure server before `listen()`.

		@param cert The certificate chain to present.
		@param key The matching private key.
		@throws Error When this server was not constructed with `secure` set.
	**/
	public function setCertificate(cert:Certificate, key:Key):Void {
		__requireSecure("setCertificate");

		(cast __serverSocket : SSLSocket).setCertificate(cert.__native, key.__native);
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

		(cast __serverSocket : SSLSocket).addSNICertificate(serverNameMatch, cert.__native, key.__native);
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

		var sslSocket:SSLSocket = cast __serverSocket;
		sslSocket.setCA(ca.__native);
		sslSocket.verifyCert = true;
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
	#end

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
			switch (e) {
				case "Bind failed":
					throw new IOError("Operation attempted on invalid socket.");
				case "Unresolved host":
					throw new ArgumentError("One of the parameters is invalid");
			}
		}
		#end
	}

	/**
		Closes the socket and stops listening for connections.
		Closed sockets cannot be reopened. Create a new ServerSocket instance instead.
		@throws Error This error occurs if the socket could not be closed, or the socket was not open.
	**/
	public function close():Void {
		#if !nodejs
		__dropPendingHandshakes();
		#end

		// stopAccepting() may already have released the listening socket as
		// the first half of a graceful shutdown; closing it again is not an
		// error.
		if (!__listenerReleased) {
			try {
				__serverSocket.close();
			} catch (e:Dynamic) {
				throw new CBError("Operation attempted on invalid socket.");
			}
		}
		listening = false;
		bound = false;
		__closed = true;
		#if !nodejs
		if (__cbInstance != null) {
			__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
		}
		#end
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
				backlog = 0x7FFFFFFF;
			}

			#if nodejs
			if (!bound) {
				throw new IOError("Operation attempted on invalid socket.");
			}

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
				__cbInstance.addEventListener(Event.TICK, this_onTick);
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
		cbSocket.__timestamp = Sys.time();

		cbSocket.__host = socket.peer().host.toString();
		cbSocket.__port = socket.peer().port;

		cbSocket.__output = new ByteArray();
		cbSocket.__output.endian = cbSocket.__endian;

		cbSocket.__input = new ByteArray();
		cbSocket.__input.endian = cbSocket.__endian;

		cbSocket.__cbInstance = __cbInstance;

		Timer.delay(() -> {
			if (!cbSocket.__connected) {
				cbSocket.dispatchEvent(new Event(Event.CLOSE));
			}
		}, 0);

		socket.custom = cbSocket;

		@:privateAccess
		__cbInstance.registerSocket(socket);

		return cbSocket;
	}

	@:noCompletion private function this_onTick(e:TickEvent):Void {
		var sysSocket = null;

		__pumpHandshakes();

		try {
			if (__serverSocket == null || !listening) {
				return;
			}
			var ready = Socket.select([__serverSocket], [], [], 0);
			if (ready.read.length == 0 || ready.read[0] != __serverSocket) {
				return;
			}

			sysSocket = __serverSocket.accept();

			if (secure) {
				// Defer the connect event: the peer is not authenticated (and
				// no application bytes are readable) until TLS completes.
				sysSocket.setBlocking(false);
				__pendingHandshakes.push({socket: sysSocket, deadline: Sys.time() + handshakeTimeout});
				__pumpHandshakes();
				return;
			}

			var socket:CBSocket = __fromSocket(sysSocket);
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
		} catch (e:Error) {
			if (!__isBlockedError(e)) {
				close();
				dispatchEvent(new Event(Event.CLOSE));
			}
		} catch (e:Dynamic) {
			// Do nothing.
		}

		/* if (sysSocket != null) {
			var socket:CBSocket = __fromSocket(sysSocket);
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
		}*/
	}

	#end

	override public function addEventListener(type:String, listener:Dynamic->Void, priority:Int = 0):Void {
		super.addEventListener(type, listener, priority);

		if (type == Event.CONNECT) {
			__hasListener = true;
			#if !nodejs
			if (listening) {
				__cbInstance.addEventListener(TickEvent.TICK, this_onTick);
			}
			#end
		}
	}

	override public function removeEventListener(type:String, listener:Dynamic->Void):Void {
		super.removeEventListener(type, listener);

		if (type == Event.CONNECT) {
			__hasListener = false;
			#if !nodejs
			if (__cbInstance != null) {
				__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
			}
			#end
		}
	}

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

		if (__cbInstance != null) {
			__cbInstance.removeEventListener(TickEvent.TICK, this_onTick);
		}
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
		enough of the peer's flight has arrived, so each connection may need
		several ticks. Connections that complete are promoted to ordinary
		`connect` events; those that fail or exceed `handshakeTimeout` are
		closed without ever reaching application code.
	**/
	@:noCompletion private function __pumpHandshakes():Void {
		#if (!java && !jvm && !nodejs)
		if (__pendingHandshakes == null || __pendingHandshakes.length == 0) {
			return;
		}

		var now:Float = Sys.time();
		var stillPending:Array<PendingHandshake> = [];
		var completed:Array<Socket> = [];

		for (pending in __pendingHandshakes) {
			var done:Bool = false;
			var failed:Bool = false;

			try {
				(cast pending.socket : SSLSocket).handshake();
				done = true;
			} catch (e:Error) {
				if (!__isBlockedError(e)) {
					failed = true;
				}
			} catch (_:Dynamic) {
				failed = true;
			}

			if (done) {
				completed.push(pending.socket);
			} else if (failed || now >= pending.deadline) {
				try {
					pending.socket.close();
				} catch (_:Dynamic) {}
			} else {
				stillPending.push(pending);
			}
		}

		__pendingHandshakes = stillPending;

		// Dispatch only after the pending list is settled: a listener may
		// close this server, and must not observe a half-updated queue.
		for (socket in completed) {
			try {
				var cbSocket:CBSocket = __fromSocket(socket);
				dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, cbSocket));
			} catch (_:Dynamic) {
				try {
					socket.close();
				} catch (_:Dynamic) {}
			}
		}
		#end
	}

	#if !nodejs
	@:noCompletion private function __dropPendingHandshakes():Void {
		if (__pendingHandshakes == null) {
			return;
		}

		for (pending in __pendingHandshakes) {
			try {
				pending.socket.close();
			} catch (_:Dynamic) {}
		}
		__pendingHandshakes = [];
	}

	@:noCompletion private inline function __isBlockedError(error:Dynamic):Bool {
		return crossbyte._internal.socket.BlockedError.isBlocked(error);
	}
	#end
}

#if !nodejs
typedef PendingHandshake = {
	var socket:Socket;
	var deadline:Float;
}
#end
#end
