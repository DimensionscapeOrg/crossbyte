package crossbyte.net;

// Not built for the browser. A page cannot listen for inbound connections; there is no API for it and no port to bind. Run a server on Node or a native target.
#if !(js && !nodejs)

import haxe.Timer;
import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import haxe.io.Error;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.errors.Error as CBError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.Socket as CBSocket;
import crossbyte.net._internal.RuntimeHandOff;
#if (target.threaded && !js)
import crossbyte.net._internal.ServerSpread;
import sys.thread.Tls;
#end
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
		half-open sockets. 0 sets no deadline, as every timeout here does: a
		client that stalls then holds its connection until it closes it.
	**/
	public var handshakeTimeout:Float = 10.0;

	/**
		Most connections taken from the listen queue each time the listener is
		found to have some waiting.

		The listener sits in the runtime's poll set, so connections are taken
		as they arrive rather than at the next tick. The operating system holds
		connections that have finished their TCP handshake in the listen queue
		until they are accepted -- as many as `listen()`'s backlog, up to the
		system's limit -- and refuses any that arrive while it is full. Taking
		one a tick, as this server used to, spent 190 ticks clearing 190
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
		of descriptors looked idle -- or, on the jvm and Node, closed the
		server.

		On a server spread over `runtimes` with `reusePort`, where each
		runtime accepts for itself, the count is theirs together.
	**/
	@:isVar public var acceptFailures(get, null):Int = 0;

	/**
		TLS handshakes that failed, or were given up on at `handshakeTimeout`,
		and so never became a `connect` event. Counted rather than reported one
		by one: an open port sees a steady trickle of them from scanners and
		broken clients, and each used to be dropped without a trace. Always 0
		on a plain server -- but a `ServerWebSocket` counts its sessions' TLS
		and upgrade together, plain or secure; see there.

		On a server spread over `runtimes`, the count is theirs together.
	**/
	@:isVar public var handshakeFailures(get, null):Int = 0;

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

		It runs on the runtime that accepts: the one that called `listen()`,
		even on a server spread over `runtimes` -- except with `reusePort`,
		where each of them accepts for itself and so asks this on its own
		thread, several at once.
	**/
	public dynamic function admit(address:String, port:Int):Bool {
		return true;
	}

	/**
		The runtimes this server's connections are served on, so that one
		listener uses more than one core. `null`, the default, serves every
		connection on the runtime that called `listen()`, as a server always
		has. Set before `listen()`.

		A runtime runs on one thread, so a server on one runtime uses one
		core however many the machine has. Spread over these, the listener
		stays where it was and accepts, and each connection it accepts is
		handed to one of them -- the one `selectRuntime` names, or the next
		in turn -- before anything else is done with it, its TLS handshake
		included. From then on it is that runtime's for its whole life: its
		socket is polled there, its events are dispatched there, its
		deadlines are kept there, and the `connect` listener that receives
		it runs there. A `close()` from any other thread is handed to it,
		as everywhere else.

		Which makes `connect` listeners, and whatever they share, code that
		runs on several threads at once. What one connection's handlers keep
		to themselves needs nothing; what they share across connections --
		a registry of players, a cache, a counter -- must be thread-safe, or
		kept per runtime and reached through `CrossByte.current()`. Add
		`connect` listeners before `listen()`.

		Make them for a server with `CrossByte.make(POLL)`, whose loop serves
		a socket as soon as it is ready, or let `runtimeCount` make them; a
		`DEFAULT` runtime serves its sockets once a tick. The listener's own
		runtime may be one of them. A runtime that has exited is passed over,
		and once every one has, each connection is closed as it is accepted
		and that is logged once. The server never exits these runtimes: they
		are the caller's.

		`admit`, `maxAcceptsPerTick` and `maxPendingHandshakes` hold for the
		server as a whole: `admit` is asked, and `maxAcceptsPerTick` counted,
		on the listener's runtime -- with `reusePort`, on each runtime as it
		accepts -- and the handshakes under way are counted across every
		runtime.
		`handshakeFailures`, `pendingHandshakeCount()` and the counts of the
		servers built on this one are the sums across them.

		On the jvm and hl, as natively, each runtime is a thread of its own
		and they run at once. neko's do too, but contend for its allocator,
		so a server there gains little past two. On the interpreter they
		take turns, so it serves correctly and no faster. On Node every
		runtime shares the one thread there is, so there is nothing to spread
		over: setting this throws `IllegalOperationError`, and several
		processes -- Node's `cluster` -- are the way to use more cores there.

		@throws ArgumentError When the list holds `null`, or a runtime twice.
		@throws IllegalOperationError When the server is already listening,
			or on Node.
	**/
	public var runtimes(get, set):Null<Array<CrossByte>>;

	/**
		How many runtimes `listen()` makes for this server, to spread its
		connections over as `runtimes` would. `0`, the default, makes none.

		Each is a `POLL` runtime made with `CrossByte.make`, a child of the
		runtime that calls `listen()`, and `runtimes` lists them once they
		are made -- to `post` per-runtime state to, say. They are the
		server's: `drain()` exits them once it has finished, where a server
		has one, and they exit with the runtime that made them in any case.
		After `close()` they go on serving the connections they hold, as a
		server's own runtime does.

		Setting this clears `runtimes`, and setting `runtimes` clears this.
		Everything `runtimes` says about where code runs holds for these.

		@throws ArgumentError When the count is negative.
		@throws IllegalOperationError When the server is already listening,
			or on Node with a count above `0`.
	**/
	public var runtimeCount(get, set):Int;

	/**
		Picks which of `runtimes` a connection is served on. Called on the
		listener's runtime as each connection is accepted -- after `admit`,
		before any TLS handshake -- with the peer's canonical address and
		port. Return one of `runtimes`, or `null` for the next in turn, which
		is what the default does.

		An answer that is not one of `runtimes`, or one that has exited, is
		replaced by the next in turn. A hook that throws refuses the
		connection, as `admit` does.

		Where the peer's address says which runtime it belongs on -- a game
		server whose matchmaker has told it which match each player's
		address is joining, and runs each match on a runtime of its own --
		this sends the player to the runtime that owns their match, so the
		match's state is only ever touched from one thread:

		```haxe
		server.runtimes = matchRuntimes;
		server.selectRuntime = (address, port) -> joining.get(address);
		```

		Not asked with `reusePort`, where the system decides.
	**/
	public dynamic function selectRuntime(address:String, port:Int):Null<CrossByte> {
		return null;
	}

	/**
		Whether each of `runtimes` listens on the port for itself, the system
		sharing the connections out among them, rather than this server's
		runtime accepting them all and handing them on. `false` by default.
		Set before `bind()`.

		This is `SO_REUSEPORT`, on Linux: one listening socket per runtime,
		the kernel spreading arriving connections over them by a hash of each
		connection's addresses. No runtime accepts for the others, so an
		accept storm is spread too. In exchange the kernel, not
		`selectRuntime`, decides where a connection goes, and each runtime
		asks `admit` for itself, on its own thread.

		It needs `runtimes` or `runtimeCount`, and is refused by `listen()`
		without one. Natively on Linux, and on the jvm on Linux from Java 9,
		which first exposes the option. macOS and the BSDs accept the option
		without spreading anything -- every connection goes to one of the
		sockets -- and Windows has nothing like it, so there, and on every
		other target, setting this to `true` throws `IllegalOperationError`;
		the hand-off `runtimes` makes by default works everywhere.

		@throws IllegalOperationError Where the system or the target cannot
			do it, or when the server is already bound.
	**/
	public var reusePort(default, set):Bool = false;

	/**
		The backlog `listen()` asks for when given none: more than any system
		grants, so the system's own maximum is what applies -- `somaxconn` on
		Linux, whichever value is asked; on Windows 65535, asked as
		`SOMAXCONN_HINT` (see `__nativeBacklog`), natively, on HashLink and on
		neko, and 200 on the jvm and the interpreter.
		`0x7FFFFFF` rather than the largest Int, which neko's 31-bit integers
		cannot carry: `listen()` threw there, so no server could start.
	**/
	@:noCompletion private static inline var DEFAULT_BACKLOG:Int = 0x7FFFFFF;

	/**
		The number to hand the system's `listen()` for `backlog`.

		Windows grants at most 200 to a backlog asked as a number --
		`0x7FFFFFF` included -- and refuses a connection arriving while 200
		wait. Asked as `SOMAXCONN_HINT(n)`, which is `-n`, it grants `n`, from
		200 to 65535. With nothing accepting, a listener asked for the default
		took 200 connections and refused the rest; asked this way, every one
		of 400. Natively, on HashLink and on neko the number reaches `listen()`
		as it is. The jvm's `bind` takes a negative backlog as "the default",
		50, and the interpreter's is not known to pass it on, so both ask
		plainly.
	**/
	@:noCompletion private static function __nativeBacklog(backlog:Int):Int {
		#if (cpp || hl || neko)
		if (backlog > 200 && crossbyte.sys.System.isWindows) {
			return -(backlog > 65535 ? 65535 : backlog);
		}
		#end
		return backlog;
	}

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
	#end
	// Whether the last accept failed, so a run of failures is reported once.
	@:noCompletion private var __acceptFailing:Bool = false;
	@:noCompletion private var __hasCertificate:Bool = false;
	#if !nodejs
	@:noCompletion private var __pendingHandshakes:Array<PendingHandshake>;
	// The peer `admit` was last asked about and agreed to; see __admits.
	@:noCompletion private var __admittedPeer:Null<{host:Host, port:Int}> = null;
	// Each TLS setting made on the listener, kept so a listener of each
	// runtime's own, with reusePort, can be given the same; see
	// __newListener.
	@:noCompletion private var __tlsReplay:Array<Socket->Void> = [];
	#end
	@:noCompletion private var __listenerReleased:Bool = false;

	// What `runtimes` and `runtimeCount` were set to, until listen() acts on
	// them.
	@:noCompletion private var __givenRuntimes:Array<CrossByte> = null;
	@:noCompletion private var __runtimeCount:Int = 0;

	// On a replica, the server it serves connections for; null on every
	// server an application makes. Declared everywhere, so the servers built
	// on this one can ask it on every target; set only where a server can be
	// spread.
	@:noCompletion private var __front:ServerSocket = null;

	// The listener the class itself attaches for `connect` -- HTTPServer's,
	// ServerWebSocket's -- which on a spread server runs on each replica
	// rather than on this one; and the `connect` listeners the application
	// added, as an array no one changes once it is published, which the
	// replicas walk from their own threads. See __dispatchShared.
	@:noCompletion private var __ownConnect:Dynamic = null;
	@:noCompletion private var __sharedConnect:Array<Dynamic> = null;
	#if (target.threaded && !js)
	// On the front of a spread server: the runtimes and their replicas.
	@:noCompletion private var __spread:ServerSpread = null;
	// On a replica: its front's.
	@:noCompletion private var __shared:ServerSpread = null;
	// On a replica: its handshakes in flight as last told to __shared.
	@:noCompletion private var __publishedPending:Int = 0;
	// The front a replica is being made for, on the thread making it; see
	// __makeReplica.
	@:noCompletion private static final __replicaOf:Tls<ServerSocket> = new Tls();
	#end
	#if nodejs
	// Collected as it arrives and handed to tls.createServer in listen(),
	// because that is the moment Node will take it.
	@:noCompletion private var __tlsCertificate:Certificate;
	@:noCompletion private var __tlsKey:Key;
	@:noCompletion private var __tlsAuthority:Certificate;
	@:noCompletion private var __tlsSni:Array<{match:String->Bool, certificate:Certificate, key:Key}> = [];
	@:noCompletion private var __tlsAlpn:Array<String>;
	// Whether Node has said the server is listening: an error before that is
	// the listen failing, and one after it a connection it could not take.
	@:noCompletion private var __nodeListening:Bool = false;
	#end

	/**
		Creates a ServerSocket object.

		@param secure When `true`, the server terminates TLS: a certificate
			must be installed with `setCertificate()` before `bind()`, and
			`connect` events are dispatched only after each client's handshake
			completes. Handshakes progress across ticks and never block the
			runtime loop.
		@throws  Error On the eval target, when `secure` is true: eval's `sys.ssl.Socket`
				cannot install a certificate, so a TLS server there is refused at construction
				rather than several calls later.
	**/
	public function new(secure:Bool = false) {
		super();

		#if (target.threaded && !js)
		// Made by a front for one of its runtimes (see __makeReplica): it gets
		// no listener of its own, and serves what the front hands it.
		__front = __replicaOf.value;
		#end

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
		if (__front != null) {
			// A replica accepts nothing: no listener, so no descriptor.
			__serverSocket = null;
			__closed = false;
			bound = false;
			listening = false;
			return;
		}
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
		clients. Must be called on a secure server before `bind()`: the TLS
		configuration is made when the listener is bound, and material
		installed afterwards would never be presented. `listen()` refuses a
		secure server that has none.

		@param cert The certificate chain to present.
		@param key The matching private key.
		@throws Error When this server was not constructed with `secure` set,
			or when it is already bound.
	**/
	public function setCertificate(cert:Certificate, key:Key):Void {
		__requireSecure("setCertificate");

		#if nodejs
		__tlsCertificate = cert;
		__tlsKey = key;
		#else
		__applyTls(socket -> (cast socket : SSLSocket).setCertificate(cert.__native, key.__native));
		#end
		__hasCertificate = true;
	}

	#if !nodejs
	/**
		Makes a TLS setting on the listener, and keeps it for the listener of
		each runtime's own that `reusePort` makes.
	**/
	@:noCompletion private function __applyTls(setting:Socket->Void):Void {
		setting(__listenerSocket());
		__tlsReplay.push(setting);
	}
	#end

	/**
		Adds an additional certificate selected by Server Name Indication,
		allowing one listener to serve several hostnames. Before `bind()`,
		as `setCertificate()`.

		@param serverNameMatch Predicate matching the client-offered hostname.
		@param cert The certificate chain to present on a match.
		@param key The matching private key.
		@throws Error When this server was not constructed with `secure` set,
			or when it is already bound.
	**/
	public function addSNICertificate(serverNameMatch:String->Bool, cert:Certificate, key:Key):Void {
		__requireSecure("addSNICertificate");

		#if nodejs
		__tlsSni.push({match: serverNameMatch, certificate: cert, key: key});
		#else
		__applyTls(socket -> (cast socket : SSLSocket).addSNICertificate(serverNameMatch, cert.__native, key.__native));
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
		__applyTls(function(socket:Socket):Void {
			var sslSocket:SSLSocket = cast socket;
			sslSocket.setCA(ca.__native);
			sslSocket.verifyCert = true;
		});
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
		__applyTls(socket -> (cast socket : AlpnSocket).setALPN(protocols));
		#elseif (java || jvm)
		__applyTls(socket -> (cast socket : SSLSocket).setALPN(protocols));
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

		On Node a server takes its address when it starts listening, and
		says whether it could only afterwards: this records the endpoint and
		cannot fail, and `listen()` claims it. A port in use, or an address
		that is not local, is then dispatched as an `ioError` saying so,
		followed by `close`, as a `DatagramSocket`'s bind is; `listening` is
		`true` from `listen()` until then. A port of 0 reads 0 in `localPort`
		until the server is listening.
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
		// two visible differences on Node: a bind failure arrives as an
		// ioError and a close event rather than out of this call, and a port
		// of 0 stays 0 in localPort until listen() has been able to ask what
		// was assigned.
		this.localAddress = localAddress;
		this.localPort = localPort;
		bound = true;
		#else
		try {
			var host:Host = new Host(localAddress);
			__bindListener(__serverSocket, host, localPort);

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
			if (__closed || !listening || __cbInstance == null) {
				// Arrived after close() or stopAccepting(): a TLS handshake
				// that was under way finishes after Node has stopped
				// listening. It was adopted anyway -- with no runtime, since
				// close() had let go of it -- and announced as a connection
				// to a server that had stopped; it is let go of, as a
				// handshake in flight is natively.
				connection.destroy();
				return;
			}

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

			__acceptFailing = false;
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
			// handshakeTimeout, which Node takes in milliseconds. It was not
			// passed, so Node's own two minutes applied: a client that opened
			// a connection and never sent its half of the handshake held it
			// twelve times longer than the server was configured to allow.
			// 0 is no deadline, which Node takes as 0 too.
			options.handshakeTimeout = handshakeTimeout > 0 ? Std.int(Math.max(1, handshakeTimeout * 1000)) : 0;
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
		// So does a connection Node could not take once listening, a process
		// out of descriptors, which closed the server: natively and on the
		// jvm the server goes on, and so it does here.
		__serverSocket.on("error", function(error:Dynamic):Void {
			if (__closed) {
				return;
			}

			var message:Dynamic = error == null ? null : Reflect.field(error, "message");
			try {
				if (__nodeListening) {
					__onAcceptFailed(message == null ? "unknown error" : message);
					return;
				}

				// The listen failed, so there is no server: an ioError saying
				// why, then CLOSE, as a DatagramSocket's bind reports it. It was
				// CLOSE alone, which said the server had stopped and not that
				// it never started, nor why.
				close();
				dispatchEvent(new crossbyte.events.IOErrorEvent(crossbyte.events.IOErrorEvent.IO_ERROR,
					"Could not listen on " + localAddress + ":" + localPort + ": " + Std.string(message)));
				dispatchEvent(new Event(Event.CLOSE));
			} catch (e:Dynamic) {
				// Contained: this runs from Node's own loop.
				CrossByte.__socketListenerThrew(e, this, "A listener of a server that failed threw");
			}
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

	/**
		Closes the socket and stops listening for connections. A connection
		still completing its TLS handshake is dropped, and no `close` event is
		dispatched: that is for the system closing the listener.
		Closed sockets cannot be reopened. Create a new ServerSocket instance instead.

		It may be called from any thread, as `Socket.close()` may. From one
		that is not the runtime's the server listens on, the close is handed
		to the runtime, as `CrossByte.post` hands work over, and happens there
		after this returns: a connection may still be announced until then.
		A runtime's poll set and tick listeners are not thread-safe, and a
		close made elsewhere took the listener out of them from the wrong
		thread, while the runtime might be polling it.
		@throws Error This error occurs if the socket could not be closed, or the socket was not open.
			From another thread nothing is thrown here: a close that fails on
			the runtime is reported as any posted callback's failure is.
	**/
	public function close():Void {
		var runtime:Null<CrossByte> = __cbInstance;
		if (RuntimeHandOff.offThread(runtime) && runtime.post(__closeOnRuntime)) {
			return;
		}

		#if (target.threaded && !js)
		if (__front != null) {
			// A replica: its share of the server stops, on its own runtime.
			__stopReplica();
			__closed = true;
			return;
		}
		#end

		#if !nodejs
		__dropPendingHandshakes();
		// Out of the poll set before the listener is closed; see
		// Socket.__cleanSocket.
		__detachAcceptTick();
		#end
		#if (target.threaded && !js)
		// Every runtime drops the handshakes it has under way, as this one
		// just did, and closes whatever reaches it from here on.
		if (__spread != null) {
			__spread.close();
		}
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
		A close handed over from another thread, on the runtime: nothing if
		the server was closed there meanwhile.
	**/
	@:noCompletion private function __closeOnRuntime():Void {
		if (!__closed) {
			close();
		}
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

		On Windows, natively, on HashLink and on neko, a backlog above 200 is
		granted up to 65535, and the default is 65535. Windows grants 200 to
		any larger number asked plainly, which is all the jvm and the
		interpreter can ask, so a burst of connections past 200 was refused by
		the kernel before the server saw it.

		On Node a port that cannot be had is reported after this returns, as
		an `ioError` and then `close`; see `bind()`.
		@throws RangeError	The backlog is negative.
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
			// Natively too, where it was left to the system: Windows refused
			// a listen on a socket never bound, and Linux and macOS bound it
			// to a port of their choosing and listened there, so the same
			// call failed on one system and served a port nobody had asked
			// for -- and that localPort did not report -- on the others.
			if (!bound) {
				throw new IOError("Operation attempted on invalid socket: listen() needs bind() first.");
			}
			if (secure && !__hasCertificate) {
				throw new IOError("A secure ServerSocket requires setCertificate() before bind().");
			}
			if (backlog < 0) {
				throw new RangeError("A listen backlog cannot be negative: " + backlog + ".");
			} else if (backlog == 0) {
				backlog = DEFAULT_BACKLOG;
			}

			#if nodejs
			__makeNodeServer();
			__nodeListening = false;
			__serverSocket.listen({port: localPort, host: localAddress, backlog: backlog}, function():Void {
				__nodeListening = true;
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
			__checkSpread();
			if (reusePort) {
				__listenOnEachRuntime(backlog);
				return;
			}
			__serverSocket.listen(__nativeBacklog(backlog));
			/* @:privateAccess
				__cbInstance.beginSocketPolling();
				@:privateAccess
				__cbInstance.registerSocket(__serverSocket); */
			listening = true;
			__startSpread();
			if (__hasListener) {
				__attachAcceptTick();
			}
			#end
		}
	}

	@:noCompletion private function get_runtimes():Null<Array<CrossByte>> {
		#if (target.threaded && !js)
		if (__spread != null) {
			return __spread.runtimes.copy();
		}
		#end
		return __givenRuntimes == null ? null : __givenRuntimes.copy();
	}

	@:noCompletion private function set_runtimes(value:Null<Array<CrossByte>>):Null<Array<CrossByte>> {
		__refuseSpreadChange("runtimes");
		if (value == null || value.length == 0) {
			__givenRuntimes = null;
			return value;
		}
		#if !(target.threaded && !js)
		throw new IllegalOperationError(#if nodejs "On Node every runtime shares the one thread, so a server cannot be spread over runtimes; run several processes (Node's cluster) to use more cores." #else "A server can be spread over runtimes only on a target with threads." #end);
		#else
		for (i in 0...value.length) {
			if (value[i] == null) {
				throw new ArgumentError("runtimes holds null at index " + i + ".");
			}
			if (value.indexOf(value[i]) != i) {
				throw new ArgumentError("runtimes holds the same runtime twice, at " + value.indexOf(value[i]) + " and " + i + ".");
			}
		}
		__givenRuntimes = value.copy();
		__runtimeCount = 0;
		return value;
		#end
	}

	@:noCompletion private function get_runtimeCount():Int {
		#if (target.threaded && !js)
		if (__spread != null) {
			return __spread.runtimes.length;
		}
		#end
		return __givenRuntimes != null ? __givenRuntimes.length : __runtimeCount;
	}

	@:noCompletion private function set_runtimeCount(value:Int):Int {
		__refuseSpreadChange("runtimeCount");
		if (value < 0) {
			throw new ArgumentError("runtimeCount cannot be negative: " + value + ".");
		}
		#if !(target.threaded && !js)
		if (value > 0) {
			throw new IllegalOperationError(#if nodejs "On Node every runtime shares the one thread, so a server cannot be spread over runtimes; run several processes (Node's cluster) to use more cores." #else "A server can be spread over runtimes only on a target with threads." #end);
		}
		#end
		__runtimeCount = value;
		if (value > 0) {
			__givenRuntimes = null;
		}
		return value;
	}

	@:noCompletion private function set_reusePort(value:Bool):Bool {
		if (value == reusePort) {
			return value;
		}
		if (bound || listening || __closed || __listenerReleased) {
			throw new IllegalOperationError("reusePort must be set before bind(): the option is the socket's before it takes its address.");
		}
		if (value) {
			var refusal:Null<String> = __reusePortRefusal();
			if (refusal != null) {
				throw new IllegalOperationError(refusal);
			}
		}
		return reusePort = value;
	}

	/** Why `reusePort` cannot be had here, or null where it can. **/
	@:noCompletion private static function __reusePortRefusal():Null<String> {
		#if (cpp && linux)
		return null;
		#elseif (java || jvm)
		return crossbyte.net._internal.ReusePort.jvmRefusal();
		#elseif nodejs
		return "reusePort spreads a server over runtimes, which Node cannot do: its runtimes share one thread.";
		#elseif cpp
		return "reusePort is SO_REUSEPORT on Linux; macOS and the BSDs accept it without spreading connections, and Windows has nothing like it. Leave it off: runtimes hands connections out on every system.";
		#else
		return "reusePort is available natively and on the jvm, on Linux; this target cannot set the option. Leave it off: runtimes hands connections out on every target.";
		#end
	}

	/** Spreading is settled as the server starts listening. **/
	@:noCompletion private function __refuseSpreadChange(field:String):Void {
		if (listening || __closed || __listenerReleased) {
			throw new IllegalOperationError(field + " must be set before listen(): the server spreads its connections as it starts.");
		}
	}

	#if !nodejs
	/**
		Binds a listener of this server's: with `SO_REUSEPORT` set first when
		`reusePort` asks for it, so the listeners of every runtime can share
		the port.
	**/
	@:noCompletion private function __bindListener(listener:Socket, host:Host, port:Int):Void {
		#if (target.threaded && !js)
		if (reusePort) {
			crossbyte.net._internal.ReusePort.bind(listener, host, port);
			return;
		}
		#end
		listener.bind(host, port);
	}

	/**
		With `reusePort`: a listener for each runtime, each bound to this
		server's address with the option set, listening, and handed to that
		runtime's replica, which accepts from it on its own thread. This
		server's own socket stays bound and never listens: the system shares
		connections only among sockets that do.

		Each listener is opened here, so a port that cannot be shared is
		refused by this call rather than later on another thread.
	**/
	@:noCompletion private function __listenOnEachRuntime(backlog:Int):Void {
		#if (target.threaded && !js)
		__startSpread();
		var spread:ServerSpread = __spread;
		var host:Host = new Host(localAddress);
		var opened:Array<Socket> = [];
		try {
			for (_ in spread.replicas) {
				var listener:Socket = __newListener();
				opened.push(listener);
				__bindListener(listener, host, localPort);
				listener.listen(__nativeBacklog(backlog));
			}
		} catch (error:Dynamic) {
			for (listener in opened) {
				try {
					listener.close();
				} catch (_:Dynamic) {}
			}
			__spread = null;
			spread.exitOwned();
			throw new IOError("Could not give each runtime a listener on " + localAddress + ":" + localPort + " with reusePort: " + Std.string(error));
		}

		listening = true;
		for (i in 0...spread.replicas.length) {
			var replica:ServerSocket = spread.replicas[i];
			replica.__takeListener(opened[i]);
			if (!spread.runtimes[i].post(replica.__startListening)) {
				// Exited already: nothing will ever accept from it.
				replica.__takeListener(null);
				try {
					opened[i].close();
				} catch (_:Dynamic) {}
			}
		}
		#end
	}

	/**
		A new listener of this server's kind, set up as its own listener was:
		non-blocking, and with every TLS setting it was given.
	**/
	@:noCompletion private function __newListener():Socket {
		var listener:Socket = #if cpp secure ? new AlpnSocket() : new sys.net.Socket() #else secure ? new SSLSocket() : new sys.net.Socket() #end;
		if (secure) {
			// As the constructor does: a server asks for client certificates
			// only when told to, which the settings below may do.
			(cast listener : SSLSocket).verifyCert = false;
		}
		listener.setBlocking(false);
		listener.setFastSend(true);
		for (setting in __tlsReplay) {
			setting(listener);
		}
		return listener;
	}

	/** Makes `listener` this server's own: a replica's, with `reusePort`. **/
	@:noCompletion private function __takeListener(listener:Null<Socket>):Void {
		__serverSocket = listener;
		bound = listener != null;
	}

	/** On a replica given a listener, on its runtime: starts accepting from it. **/
	@:noCompletion private function __startListening():Void {
		if (__closed || !listening) {
			return;
		}
		__attachAcceptTick();
	}

	/**
		What `listen()` refuses before the listener is opened: `reusePort`
		with no runtimes to give a listener each.
	**/
	@:noCompletion private function __checkSpread():Void {
		if (reusePort && __givenRuntimes == null && __runtimeCount <= 0) {
			throw new IOError("reusePort gives each of runtimes a listener of its own, and this server has none: set runtimes or runtimeCount.");
		}
	}

	/**
		Makes the replicas `runtimes` or `runtimeCount` ask for, once the
		listener is open; nothing for a server on one runtime.
	**/
	@:noCompletion private function __startSpread():Void {
		#if (target.threaded && !js)
		if (__spread != null || __front != null) {
			return;
		}

		var runtimes:Array<CrossByte> = null;
		var owned:Bool = false;
		if (__givenRuntimes != null) {
			runtimes = __givenRuntimes.copy();
		} else if (__runtimeCount > 0) {
			runtimes = [for (_ in 0...__runtimeCount) CrossByte.make(POLL)];
			owned = true;
		}
		if (runtimes == null) {
			return;
		}

		var spread:ServerSpread = new ServerSpread(this, runtimes, owned);
		for (runtime in runtimes) {
			spread.replicas.push(__makeReplica(runtime, spread));
		}
		__spread = spread;
		#end
	}
	#end

	#if (target.threaded && !js)
	/**
		A replica of this server for `runtime`, made here on this server's
		runtime and complete before any other thread sees it: every field it
		has is set by the time it is handed over, which neko needs of an
		object another thread writes.
	**/
	@:noCompletion private function __makeReplica(runtime:CrossByte, spread:ServerSpread):ServerSocket {
		__replicaOf.value = this;
		var replica:ServerSocket = null;
		try {
			replica = __replicate();
		} catch (error:Dynamic) {
			__replicaOf.value = null;
			#if cpp
			cpp.Lib.rethrow(error);
			#else
			throw error;
			#end
		}
		__replicaOf.value = null;

		replica.__shared = spread;
		replica.__cbInstance = runtime;
		replica.localAddress = localAddress;
		replica.localPort = localPort;
		replica.listening = true;
		replica.handshakeTimeout = handshakeTimeout;
		replica.maxAcceptsPerTick = maxAcceptsPerTick;
		// The limit is the front's, over every runtime together.
		replica.maxPendingHandshakes = -1;
		// Asked by a replica only when it accepts for itself, with reusePort:
		// the front's hook, as it stands when each connection arrives.
		var front:ServerSocket = this;
		replica.admit = function(address:String, port:Int):Bool {
			return front.admit(address, port);
		};
		return replica;
	}

	/**
		A new server of this one's class, without a listener: one runtime's
		share of it. Overridden by the servers built on this one, which keep
		state of their own per connection.
	**/
	@:noCompletion private function __replicate():ServerSocket {
		return new ServerSocket(secure);
	}

	/**
		On a replica, on its runtime: `socket`, accepted by the front and
		handed here, becomes this runtime's. One that arrives once the server
		has stopped is closed.
	**/
	@:noCompletion private function __adopt(socket:Socket, peer:{host:Host, port:Int}):Void {
		var shared:ServerSpread = __shared;
		var tracked:Bool = __front.__tracksHandshakes();
		// Run as its runtime exits, too: what was posted before an exit still
		// runs. A connection taken up then would sit in a poll set about to be
		// let go of, open and never read, so it is closed instead.
		if (__closed || !listening || shared.stopped || !@:privateAccess __cbInstance.__getRunning()) {
			if (tracked) {
				shared.addInFlight(-1, __front.maxPendingHandshakes);
			}
			try {
				socket.close();
			} catch (_:Dynamic) {}
			return;
		}

		__attachAcceptTick();
		__adoptConnection(socket, peer);
	}

	/**
		What a replica does with a connection handed to it: a TLS handshake
		begins, as the front's would have; a plain connection is announced.
	**/
	@:noCompletion private function __adoptConnection(socket:Socket, peer:{host:Host, port:Int}):Void {
		if (secure) {
			socket.setBlocking(false);
			var pending:PendingHandshake = new PendingHandshake(this, socket,
				handshakeTimeout > 0 ? haxe.Timer.stamp() + handshakeTimeout : Math.POSITIVE_INFINITY, peer);
			__pendingHandshakes.push(pending);
			socket.custom = pending;
			pending.runtime = __cbInstance;
			@:privateAccess
			__cbInstance.registerSocket(socket);
			// It was counted in flight as it was handed over; now it is
			// counted here instead.
			__publishPending(1);
			// The client's first flight may be waiting already.
			__stepHandshake(pending);
			return;
		}

		var cbSocket:Null<CBSocket> = __fromSocket(socket, peer);
		if (cbSocket == null) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
			return;
		}
		__announceHere(cbSocket);
	}

	/**
		A replica's `connect`, contained as a socket handler is: a listener
		that throws is reported on this runtime and its connection closed,
		rather than the failure ending the posted hand-off with the
		connection left open and announced to no one after it.
	**/
	@:noCompletion private function __announceHere(socket:CBSocket):Void {
		try {
			dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));
		} catch (error:Dynamic) {
			if (__cbInstance != null) {
				__cbInstance.__uncaught(error, crossbyte.events.UncaughtErrorEvent.SOCKET, socket);
			}
			try {
				socket.close();
			} catch (_:Dynamic) {}
		}
	}

	/**
		A spread server's drain, for the servers built on this one: each
		replica drains what it holds on its own runtime, as a server on one
		runtime drains its own, by `drainOne`, which calls the function it is
		given once it has finished; `finish` runs here once every one has --
		or, should one never say so, a second after the deadline they were
		all given, so the wait ends either way.
	**/
	@:noCompletion private function __drainReplicas(timeoutSeconds:Float, drainOne:(ServerSocket, Void->Void) -> Void, finish:Void->Void):Void {
		var spread:ServerSpread = __spread;
		var runtime:CrossByte = __cbInstance;
		if (runtime == null) {
			// Closed already: nothing on this side to wait on, and nowhere to be
			// told. Each runtime still drains what it holds.
			spread.each(replica -> drainOne(replica, () -> {}));
			finish();
			return;
		}
		var waiting:Int = spread.replicas.length;
		var finished:Bool = false;
		var onTick:TickEvent->Void = null;

		function end():Void {
			if (finished) {
				return;
			}
			finished = true;
			if (onTick != null) {
				runtime.removeEventListener(TickEvent.TICK, onTick);
			}
			finish();
		}

		// Told on this runtime as each finishes. One whose runtime has
		// exited has nothing left to drain.
		function drained():Void {
			waiting--;
			if (waiting <= 0) {
				end();
			}
		}

		if (waiting <= 0) {
			end();
			return;
		}
		spread.each(replica -> drainOne(replica, () -> runtime.post(drained)), _ -> drained());
		if (finished) {
			return;
		}

		var deadline:Float = haxe.Timer.stamp() + (timeoutSeconds > 0 ? timeoutSeconds : 0) + 1.0;
		onTick = function(_:TickEvent):Void {
			if (haxe.Timer.stamp() >= deadline) {
				end();
			}
		};
		runtime.addEventListener(TickEvent.TICK, onTick);
	}

	/**
		On a replica, on its runtime: the front has stopped accepting, or
		closed. What is still handshaking here is dropped, as the front drops
		its own.
	**/
	@:noCompletion private function __stopReplica():Void {
		__dropPendingHandshakes();
		__detachAcceptTick();
		listening = false;
		__releaseReplicaListener();
		__publishPending();
	}

	/**
		A replica's own listener, with `reusePort`, closed once it has left
		the poll set -- which `__detachAcceptTick` takes it out of first.
	**/
	@:noCompletion private function __releaseReplicaListener():Void {
		var listener:Null<Socket> = __listenerSocket();
		if (listener == null) {
			return;
		}
		__takeListener(null);
		try {
			listener.close();
		} catch (_:Dynamic) {}
	}

	/**
		On a replica: tells the front how many handshakes are under way here,
		so `maxPendingHandshakes` counts every runtime's. `arrivals` were
		counted by the front as it handed them over, and are taken off that
		count as this one takes them up.
	**/
	@:noCompletion private function __publishPending(arrivals:Int = 0):Void {
		var shared:ServerSpread = __shared;
		if (shared == null || !__front.__tracksHandshakes()) {
			return;
		}
		var now:Int = __localPendingCount();
		var delta:Int = now - __publishedPending - arrivals;
		__publishedPending = now;
		if (delta != 0) {
			shared.addInFlight(delta, __front.maxPendingHandshakes);
		}
	}

	/**
		On the front, on the listener's runtime: hands `socket`, accepted and
		admitted, to one of the runtimes. Counted in flight on the way when
		the server waits on a handshake for it.
	**/
	@:noCompletion private function __handOff(socket:Socket, peer:{host:Host, port:Int}):Void {
		var spread:ServerSpread = __spread;
		var tracked:Bool = __tracksHandshakes();
		if (tracked) {
			spread.addInFlight(1, maxPendingHandshakes);
		}
		var address:String = crossbyte._internal.net.IPv6.compress(peer.host.toString());
		if (spread.handOff(socket, peer, address)) {
			return;
		}

		if (tracked) {
			spread.addInFlight(-1, maxPendingHandshakes);
		}
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}
	#end

	/**
		Whether this server waits on a handshake for each connection before
		announcing it: a TLS one's. What `maxPendingHandshakes` counts.
	**/
	@:noCompletion private function __tracksHandshakes():Bool {
		return secure;
	}

	/** Handshakes under way on this server itself, not counting replicas'. **/
	@:noCompletion private function __localPendingCount():Int {
		#if nodejs
		return 0;
		#else
		return __pendingHandshakes == null ? 0 : __pendingHandshakes.length;
		#end
	}

	/**
		On the front of a spread server: dispatches `event` -- a `connect`
		on one of the replicas, on its runtime -- to the `connect` listeners
		the application added to this server. Walked from the published
		array, which nothing changes once it is published, rather than from
		the dispatcher's own lists, which this thread does not own.
	**/
	@:noCompletion private function __dispatchShared(event:ServerSocketConnectEvent):Bool {
		var listeners:Array<Dynamic> = __sharedConnect;
		if (listeners == null || listeners.length == 0) {
			return false;
		}
		@:privateAccess {
			event.target = this;
			event.currentTarget = this;
		}
		for (listener in listeners) {
			listener(event);
		}
		return true;
	}

	/**
		Publishes the `connect` listeners the application has added, in the
		order they run, leaving out the one this class attached for itself.
	**/
	@:noCompletion private function __refreshSharedConnect():Void {
		var listed:Array<Dynamic> = __eventMap == null ? null : cast __eventMap.get(ServerSocketConnectEvent.CONNECT);
		if (listed == null || listed.length == 0) {
			__sharedConnect = null;
			return;
		}
		var published:Array<Dynamic> = [];
		for (entry in listed) {
			var listener:Dynamic = entry == null ? null : entry.listener;
			if (listener == null || __isOwnConnect(listener)) {
				continue;
			}
			published.push(listener);
		}
		__sharedConnect = published;
	}

	@:noCompletion private function __isOwnConnect(listener:Dynamic):Bool {
		var own:Dynamic = __ownConnect;
		return own != null && (listener == own || Reflect.compareMethods(listener, own));
	}

	/**
		How a server built on this one attaches its own `connect` listener:
		as any listener, and noted, so a spread server runs it on each
		replica rather than among the application's.
	**/
	@:noCompletion private function __addOwnConnectListener(listener:ServerSocketConnectEvent->Void):Void {
		__ownConnect = listener;
		addEventListener(ServerSocketConnectEvent.CONNECT, listener);
	}

	/**
		A replica's `connect` goes to its own listener -- the class's -- and
		then to those the application added to the front. Every other event,
		and every event on a server that is not a replica, is dispatched as
		ever.
	**/
	override public function dispatchEvent<T:Event>(event:T):Bool {
		var front:ServerSocket = __front;
		if (front != null && event != null && event.type == ServerSocketConnectEvent.CONNECT) {
			var handled:Bool = super.dispatchEvent(event);
			return front.__dispatchShared(cast event) || handled;
		}
		return super.dispatchEvent(event);
	}

	@:noCompletion private function get_acceptFailures():Int {
		var total:Int = acceptFailures;
		#if (target.threaded && !js)
		if (__spread != null) {
			for (replica in __spread.replicas) {
				total += replica.acceptFailures;
			}
		}
		#end
		return total;
	}

	@:noCompletion private function get_handshakeFailures():Int {
		var total:Int = handshakeFailures;
		#if (target.threaded && !js)
		if (__spread != null) {
			for (replica in __spread.replicas) {
				total += replica.handshakeFailures;
			}
		}
		#end
		return total;
	}

	#if !nodejs
	@:noCompletion private function __fromSocket(socket:sys.net.Socket, ?accepted:{host:sys.net.Host, port:Int}):Null<CBSocket> {
		// Asked once, and first. A peer already gone has no address on Linux
		// and macOS -- getpeername fails once a connection is reset, and
		// Linux hands over one reset before it was accepted -- and peer()
		// answers null, which was read through twice below and ended the
		// process: any client that connected and reset at once took a native
		// server on Linux down. A TLS 1.3
		// client finishes its handshake before the server does, and one that
		// hangs up at once is often gone by the time its connection is
		// promoted: it is announced all the same, from the address it was
		// accepted with, as Windows announces it and as TLS 1.2 always did,
		// and its first read finds it gone. With no address at all there is
		// nothing to announce; the caller closes the socket.
		var peer = socket.peer();
		if (peer == null) {
			peer = accepted;
		}
		if (peer == null) {
			return null;
		}

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
		cbSocket.__host = crossbyte._internal.net.IPv6.compress(peer.host.toString());
		cbSocket.__port = peer.port;

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

			#if (target.threaded && !js)
			if (__spread != null) {
				// Another runtime's from here, TLS handshake and all.
				var peer = __admittedPeer;
				__admittedPeer = null;
				__handOff(sysSocket, peer);
				return true;
			}
			#end

			if (secure) {
				// Defer the connect event: the peer is not authenticated (and
				// no application bytes are readable) until TLS completes.
				sysSocket.setBlocking(false);
				var pending:PendingHandshake = new PendingHandshake(this, sysSocket,
					handshakeTimeout > 0 ? haxe.Timer.stamp() + handshakeTimeout : Math.POSITIVE_INFINITY, sysSocket.peer());
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

			var socket:Null<CBSocket> = __fromSocket(sysSocket);
			if (socket == null) {
				// Gone already; the next one may not be.
				try {
					sysSocket.close();
				} catch (_:Dynamic) {}
				return true;
			}
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
		Asks `admit` about a connection just accepted, and closes it if the
		answer is no -- or if asking threw.
	**/
	@:noCompletion private function __admits(sysSocket:Socket):Bool {
		var admitted:Bool = false;
		__admittedPeer = null;
		try {
			// Null for a peer already gone (see __fromSocket), which the catch
			// below never caught: reading through null is no exception on hxcpp.
			var peer = sysSocket.peer();
			admitted = peer != null && admit(crossbyte._internal.net.IPv6.compress(peer.host.toString()), peer.port);
			if (admitted) {
				// Kept for the hand-off to another runtime, which asks again
				// otherwise.
				__admittedPeer = peer;
			}
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

	/**
		A connection the system would not hand over, though one was waiting:
		counted, and reported once for a run of them. The server stays up. The
		connection stays in the kernel's queue and is asked for again next
		tick, which is all there is to do about a process out of descriptors.

		On Node it arrives as the server's error event, and closed the
		server; it is counted and reported here the same way.

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
		#if (target.threaded && !js)
		var front:ServerSocket = __front;
		if (front != null) {
			// A replica accepting for itself, with reusePort: the application
			// listens on the front, which is told on its own runtime.
			var runtime:Null<CrossByte> = front.__cbInstance;
			if (runtime != null) {
				runtime.post(() -> front.dispatchEvent(new crossbyte.events.IOErrorEvent(crossbyte.events.IOErrorEvent.IO_ERROR, message)));
			}
			return;
		}
		#end
		dispatchEvent(new crossbyte.events.IOErrorEvent(crossbyte.events.IOErrorEvent.IO_ERROR, message));
	}

	override public function addEventListener<T>(type:EventType<T>, listener:T->Void, priority:Int = 0):Void {
		super.addEventListener(type, listener, priority);

		if (type == Event.CONNECT) {
			__hasListener = true;
			__refreshSharedConnect();
			#if !nodejs
			if (listening) {
				__attachAcceptTick();
			}
			#end
		}
	}

	override public function removeEventListener<T>(type:EventType<T>, listener:T->Void):Void {
		super.removeEventListener(type, listener);

		if (type == Event.CONNECT) {
			__refreshSharedConnect();
		}

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
		#if (target.threaded && !js)
		if (__spread != null || __shared != null) {
			return __spreadFull();
		}
		#end
		return secure && maxPendingHandshakes >= 0 && __pendingHandshakes.length >= maxPendingHandshakes;
	}

	#if (target.threaded && !js)
	/**
		On a spread server's listener -- the front's, or with `reusePort` a
		replica's own: whether the handshakes under way on every runtime, and
		on their way to one, reach the front's `maxPendingHandshakes`. If they
		do, this listener is set aside until a runtime says one has ended.
	**/
	@:noCompletion private function __spreadFull():Bool {
		var spread:ServerSpread = __spread != null ? __spread : __shared;
		var front:ServerSocket = __front != null ? __front : this;
		return front.__tracksHandshakes() && spread.parkIfFull(front.maxPendingHandshakes, this);
	}
	#end

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
		#if (target.threaded && !js)
		if (__front != null) {
			// A replica's handshakes are counted by the front, and this is
			// called wherever they change, so this is where the front hears
			// of it. Only a replica that listens for itself, with reusePort,
			// has a listener to keep in the poll set.
			__publishPending();
			if (__listenerSocket() == null) {
				return;
			}
		}
		#end
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
		Always `0` on a plain server -- but a `ServerWebSocket` counts its
		sessions' TLS and upgrade together, plain or secure; see there.

		On Node always `0` as well, secure or not: Node completes each
		handshake itself and hands the server a connection only once it is
		done, without saying how many are under way. `handshakeTimeout`
		still bounds each, and `handshakeFailures` still counts the ones that
		fail or run out of time.

		On a server spread over `runtimes`, every runtime's together, with
		those accepted and on their way to one.
	**/
	public function pendingHandshakeCount():Int {
		#if (target.threaded && !js)
		if (__spread != null) {
			return __tracksHandshakes() ? __spread.inFlight : 0;
		}
		#end
		return __localPendingCount();
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
		never listening. Neither this nor `close()` dispatches `close`, which
		is for the system closing the listener; unlike `close()`, this does
		not mark the server closed.

		On Node a handshake under way finishes after the listener has
		stopped, and is closed as it does, as one in flight is natively.

		It may be called from any thread, as `close()` may, and is handed to
		the runtime the same way.
	**/
	public function stopAccepting():Void {
		if (!listening && !bound) {
			return;
		}

		var runtime:Null<CrossByte> = __cbInstance;
		if (RuntimeHandOff.offThread(runtime) && runtime.post(stopAccepting)) {
			return;
		}

		#if (target.threaded && !js)
		if (__front != null) {
			__stopReplica();
			return;
		}
		#end

		#if !nodejs
		__dropPendingHandshakes();
		__detachAcceptTick();
		#end
		#if (target.threaded && !js)
		if (__spread != null) {
			__spread.stop();
		}
		#end

		try {
			if (__serverSocket != null) {
				__serverSocket.close();
			}
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
			var cbSocket:Null<CBSocket> = __fromSocket(pending.socket, pending.peer);
			if (cbSocket == null) {
				__closeHandshake(pending);
				return;
			}
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

	// The peer's address when the connection was accepted: a client that
	// leaves the moment its handshake is done has none by the time the
	// connection is announced, on Linux and macOS. Null if it had none then.
	public var peer(default, null):Null<{host:sys.net.Host, port:Int}>;

	// The runtime whose poll set it is in, if it is in one.
	public var runtime:CrossByte = null;

	// Promoted, failed or dropped: nothing more for the poll set to do.
	public var settled:Bool = false;

	public var registryClosed(get, never):Bool;

	@:noCompletion private var __server:ServerSocket;

	public function new(server:ServerSocket, socket:Socket, deadline:Float, ?peer:{host:sys.net.Host, port:Int}) {
		__server = server;
		this.socket = socket;
		this.deadline = deadline;
		this.peer = peer;
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
