package crossbyte.net;

// Not built for the browser, for the same reason as ServerSocket: accepting WebSocket connections means listening, which a page cannot do.
#if !(js && !nodejs)

#if nodejs
import js.node.Net;
import js.node.Tls;
import js.node.net.Server as NodeServer;
import js.node.net.Socket as NodeSocket;
#else
import crossbyte._internal.websocket.FlexSocket;
#end
import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import crossbyte.net.WebSocket;
import haxe.io.Eof;
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
#if !nodejs
import sys.net.Host;
#end

/**
 * A server that accepts WebSocket sessions.
 *
 * Admission works as it does on `ServerSocket`, whose settings this
 * inherits: `admit` is asked about each connection as soon as it is
 * accepted, before any TLS or upgrade work; `maxAcceptsPerTick` bounds how
 * many are taken from the listen queue in one tick; and
 * `maxPendingHandshakes` bounds the sessions still upgrading, TLS and the
 * HTTP upgrade together, after which new connections wait in the kernel's
 * queue. On Node, which accepts as connections arrive and has no queue to
 * leave them in, a connection that would pass that bound is refused.
 *
 * @author Christopher Speciale
 */
class ServerWebSocket extends ServerSocket {
	// Note: use chrome://flags/#allow-insecure-localhost to allow local host certificates in chrome!

	/**
		The authority a client's certificate has to be issued by: mutual TLS.

		Set, every client is asked for a certificate during the TLS handshake,
		and one that presents none, or one this authority did not issue, fails
		the handshake and never becomes a session. That is every browser,
		unless its user has installed a certificate for this server. `null`,
		the default, asks clients for nothing.

		The same as `requireClientCertificate()`, and the same on every
		target. Set it before `bind()`, where a native server builds its TLS
		configuration; it is refused afterwards.

		@throws Error When this server is not secure, unless the value is
			`null`, or when it is already bound.
	**/
	public var certAuthority(default, set):Certificate;

	/**
		Indicates whether or not ServerSocket features are supported in the run-time environment.
	**/
	public static var isSupported(default, null):Bool = #if html5 false #else true #end;

	/**
		Applied to every session this server accepts as its
		`WebSocket.maxOutputBufferSize`, or `0` to leave sessions unbounded.

		Set here rather than per session because an application never sees an
		accepted socket before the handshake response is written to it, so a
		per-connection limit is only reachable from the server that accepted
		it. Existing sessions are unaffected; assign before `listen()`.

		Size it to the largest message this server legitimately sends, with
		headroom.
	**/
	public var maxOutputBufferSize:Int = 0;

	/**
		`WebSocket.pingInterval` for each session this server accepts, in
		seconds; zero for none. Set before the sessions it is for arrive.
	**/
	public var pingInterval:Float = crossbyte._internal.websocket.WebSocket.PING_INTERVAL / 1000;

	/**
		`WebSocket.idleTimeout` for each session this server accepts, in
		seconds; zero for never. A session whose peer has vanished without
		closing is closed after this, and what was waiting for it freed.
	**/
	public var idleTimeout:Float = crossbyte._internal.websocket.WebSocket.DEFAULT_IDLE_TIMEOUT;

	/**
		Whether sessions agree to permessage-deflate (RFC 7692) when a client
		offers it, as every browser does, sending each message of
		`compressionThreshold` bytes or more compressed and accepting
		compressed messages.
		Off by default. Set before the sessions it is for arrive.

		Each message is compressed on its own, in both directions: this side
		keeps no compressor between messages, and asks the client to keep
		none. An offer that would narrow this side's window is declined, and
		that session goes on uncompressed. `WebSocket.compressed` says which a
		session got.
	**/
	public var perMessageDeflate:Bool = false;

	/**
		`WebSocket.compressionThreshold` for each session this server accepts:
		messages shorter than this many bytes go uncompressed.
	**/
	public var compressionThreshold:Int = crossbyte._internal.websocket.WebSocket.DEFAULT_COMPRESSION_THRESHOLD;

	/**
		Decides, once a client's upgrade request has arrived and before the
		`101` answers it, whether the session is opened, and with which
		subprotocol.

		The request's path, query, headers, cookies and `Origin` are all
		there, which is where a session is authenticated and a page from
		another site refused. Return `false` to refuse, answered with the
		request's `status` (403 unless changed); set `request.protocol` to
		choose from the subprotocols offered. Unset, every valid upgrade is
		accepted, with the first subprotocol the client offered: a browser that
		offers one and hears none back fails the connection. A hook that throws
		refuses, with 500.

		The session carries the request afterwards, as `WebSocket.request`.
	**/
	public dynamic function upgrade(request:WebSocketRequest):Bool {
		return true;
	}

	@:noCompletion private var __metrics:crossbyte.metrics.Metrics;
	@:noCompletion private var __acceptedTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __closedTotal:crossbyte.metrics.Counter;

	/**
	 * Publishes this server's session metrics into `registry`.
	 *
	 * Everything here is an **aggregate across sessions**, a count, a
	 * maximum, a sum. Nothing is labelled per peer, and that is a hard
	 * constraint rather than a stylistic one: a label whose values are
	 * client addresses or session ids creates a new time series per
	 * connection, which a collector keeps long after the connection is
	 * gone. On a server with real churn that is how a metrics pipeline is
	 * brought down by the thing meant to observe it.
	 *
	 * The buffer gauges are what make a slow consumer visible.
	 * `maxOutputBufferSize` bounds a single session, but a fleet of peers
	 * each sitting just under the bound is invisible from the ceiling
	 * alone; the max and the total together separate one stuck client from
	 * a server-wide back-up.
	 *
	 * Call before `listen()` so the first accepted session is counted.
	 *
	 * @param registry Destination registry.
	 * @param prefix Metric name prefix. Defaults to `websocket`.
	 */
	public function publishMetrics(registry:crossbyte.metrics.Metrics, prefix:String = "websocket"):Void {
		if (registry == null) {
			return;
		}

		__metrics = registry;
		var name:String = (prefix == null || prefix == "") ? "websocket" : prefix;

		registry.gaugeFn(name + "_sessions", () -> clientCount, null, "Sessions currently established.");

		registry.gaugeFn(name + "_output_buffer_bytes_max", () -> __maxOutputBuffer(), null,
			"Largest amount of unsent frame data held by any one session.");
		registry.gaugeFn(name + "_output_buffer_bytes_total", () -> __totalOutputBuffer(), null,
			"Unsent frame data held across all sessions.");

		__acceptedTotal = registry.counter(name + "_sessions_accepted_total", null, "Sessions accepted since start.");
		__closedTotal = registry.counter(name + "_sessions_closed_total", null, "Sessions closed since start.");
	}

	/**
	 * Walks the live sessions on scrape rather than tracking a running
	 * maximum, because a running maximum only ever rises: once one peer
	 * stalls, the metric stays high forever and stops describing the
	 * present. Cost is one pass over the session list per scrape.
	 */
	@:noCompletion private function __maxOutputBuffer():Int {
		var peak:Int = 0;
		for (client in __clients) {
			var pending:Int = client.outputBufferLength;
			if (pending > peak) {
				peak = pending;
			}
		}
		return peak;
	}

	@:noCompletion private function __totalOutputBuffer():Int {
		var total:Int = 0;
		for (client in __clients) {
			total += client.outputBufferLength;
		}
		return total;
	}

	@:noCompletion private var __webServerSocket:#if nodejs NodeServer #else FlexSocket #end;
	#if nodejs
	// The runtime the upgrade reaper is attached to, or null while it is not;
	// see __attachTick.
	@:noCompletion private var __reapRuntime:CrossByte = null;
	#end

	// Sessions accepted whose upgrade has not completed, and when to give up
	// on each.
	//
	// `ServerSocket` bounds this for its own accepts by deferring the TLS
	// handshake and sweeping deadlines from the tick. This class overrides
	// `this_onTick` and accepts through its own path, so it never populated
	// that queue and never swept it, proposal 0010 recorded the gap and it
	// is this list that closes it. One deadline covers both ways an upgrade
	// can stall: a peer that finishes the TCP connection and then says nothing
	// during TLS, and one that completes TLS and never sends the HTTP upgrade.
	// Neither is distinguishable from a slow client until the clock runs out,
	// which is exactly why there has to be a clock.
	@:noCompletion private var __pendingUpgrades:Array<PendingUpgrade> = [];

	@:noCompletion private function set_certAuthority(value:Certificate):Certificate {
		// Nothing asked of a plain server, so nothing to refuse.
		if (value == null && !secure) {
			return certAuthority = null;
		}
		__requireUnboundTls("certAuthority");

		#if nodejs
		// Kept for listen(), which builds the server from it: ca with
		// requestCert and rejectUnauthorized.
		__tlsAuthority = value;
		#else
		// The authority and the demand together. Natively the authority alone
		// was installed, with verification left off as the constructor set
		// it, so a server told to require client certificates let in a client
		// that presented none, where Node asked and refused.
		if (value != null) {
			__webServerSocket.setCA(value.__native);
		}
		__webServerSocket.verifyCert = value != null;
		#end

		return certAuthority = value;
	}

	/**
		Requires connecting clients to present a certificate `ca` issued
		(mutual TLS): the same as setting `certAuthority`, which see.

		@param ca The authority client certificates must be issued by.
		@throws Error When this server is not secure, when `ca` is `null`,
			or when it is already bound.
	**/
	override public function requireClientCertificate(ca:Certificate):Void {
		if (ca == null) {
			throw new CBError("requireClientCertificate requires a certificate authority.");
		}
		certAuthority = ca;
	}

	/**
		Refuses TLS configuration on a plain server, and once this server is
		bound: a native server builds its TLS configuration in `bind()`, so
		anything assigned later would silently never apply.
	**/
	@:noCompletion private function __requireUnboundTls(field:String):Void {
		if (!secure) {
			throw new CBError('$field is only available on a ServerWebSocket constructed with secure = true.');
		}
		if (bound || listening || __listenerReleased || __closed) {
			throw new CBError('$field must be set before bind(), where the TLS configuration is built.');
		}
	}

	/**
		Client connections that have completed their handshake and not yet
		closed. Maintained so `drain()` can shut them down deliberately.
	**/
	public var clientCount(get, never):Int;

	private function get_clientCount():Int {
		return __clients.length;
	}

	/**
		Whether `drain()` has been called and shutdown is in progress.
	**/
	public var draining(default, null):Bool = false;

	@:noCompletion private var __clients:Array<WebSocket> = [];

	/**
		Creates a ServerWebSocket.

		@param secure When `true`, the server terminates TLS (`wss://`) and
			requires a certificate, through `cert` or `setCertificate()`,
			before `bind()`.
		@throws Error On the eval target, when `secure` is true. Inherited from
			`ServerSocket`, which cannot install a certificate there.
	**/
	public function new(secure:Bool = false) {
		// Passed up rather than kept here. This used to set a private
		// secure and then call super() with no argument, so `secure`,
		// the property ServerSocket exposes and this class inherits, read
		// false on a server that was terminating TLS. Two fields for one fact,
		// and the public one was the wrong one.
		super(secure);

		// The server dispatches CONNECT to itself once a handshake
		// completes, so it can observe its own connections without the
		// WebSocket needing to know about a registry.
		addEventListener(ServerSocketConnectEvent.CONNECT, __trackClient);
	}

	/**
		The tick this target needs, attached and detached in one place.

		Native drives its own accepting from `this_onTick`, and reaps there as a
		side effect of already being called. Node is handed connections by a
		callback and has no accept loop, so it has nothing that runs on a clock,
		and it needs one exactly as much, because a peer that completes the
		TCP connection and then says nothing is holding a descriptor either way.
	**/
	@:noCompletion private function __attachTick():Void {
		#if nodejs
		if (__reapRuntime != null || __cbInstance == null) {
			return;
		}

		__reapRuntime = __cbInstance;
		__reapRuntime.addEventListener(TickEvent.TICK, __reapOnTick);
		#else
		// The one attachment ServerSocket keeps for the accept tick, which is
		// this class's this_onTick. This added a second of its own, beside the
		// one a connect listener added while listening puts there, and the
		// one close() took away left the other running; see
		// ServerSocket.__attachAcceptTick.
		__attachAcceptTick();
		#end
	}

	@:noCompletion private function __detachTick():Void {
		#if nodejs
		if (__reapRuntime == null) {
			return;
		}

		var runtime = __reapRuntime;
		__reapRuntime = null;
		runtime.removeEventListener(TickEvent.TICK, __reapOnTick);
		#else
		__detachAcceptTick();
		#end
	}

	#if nodejs
	@:noCompletion private function __reapOnTick(_:TickEvent):Void {
		__reapStalledUpgrades();
	}
	#end

	@:noCompletion private function __clearPendingUpgrade(session:WebSocket):Void {
		for (pending in __pendingUpgrades) {
			if (pending.session == session) {
				__pendingUpgrades.remove(pending);
				return;
			}
		}
	}

	@:noCompletion private function __reapStalledUpgrades():Void {
		if (__pendingUpgrades.length == 0) {
			return;
		}

		var now:Float = haxe.Timer.stamp();
		var still:Array<PendingUpgrade> = [];

		for (pending in __pendingUpgrades) {
			// Gone on its own, by close or by error. Nothing owed here.
			//
			// This read `!pending.session.connected`, which is never true of a
			// session waiting to upgrade: a WebSocket reports `connected` once
			// the handshake completes, deliberately, and these are exactly the
			// sessions whose handshake has not completed. So every entry took
			// this branch on the first tick after it was recorded and was
			// dropped from tracking without being closed. The deadline below was
			// unreachable, and `handshakeTimeout` shut nothing on any target.
			//
			// A successful upgrade is not what this has to catch either: the
			// session removes itself through `__clearPendingUpgrade` when it
			// dispatches CONNECT. What is left for here is a session that went
			// away on its own, which is what `registryClosed` says.
			if (pending.session == null || pending.session.registryClosed) {
				continue;
			}

			if (now < pending.deadline) {
				still.push(pending);
				continue;
			}

			try {
				pending.session.close();
			} catch (_:Dynamic) {}
		}

		__pendingUpgrades = still;
	}

	@:noCompletion private function __trackClient(e:ServerSocketConnectEvent):Void {
		var client:WebSocket = cast e.socket;
		if (client == null || __clients.indexOf(client) >= 0) {
			return;
		}

		// It arrived, so it is no longer owed a deadline. CONNECT is dispatched
		// once the upgrade completes, which is the only moment that is true.
		__clearPendingUpgrade(client);
		#if !nodejs
		// And a listener set aside at the limit can take the next.
		__syncListenerWatch();
		#end

		if (maxOutputBufferSize > 0) {
			client.maxOutputBufferSize = maxOutputBufferSize;
		}

		__clients.push(client);
		if (__acceptedTotal != null) {
			__acceptedTotal.inc();
		}

		client.addEventListener(Event.CLOSE, function(_) {
			__clients.remove(client);
			if (__closedTotal != null) {
				__closedTotal.inc();
			}
		});
	}

	override function __init():Void {
		#if nodejs
		// Built in listen(), not here: a Node TLS server takes its key and
		// certificate when it is created, and those arrive afterwards through
		// `cert`. See ServerSocket.__makeNodeServer, which this mirrors.
		__webServerSocket = null;
		#else
		__webServerSocket = new FlexSocket(secure);

		if (secure) {
			// A TLS socket verifies its peer unless told otherwise, which on a
			// server means demanding a certificate from every client, every
			// browser refused. Clients are asked for one only once
			// certAuthority says to.
			__webServerSocket.verifyCert = false;
		}

		__webServerSocket.setBlocking(false);
		__webServerSocket.setFastSend(true);
		#end
		__closed = false;
		bound = false;
		listening = false;
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
	override public function bind(localPort:Int = 0, localAddress:String = "0.0.0.0"):Void {
		if (localPort > 65535 || localPort < 0) {
			throw new RangeError("Invalid socket port number specified.");
		}
		try {
			#if nodejs
			// Node has no bind separate from listening, so this records the
			// endpoint and listen() claims it, which means a refused address
			// arrives as a close event rather than out of this call, and a
			// port of 0 stays 0 until listen() can ask what was assigned.
			// Exactly as ServerSocket behaves there.
			this.localAddress = localAddress;
			this.localPort = localPort;
			bound = true;
			#else
			this.localAddress = localAddress;
			__webServerSocket.bind(localAddress, localPort);

			// Port 0 asks the operating system to choose. Report the port it
			// actually assigned, matching ServerSocket: otherwise localPort
			// stays 0 and a caller has no way to learn where to connect.
			this.localPort = localPort == 0 ? __webServerSocket.host().port : localPort;
			bound = true;
			#end
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
					// invalid, the address or the port would not take.
					throw new IOError("Could not bind to " + localAddress + ":" + localPort + ": " + Std.string(e));
			}
		}
	}

	/**
		Stops accepting new connections while leaving established sessions
		open and usable.

		The listening socket is released, so a successor process can bind
		the port immediately during a deploy. Unlike `close()`, no `close`
		event is dispatched and the server is not marked closed. Safe to
		call more than once.
	**/
	override public function stopAccepting():Void {
		if (!listening && !bound) {
			return;
		}

		__detachTick();

		try {
			__webServerSocket.close();
		} catch (_:Dynamic) {
			// Best-effort: the listener may already be gone.
		}

		listening = false;
		bound = false;
		__listenerReleased = true;
	}

	/**
		Gracefully shuts the server down.

		A WebSocket session is long-lived by design, so unlike an HTTP
		request there is nothing to "finish". Draining therefore means
		telling clients to go away: every session is sent a close frame
		with `closeCode`, and sessions still open when `timeoutSeconds`
		elapses are dropped.

		Sending a close frame rather than severing the socket is what lets
		a client distinguish an orderly shutdown from a network failure,
		and so reconnect sensibly instead of treating it as an error.

		Pairs with `ProcessLifecycle`:

		```haxe
		ProcessLifecycle.onShutdown(() -> server.drain());
		ProcessLifecycle.installDefaultHandlers();
		```

		@param timeoutSeconds How long to wait for clients to acknowledge
			before dropping them. Values at or below zero close at once.
		@param onComplete Invoked once shutdown finishes, on the runtime
			thread.
		@param closeCode WebSocket close code sent to clients. Defaults to
			1001 ("going away"), the code meaning a server is shutting
			down.
	**/
	public function drain(timeoutSeconds:Float = 30.0, ?onComplete:Void->Void, closeCode:Int = 1001):Void {
		if (draining) {
			return;
		}
		draining = true;

		stopAccepting();

		var pending:Array<WebSocket> = __clients.copy();
		for (client in pending) {
			try {
				client.closeWith(closeCode, "server shutting down");
			} catch (_:Dynamic) {
				// A session that is already gone needs no close frame.
			}
		}

		if (__clients.length == 0 || timeoutSeconds <= 0 || __cbInstance == null) {
			__finishDrain(onComplete);
			return;
		}

		var deadline:Float = haxe.Timer.stamp() + timeoutSeconds;
		var runtime = __cbInstance;
		var onTick:TickEvent->Void = null;

		onTick = function(_:TickEvent):Void {
			if (__clients.length > 0 && haxe.Timer.stamp() < deadline) {
				return;
			}

			runtime.removeEventListener(TickEvent.TICK, onTick);
			__finishDrain(onComplete);
		};
		runtime.addEventListener(TickEvent.TICK, onTick);
	}

	@:noCompletion private function __finishDrain(onComplete:Void->Void):Void {
		for (client in __clients.copy()) {
			try {
				client.close();
			} catch (_:Dynamic) {}
		}
		__clients = [];

		try {
			close();
		} catch (_:Dynamic) {}

		if (onComplete != null) {
			onComplete();
		}
	}

	/**
		Closes the socket and stops listening for connections.
		Closed sockets cannot be reopened. Create a new ServerSocket instance instead.
		@throws Error This error occurs if the socket could not be closed, or the socket was not open.
	**/
	override public function close():Void {
		// stopAccepting() may already have released the listener as the
		// first half of a graceful shutdown; closing again is not an error.
		if (__listenerReleased) {
			listening = false;
			bound = false;
			__closed = true;
			__detachTick();
			__cbInstance = null;
			return;
		}

		// Out of the poll set before the listener is closed; see
		// Socket.__cleanSocket.
		__detachTick();
		try {
			__webServerSocket.close();
		} catch (e:Dynamic) {
			throw new CBError("The listening socket could not be closed: " + Std.string(e));
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
	override public function listen(backlog:Int = 0):Void {
		__cbInstance = CrossByte.current();
		if (__cbInstance == null) {
			throw "ServerWebSocket can only be initiated in a CrossByte threaded instance";
		}
		if (__closed) {
			throw new IOError("Operation attempted on invalid socket.");
		}
		// As ServerSocket asks. Natively nothing did: the server listened,
		// and every handshake failed without a word.
		if (secure && !__hasCertificate) {
			throw new IOError("A secure ServerWebSocket requires a certificate, through cert or setCertificate(), before bind().");
		}
		if (backlog < 0) {
			throw new RangeError("The supplied index is out of bounds.");
		} else if (backlog == 0) {
			backlog = ServerSocket.DEFAULT_BACKLOG;
		}

		#if nodejs
		if (!bound) {
			throw new IOError("Operation attempted on invalid socket.");
		}

		__makeNodeServer();
		__webServerSocket.listen({port: localPort, host: localAddress, backlog: backlog}, function():Void {
			var assigned:Dynamic = __webServerSocket.address();

			if (assigned != null && assigned.port != null) {
				localPort = assigned.port;
			}
		});

		listening = true;
		// Not gated on __hasListener the way the native branch is: that gate is
		// about the accept loop, and this tick is only the upgrade reaper.
		// Reaping an empty list costs one length check.
		__attachTick();
		#else
		__webServerSocket.listen(backlog);
		listening = true;
		if (__hasListener) {
			__attachTick();
		}
		#end
	}

	@:noCompletion private function __fromSockettoWebsocket(socket:#if nodejs NodeSocket #else FlexSocket #end):WebSocket {
		#if !nodejs
		socket.setFastSend(true);
		socket.setBlocking(false);
		#end

		var webSocket:WebSocket = WebSocket.toWebSocket(socket, this);
		/*var cbSocket = new WebSocket(); 
			cbSocket.__socket = socket;
			cbSocket.__connected = true;
			cbSocket.__timestamp = haxe.Timer.stamp();

			cbSocket.__host = socket.peer().host.host;
			cbSocket.__port = socket.peer().port;

			cbSocket.__output = new ByteArray();
			cbSocket.__output.endian = cbSocket.__endian;

			cbSocket.__input = new ByteArray();
			cbSocket.__input.endian = cbSocket.__endian; */

		// CrossByte.current().addEventListener(TickEvent.TICK, cbSocket.this_onTick);

		return webSocket;
	}

	#if !nodejs
	/**
		The tick reaps sessions whose upgrade has stalled, and puts the
		listener back in the poll set once enough of them have gone. It no
		longer accepts: the listener is in the poll set, and is read as soon
		as connections are waiting.
	**/
	@:noCompletion override private function this_onTick(e:TickEvent):Void {
		// A tick that outlived its server has nothing to do, and its
		// listener's descriptor number may be another server's by now.
		if (__closed || !listening) {
			return;
		}

		// Extracted from a single method with a local assigned inside try/catch and
		// used afterwards: that shape mis-compiles (VerifyError) on the jvm target.
		__reapStalledUpgrades();
		__syncListenerWatch();
	}

	@:noCompletion override private function __onListenerReadable():Void {
		if (__closed || !listening) {
			return;
		}

		// As many as maxAcceptsPerTick, not one: this loop used to take one
		// connection a tick and never asked `admit`, which the class inherits
		// from ServerSocket, so a hook set here compiled, and did nothing.
		var limit:Int = maxAcceptsPerTick < 1 ? 1 : maxAcceptsPerTick;
		for (_ in 0...limit) {
			// Full: the rest wait in the kernel's queue until upgrades finish.
			if (__handshakesFull()) {
				break;
			}

			var socket:FlexSocket = __acceptPending();
			if (socket == null) {
				break;
			}

			if (!__askAdmit(socket)) {
				try {
					socket.close();
				} catch (_:Dynamic) {}
				continue;
			}

			var accepted = __fromSockettoWebsocket(socket);

			if (accepted != null && handshakeTimeout > 0) {
				__pendingUpgrades.push({session: accepted, deadline: haxe.Timer.stamp() + handshakeTimeout});
			}
		}
		__syncListenerWatch();
	}

	/** It reaps stalled upgrades from the tick, plain or secure. **/
	@:noCompletion override private function __needsAcceptTick():Bool {
		return true;
	}

	/** Its limit counts sessions still upgrading, TLS and HTTP together. **/
	@:noCompletion override private function __handshakesFull():Bool {
		return maxPendingHandshakes >= 0 && __pendingUpgrades.length >= maxPendingHandshakes;
	}

	@:noCompletion override private function __listenerSocket():sys.net.Socket {
		return __webServerSocket;
	}

	/**
		`admit`'s verdict on a connection just accepted, before any TLS or
		upgrade work is done for it. A hook that throws is a refusal. Answers
		from inside the try rather than through a local, for the jvm reason
		noted on `this_onTick`.
	**/
	@:noCompletion private function __askAdmit(socket:FlexSocket):Bool {
		try {
			var peer = socket.peer();
			return admit(crossbyte._internal.net.IPv6.compress(peer.host.toString()), peer.port);
		} catch (_:Dynamic) {
			return false;
		}
	}

	/**
		Closes sessions that were accepted and never finished arriving.

		Without this a peer completes the TCP connection, stalls, and holds a
		socket for as long as it likes, bounded only by the operating
		system's own limits, which is a slow way to lose a server rather than
		a fast one. `handshakeTimeout` is inherited from `ServerSocket` and
		means the same thing here.
	**/
	@:noCompletion private function __acceptPending():FlexSocket {
		try {
			#if eval
			// eval cannot make a socket non-blocking, its setBlocking does
			// nothing, so an accept with no connection waiting would hold
			// the runtime until one came. Asked first, as ServerSocket does.
			if (sys.net.Socket.select([__webServerSocket], [], [], 0).read.length == 0) {
				return null;
			}
			#end
			return __webServerSocket.accept();
		} catch (e:Error) {
			// One predicate, and no per-target branch: the enum switch that
			// needed a jvm workaround here (VerifyError: bad type on operand
			// stack, from matching inside a catch) now lives in a plain
			// static function where that mis-compile does not apply.
			if (!crossbyte._internal.socket.BlockedError.isBlocked(e)) {
				close();
				dispatchEvent(new Event(Event.CLOSE));
			}
		} catch (e:Dynamic) {
			// Do nothing.
		}
		return null;
	}
	#end

	/**
		The certificate this server presents to clients, with its private key.

		Set it before `bind()`, where a native server builds its TLS
		configuration: it is refused afterwards, where it used to be taken
		and then never presented. A secure server will not `listen()`
		without one.

		@throws Error When this server is not secure, or is already bound.
		@throws ArgumentError When the certificate or the key is missing.
	**/
	public var cert(default, set):{certificate:Certificate, key:Key};

	@:noCompletion private function set_cert(value:{certificate:Certificate, key:Key}):{certificate:Certificate, key:Key} {
		__requireUnboundTls("cert");
		if (value == null || value.certificate == null || value.key == null) {
			throw new ArgumentError("cert needs a certificate and its key.");
		}

		#if nodejs
		// Kept for listen(), which builds the server from it: Node takes a TLS
		// server's key and certificate when it is created.
		__tlsCertificate = value.certificate;
		__tlsKey = value.key;
		#else
		__webServerSocket.setCertificate(value.certificate.__native, value.key.__native);
		#end
		__hasCertificate = true;

		return cert = value;
	}

	#if nodejs
	/**
	 * Builds the listener, plain or TLS. The mirror of
	 * `ServerSocket.__makeNodeServer`, and deferred for the same reason: Node
	 * takes a TLS server's key and certificate when the server is created, and
	 * `cert` is assigned after the constructor.
	 */
	@:noCompletion override private function __makeNodeServer():Void {
		if (__webServerSocket != null) {
			return;
		}

		var accept = function(connection:NodeSocket):Void {
			if (!__hasListener) {
				// Node has already accepted this and there is no backlog to
				// leave it sitting in, so a session nobody is listening for is
				// refused rather than left holding a descriptor.
				connection.destroy();
				return;
			}

			// A TLS server asks on its raw `connection` event instead, below,
			// before a handshake is spent on the peer.
			if (!secure && !__nodeAdmits(connection)) {
				connection.destroy();
				return;
			}

			// Node has no listen queue to leave this in, so past the bound on
			// sessions still upgrading it is refused rather than deferred.
			if (maxPendingHandshakes >= 0 && __pendingUpgrades.length >= maxPendingHandshakes) {
				connection.destroy();
				return;
			}

			connection.setNoDelay(true);
			var accepted = __fromSockettoWebsocket(connection);

			// The push the comment on __pendingUpgrades used to say was missing.
			// Without it a peer could connect, send no upgrade request, and hold
			// the descriptor for as long as it liked, the native path has been
			// closing those for a while, and Node was the one serving the web.
			if (accepted != null && handshakeTimeout > 0) {
				__pendingUpgrades.push({session: accepted, deadline: haxe.Timer.stamp() + handshakeTimeout});
			}
		};

		if (secure) {
			if (cert == null) {
				throw new IOError("A secure ServerWebSocket requires cert before listen().");
			}

			var options:Dynamic = {key: cert.key.__pem, cert: cert.certificate.__pem};

			if (cert.key.__passphrase != null) {
				options.passphrase = cert.key.__passphrase;
			}

			if (__tlsAuthority != null) {
				options.ca = [__tlsAuthority.__pem];
				options.requestCert = true;
				options.rejectUnauthorized = true;
			}

			// tls.Server extends net.Server, so listen, close and address are
			// the same calls below this point.
			__webServerSocket = Tls.createServer(options, accept);

			// The raw TCP connection, before TLS starts on it: the point where
			// a refusal still costs nothing.
			__webServerSocket.on("connection", function(raw:NodeSocket):Void {
				if (!__nodeAdmits(raw)) {
					raw.destroy();
				}
			});
		} else {
			__webServerSocket = Net.createServer(accept);
		}

		__webServerSocket.on("error", function(_):Void {
			if (__closed) {
				return;
			}

			close();
			dispatchEvent(new Event(Event.CLOSE));
		});
	}
	#end
}
/** One accepted session and the moment its upgrade stops being awaited. */
private typedef PendingUpgrade = {
	var session:WebSocket;
	var deadline:Float;
}
#end
