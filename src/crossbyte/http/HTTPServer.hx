package crossbyte.http;

// Not built for the browser: serving HTTP means listening on a port.
#if !(js && !nodejs)

import haxe.io.Path;
import haxe.ds.ObjectMap;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket as CBSocket;
import crossbyte.http.HTTPRequestHandler;
import crossbyte._internal.http.H2ConnectionHandler;
import crossbyte._internal.http.H2PrefaceSniffer;
import crossbyte._internal.http.HTTP1ResponseWriter;
import crossbyte._internal.http.HTTPResponseWriter;
import crossbyte.io.ByteArray;
import crossbyte.http.HTTPServerConfig;
import crossbyte.utils.Logger;
import crossbyte.core.CrossByte;
import crossbyte._internal.php.PHPBridge;
import crossbyte._internal.php.PHPMode;

using StringTools;

/** Lightweight static-and-middleware HTTP server built on `ServerSocket`. */
@:access(crossbyte.http.HTTPRequestHandler)
class HTTPServer extends ServerSocket {
	private var __config:HTTPServerConfig;
	private var __active:ObjectMap<Dynamic, HTTPRequestHandler>;

	// Kept apart from __active rather than widened into it: the two hold
	// different handlers and the sweep asks each a different question.
	private var __activeHttp2:ObjectMap<Dynamic, H2ConnectionHandler>;

	// Cleartext connections whose first bytes have not yet said which protocol
	// they speak, with the time each must say it by (0 for none). Counted
	// against maxConnections like any other: while waiting here they used to
	// be counted by nothing, timed by nothing and drained by nothing, so six
	// silent sockets all got in past a limit of two and outlived drain().
	private var __sniffing:ObjectMap<Dynamic, Float>;
	private var __maxConnections:Int;
	private var __connections:Int;
	private var docRoot:String;
	private var autoIndex:Array<String>;
	// Null unless PHP is on. Given a value as the server is made, as every
	// field another thread writes must be: see ServerSocket.__makeReplica.
	private var php:PHPBridge = null;

	@:noCompletion private var __requestsTotal:crossbyte.metrics.Counter = null;
	@:noCompletion private var __requestSeconds:crossbyte.metrics.Histogram = null;
	// On a replica: what its connections hold unsent, as last measured by
	// its sweep, for the front's gauges; see __publishBufferStats.
	@:noCompletion private var __publishedMaxBuffer:Int = 0;
	@:noCompletion private var __publishedTotalBuffer:Int = 0;
	// The status-class counters, by status / 100, each looked up once.
	@:noCompletion private var __statusCounters:Array<Null<crossbyte.metrics.Counter>> = [for (_ in 0...10) null];
	@:noCompletion private static inline var RECEIVE_SWEEP_INTERVAL:Float = 0.25;
	@:noCompletion private var __sweepAccumulator:Float = 0;
	@:noCompletion private var __sweepArmed:Bool = false;

	// Each body being pumped out, by its writer, with the stall check its
	// pump keeps, and each connection holding bytes its client has not
	// taken, with its check of them: what the sweep runs whatever the
	// timeouts are (see HTTPResponseWriter.sweepWith). Counted, since a map
	// has no size, so the sweep can tell when it has nothing left to do.
	@:noCompletion private var __pumps:ObjectMap<{}, Float->Void>;
	@:noCompletion private var __pumpCount:Int = 0;

	// __sweepWith, made once and handed to every writer and HTTP/2 connection.
	@:noCompletion private final __sweepHook:({}, Null<Float->Void>) -> Void;

	/**
		Makes the server and starts it listening on the configuration's
		address and port.

		With `HTTPServerConfig.runtimes` or `runtimeCount` set, the server
		serves its connections on those runtimes, as `ServerSocket.runtimes`
		describes: everything a request runs, the configuration's middleware
		and hooks included, then runs on several threads at once. See
		`HTTPServerConfig.runtimes` for what that asks of them.

		@throws IllegalOperationError When the configuration spreads the
			server over runtimes on a target that cannot: Node, whose runtimes
			share one thread; or asks for `reusePort` where there is none.
	**/
	public function new(config:HTTPServerConfig) {
		config.validate();
		super(config.tlsEnabled);
		__connections = 0;
		__config = config;
		__pumps = new ObjectMap();
		__sweepHook = __sweepWith;
		// A replica, made by a server spread over runtimes for one of them:
		// it is handed connections, and has no listener, certificate or
		// metrics of its own.
		var replica:Bool = __front != null;

		if (config.tlsEnabled && !replica) {
			try {
				setCertificate(crossbyte.net.Certificate.fromFile(config.tlsCertificatePath), crossbyte.net.Key.fromFile(config.tlsKeyPath));
			} catch (e:Dynamic) {
				Logger.error('HTTP Server failed to load TLS material: ' + e);
				throw e;
			}

			if (config.http2Enabled) {
				// Both, in preference order. Advertising only h2 would turn
				// every HTTP/1.1 client into a failed handshake, and a TLS
				// listener has no second chance to negotiate: ALPN happens
				// once, before any request exists to fall back on.
				setALPN(["h2", "http/1.1"]);
			}
		}
		// Null when the server has no static files; validate() has already
		// refused everything that would need one.
		docRoot = config.rootDirectory != null ? config.rootDirectory.nativePath : null;
		autoIndex = (config.directoryIndex != null && config.directoryIndex.length > 0) ? config.directoryIndex : ["index.php", "index.html"];
		__active = new ObjectMap();
		__activeHttp2 = new ObjectMap();
		__sniffing = new ObjectMap();
		__maxConnections = config.maxConnections;

		if (__config.phpEnabled) {
			var mode:PHPMode = switch (__config.phpMode) {
				case 0: Connect(__config.phpAddress, __config.phpPort);
				case 1: Launch(__config.phpAddress, __config.phpPort, __config.phpCGIPath, __config.phpINIPath);
				default:
					throw "Invalid PHPMode enum";
			}
			if (replica) {
				// A bridge per runtime, since a bridge is its runtime's: each
				// dials the backend the front launched, or was told of.
				mode = Connect(__config.phpAddress, __config.phpPort);
			}
			php = new PHPBridge(mode, docRoot, autoIndex, __config.phpTimeout);
		}

		if (replica) {
			// The front's series, which take locks of their own.
			var front:HTTPServer = cast __front;
			__requestsTotal = front.__requestsTotal;
			__requestSeconds = front.__requestSeconds;
		} else {
			__initMetrics();
		}

		// Its own listener: on a server spread over runtimes it runs on each
		// runtime's replica, with that runtime's connections.
		__addOwnConnectListener(this_onConnect);

		if (replica) {
			return;
		}

		// Spread as the configuration says, before the listener exists.
		if (config.runtimes != null && config.runtimes.length > 0) {
			runtimes = config.runtimes;
		} else if (config.runtimeCount > 0) {
			runtimeCount = config.runtimeCount;
		}
		if (config.reusePort) {
			reusePort = true;
		}
		#if (target.threaded && !js)
		if (runtimeCount > 0) {
			// One budget per client across every runtime, with a lock in front
			// of it; see HTTPServerConfig.rateLimiter.
			config.rateLimiter = crossbyte._internal.http.SharedRateLimiter.around(config.rateLimiter);
		}
		#end

		try {
			bind(__config.port, __config.address);
			listen(__config.backlog);
			// The port bound, which for a configured 0 is the one the system chose.
			Logger.info('HTTP Server started on ${__config.address}:${localPort}');
		} catch (e:Dynamic) {
			Logger.error('HTTP Server failed to start on ${__config.address}:${__config.port}: ' + e);
			throw e;
		}
	}

	/**
		Number of client connections currently being served.

		On a server spread over runtimes, every runtime's together: the count
		`maxConnections` is held to.
	**/
	public var activeConnections(get, never):Int;

	private function get_activeConnections():Int {
		#if (target.threaded && !js)
		if (__spread != null) {
			return __spread.connections;
		}
		#end
		return __connections;
	}

	/**
		Whether `drain()` has been called and shutdown is in progress.
	**/
	public var draining(default, null):Bool = false;

	/**
		Gracefully shuts the server down: stops accepting new connections,
		lets in-flight requests finish, then closes.

		Intended as the body of a `ProcessLifecycle.onShutdown` callback so a
		service stopped by the operating system does not sever live requests:

		```haxe
		ProcessLifecycle.onShutdown(() -> server.drain());
		ProcessLifecycle.installDefaultHandlers();
		```

		The listening socket is released immediately, so a successor process
		can bind the port while this one finishes its work. Connections still
		open when `timeoutSeconds` elapses are closed regardless.

		On a server spread over runtimes, each runtime drains the connections
		it holds, at once and on its own thread, and the drain finishes once
		every one has; the runtimes made for it (`runtimeCount`) then exit.

		It may be called from any thread, as `close()` may: from one that is
		not the server's runtime's, the drain is handed to the runtime and
		begins there after this returns. Begun elsewhere, it walked the
		connections and put its wait on the runtime's tick from the wrong
		thread.

		@param timeoutSeconds How long to wait for active connections before
			forcing them closed. Values at or below zero close immediately.
		@param onComplete Invoked once shutdown finishes, on the runtime
			thread, whether it completed naturally or by timeout.
	**/
	public function drain(timeoutSeconds:Float = 30.0, ?onComplete:Void->Void):Void {
		var owner:Null<CrossByte> = __cbInstance;
		if (crossbyte.net._internal.RuntimeHandOff.offThread(owner) && owner.post(() -> drain(timeoutSeconds, onComplete))) {
			return;
		}
		if (draining) {
			return;
		}
		draining = true;

		stopAccepting();

		#if (target.threaded && !js)
		if (__spread != null) {
			// Each runtime drains its own; this finishes once they all have.
			Logger.info('HTTP Server draining: ${activeConnections} active connection(s) across ${__spread.runtimes.length} runtimes');
			__drainReplicas(timeoutSeconds, (replica, drained) -> (cast replica : HTTPServer).drain(timeoutSeconds, drained),
				() -> __finishDrain(onComplete));
			return;
		}
		#end

		// An idle keep-alive connection is between requests: there is
		// nothing in flight to wait for, so it closes now rather than
		// holding the drain open for up to keepAliveTimeout. The rest are
		// marked to close after the response they are working on, so the
		// wall deadline is a backstop, not the norm. Snapshot before
		// closing: close() re-enters cleanupSocket synchronously, which
		// mutates __active mid-walk.
		var idleSockets:Array<Dynamic> = [];
		for (socket in __active.keys()) {
			var handler:HTTPRequestHandler = __active.get(socket);
			// A connection that has never sent a byte, a browser's
			// preconnect, has nothing in flight either, and held the drain
			// open for its whole timeout.
			if (handler.__isIdle() || !handler.__receivedAny) {
				idleSockets.push(socket);
			} else {
				handler.__closeAfterResponse = true;
			}
		}
		// Still deciding which protocol they speak: nothing has begun.
		for (socket in __sniffing.keys()) {
			idleSockets.push(socket);
		}
		for (socket in idleSockets) {
			try {
				(cast socket : crossbyte.net.Socket).close();
			} catch (_:Dynamic) {}
		}

		// HTTP/2 clients are told now, with a GOAWAY, rather than at the
		// deadline: they stop opening streams here, and what they have in
		// flight finishes. A connection with nothing open closes at once, and
		// the rest as their last stream ends.
		var http2:Array<H2ConnectionHandler> = [for (handler in __activeHttp2) handler];
		for (handler in http2) {
			try {
				handler.beginDrain();
			} catch (_:Dynamic) {}
		}

		// After the walk __connections counts only in-flight work, which
		// also makes this log line honest. A spread server's runtimes do not
		// each say it: the server said it once for them.
		if (__front == null) {
			Logger.info('HTTP Server draining: ${__connections} active connection(s)');
		}

		if (__connections <= 0 || timeoutSeconds <= 0) {
			__finishDrain(onComplete);
			return;
		}

		var deadline:Float = haxe.Timer.stamp() + timeoutSeconds;
		var runtime = __cbInstance;
		if (runtime == null) {
			// No runtime to poll on; complete synchronously rather than
			// leaving the caller waiting for a callback that cannot fire.
			__finishDrain(onComplete);
			return;
		}

		var onTick:TickEvent->Void = null;
		onTick = function(_:TickEvent):Void {
			// Closed here as well as in the sweep's walk of the connections,
			// which a server with both timeouts turned off never makes.
			if (__connections > 0) {
				var finished:Array<H2ConnectionHandler> = [for (handler in __activeHttp2) if (handler.drained) handler];
				for (handler in finished) {
					handler.close();
				}
			}

			if (__connections > 0 && haxe.Timer.stamp() < deadline) {
				return;
			}

			runtime.removeEventListener(TickEvent.TICK, onTick);
			if (__connections > 0) {
				Logger.info('HTTP Server drain timeout: closing ${__connections} connection(s)');
			}
			__finishDrain(onComplete);
		};
		runtime.addEventListener(TickEvent.TICK, onTick);
	}

	private function __finishDrain(onComplete:Void->Void):Void {
		var sockets:Array<Dynamic> = [for (socket in __active.keys()) socket];
		for (socket in __sniffing.keys()) {
			sockets.push(socket);
		}
		for (socket in sockets) {
			try {
				(cast socket : crossbyte.net.Socket).close();
			} catch (_:Dynamic) {}
		}

		// Closed through the handler rather than the socket, so the peer gets a
		// GOAWAY naming the last stream it processed instead of a connection
		// that simply stops, which is the difference between a client that
		// knows what to retry and one that guesses. Snapshotted first, since a
		// close re-enters cleanupSocket, which removes from the map.
		var http2:Array<H2ConnectionHandler> = [for (handler in __activeHttp2) handler];
		for (handler in http2) {
			try {
				handler.close();
			} catch (_:Dynamic) {}
		}

		__active = new ObjectMap();
		__activeHttp2 = new ObjectMap();
		__sniffing = new ObjectMap();
		__pumps = new ObjectMap();
		__pumpCount = 0;
		#if (target.threaded && !js)
		// What is left of this runtime's share of the server's count.
		if (__shared != null) {
			__shared.releaseConnections(__connections);
		}
		#end
		__connections = 0;

		try {
			close();
		} catch (_:Dynamic) {}

		#if (target.threaded && !js)
		if (__front == null) {
			Logger.info("HTTP Server drained");
		}
		// Runtimes made for this server have nothing left to serve.
		if (__spread != null) {
			__spread.exitOwned();
		}
		#else
		Logger.info("HTTP Server drained");
		#end

		if (onComplete != null) {
			onComplete();
		}
	}

	override function close() {
		super.close();
		if (php != null) {
			try {
				php.stop();
			} catch (_:Dynamic) {}
			php = null;
		}
	}

	private function this_onConnect(e:ServerSocketConnectEvent):Void {
		if (__config.http2Enabled) {
			if (__config.maxOutputBufferSize > 0) {
				e.socket.maxOutputBufferSize = __config.maxOutputBufferSize;
				e.socket.outputOverflowPolicy = __config.outputOverflowPolicy;
			}

			if (secure) {
				// ALPN already settled it during the handshake, which is the
				// whole reason the listener advertises both.
				if (e.socket.alpnProtocol == "h2") {
					__serveHttp2(e.socket, null);
				} else {
					__serveHttp1(e.socket);
				}
				return;
			}

			// Cleartext has no negotiation to read, so the first bytes decide.
			__sniff(e.socket);
			return;
		}

		__serveHttp1(e.socket);
	}

	/**
	 * Watches a cleartext connection's first bytes, counted and timed while it
	 * does. Counted against the same ceiling as a served connection, and held
	 * to `requestTimeout`, since until it speaks it is a request that has not
	 * arrived.
	 */
	@:noCompletion private function __sniff(socket:CBSocket):Void {
		if (!__claimConnection()) {
			// Nothing to answer in: which protocol would be a guess.
			Logger.error('Connection refused: concurrency limit ${__maxConnections}');
			try {
				socket.close();
			} catch (_:Dynamic) {}
			return;
		}

		__sniffing.set(socket, __config.requestTimeout > 0 ? haxe.Timer.stamp() + __config.requestTimeout : 0);
		__armReceiveSweep();

		socket.addEventListener("close", (_) -> cleanupSocket(socket));
		socket.addEventListener("error", (_) -> cleanupSocket(socket));

		new H2PrefaceSniffer(socket, __onProtocolDecided);
	}

	/** Routes a sniffed cleartext connection to the handler it turned out to need. */
	@:noCompletion private function __onProtocolDecided(socket:CBSocket, buffered:ByteArray, isHttp2:Bool):Void {
		if (!__sniffing.exists(socket)) {
			// Closed, timed out or drained while it was deciding.
			return;
		}

		// Handed over still counted: it keeps the place it took. It was let
		// go of and counted again by the serve functions, and on a server
		// spread over runtimes another runtime could take the place between.
		__sniffing.remove(socket);

		if (isHttp2) {
			__serveHttp2(socket, buffered, true);
		} else {
			__serveHttp1(socket, buffered, true);
		}
	}

	/**
		Counts a connection, unless the server already holds
		`maxConnections`: whether it was counted. On a server spread over
		runtimes the limit is every runtime's connections together, checked
		and counted in one step.
	**/
	@:noCompletion private function __claimConnection():Bool {
		#if (target.threaded && !js)
		if (__shared != null) {
			if (!__shared.claimConnection(__maxConnections)) {
				return false;
			}
			__connections++;
			return true;
		}
		#end
		if (__connections >= __maxConnections) {
			return false;
		}
		__connections++;
		return true;
	}

	/** A connection counted by `__claimConnection` has ended. **/
	@:noCompletion private function __releaseConnection():Void {
		if (__connections <= 0) {
			return;
		}
		__connections--;
		#if (target.threaded && !js)
		if (__shared != null) {
			__shared.releaseConnections(1);
		}
		#end
	}

	/**
	 * Hands a connection to the frame layer.
	 *
	 * None of the HTTP/1.1 per-connection bookkeeping applies: streams are the
	 * unit of concurrency here, not connections, so the concurrency limit and
	 * the keep-alive sweep have nothing to count.
	 */
	@:noCompletion private function __serveHttp2(socket:CBSocket, buffered:ByteArray, counted:Bool = false):Void {
		if (!counted && !__claimConnection()) {
			// Counted against the same ceiling as HTTP/1.1. Left out, the limit
			// was one a peer could ignore entirely by speaking HTTP/2.
			Logger.error('Connection refused: concurrency limit ${__maxConnections}');
			try {
				socket.close();
			} catch (_:Dynamic) {}
			return;
		}

		// The same per-response hook as HTTP/1.1, so HTTP/2 responses are counted
		// and timed. They were not, so a server serving browsers over h2
		// reported almost nothing.
		var handler:H2ConnectionHandler = new H2ConnectionHandler(socket, __config, php, buffered, this_onResponse, __sweepHook);
		__activeHttp2.set(socket, handler);
		__armReceiveSweep();

		socket.addEventListener("close", (_) -> cleanupSocket(socket));
		socket.addEventListener("error", (_) -> cleanupSocket(socket));
	}

	@:noCompletion private function __serveHttp1(socket:CBSocket, buffered:ByteArray = null, counted:Bool = false):Void {
		var e = {socket: socket};

		if (!counted && !__claimConnection()) {
			Logger.error('Connection refused: concurrency limit ${__maxConnections}');
			try {
				e.socket.writeUTFBytes('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
				e.socket.flush();
			} catch (_:Dynamic) {}
			try
				e.socket.close()
			catch (_:Dynamic) {}
			return;
		}

		// Applied here because an application never sees this socket before
		// it is written to, so a per-connection limit is only reachable from
		// the server that accepted it.
		if (__config.maxOutputBufferSize > 0) {
			e.socket.maxOutputBufferSize = __config.maxOutputBufferSize;
			e.socket.outputOverflowPolicy = __config.outputOverflowPolicy;
		}

		// Its writer made here, so a body it pumps out reaches the sweep.
		var handler:HTTPRequestHandler = new HTTPRequestHandler(e.socket, __config, php, new HTTP1ResponseWriter(e.socket, __sweepHook));
		__active.set(e.socket, handler);
		__armReceiveSweep();

		// A closure rather than the bare method: the response hook needs
		// the handler for its per-request start stamp, and the event only
		// carries the status.
		handler.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, e -> this_onResponse(e, handler));

		e.socket.addEventListener("close", (_) -> cleanupSocket(e.socket));
		e.socket.addEventListener("error", (_) -> cleanupSocket(e.socket));

		// Fed last, so the handler is fully wired before the request it was
		// chosen for reaches it.
		if (buffered != null && buffered.length > 0) {
			@:privateAccess handler.__adoptBuffered(buffered);
		}
	}


	/**
	 * Starts the receive-deadline sweep, once, when the first connection
	 * arrives. Armed lazily because the runtime reference is only
	 * guaranteed by then, and a server with no connections has nothing to
	 * time out. Disarms itself the same way: the first sweep that finds no
	 * active connections unsubscribes, so an idle or drained server leaves
	 * nothing ticking.
	 *
	 * The sweep also reaps idle keep-alive connections, one walk, two
	 * meanings of the same per-handler deadline, so it must arm when
	 * either timeout is live, not only `requestTimeout`. And it holds every
	 * body being pumped out to its stall deadline, whatever the timeouts
	 * are, so it arms while one is: with both timeouts off it never armed,
	 * and a download whose client stopped taking it held its file and its
	 * connection for good.
	 */
	@:noCompletion private function __armReceiveSweep():Void {
		if (__sweepArmed || (!__timeoutsLive() && __pumpCount <= 0 && !__publishesBuffers())) {
			return;
		}

		var runtime:CrossByte = __cbInstance != null ? __cbInstance : CrossByte.current();
		if (runtime == null) {
			return;
		}

		runtime.addEventListener(TickEvent.TICK, this_onReceiveSweep);
		__sweepArmed = true;
		__sweepAccumulator = 0;
	}

	/** Whether either timeout sets a deadline, which the walk over every connection keeps. */
	@:noCompletion private inline function __timeoutsLive():Bool {
		return __config.requestTimeout > 0 || (__config.keepAlive && __config.keepAliveTimeout > 0);
	}

	/**
	 * Registers, or with `null` drops, `owner`'s stall check: a writer's, for
	 * a body it is pumping out or bytes its client has not taken, what
	 * `HTTPResponseWriter.sweepWith` reaches here, or an HTTP/2
	 * connection's, for what it holds for its client.
	 */
	@:noCompletion private function __sweepWith(owner:{}, check:Null<Float->Void>):Void {
		if (check == null) {
			if (__pumps.remove(owner)) {
				__pumpCount--;
			}
			return;
		}

		if (!__pumps.exists(owner)) {
			__pumpCount++;
		}
		__pumps.set(owner, check);
		__armReceiveSweep();
	}

	@:noCompletion private function this_onReceiveSweep(e:TickEvent):Void {
		if (__connections <= 0) {
			__disarmReceiveSweep();
			return;
		}

		__sweepAccumulator += e.delta;
		if (__sweepAccumulator < RECEIVE_SWEEP_INTERVAL) {
			return;
		}
		__sweepAccumulator = 0;

		// Asked here, a few times a second, rather than above on every tick.
		if (!__timeoutsLive() && __pumpCount <= 0 && !__publishesBuffers()) {
			__disarmReceiveSweep();
			return;
		}

		__sweep(haxe.Timer.stamp());
		if (__publishesBuffers()) {
			__publishedMaxBuffer = __maxOutputBuffer();
			__publishedTotalBuffer = __totalOutputBuffer();
		}
	}

	@:noCompletion private function __disarmReceiveSweep():Void {
		var runtime:CrossByte = __cbInstance != null ? __cbInstance : CrossByte.current();
		if (runtime != null) {
			runtime.removeEventListener(TickEvent.TICK, this_onReceiveSweep);
		}
		__sweepArmed = false;
		// Disarmed with nothing held, or with nothing measured: either way the
		// front's gauges are told nothing is held here.
		__publishedMaxBuffer = 0;
		__publishedTotalBuffer = 0;
	}

	/**
		Whether the sweep measures what this runtime's connections hold
		unsent, for the gauges of the server it serves: a replica's, while
		metrics are kept. The front cannot walk another thread's connections,
		so each runtime measures its own a few times a second.
	**/
	@:noCompletion private inline function __publishesBuffers():Bool {
		return __front != null && __config.metrics != null;
	}

	/**
	 * One visit of the sweep, at `now` (`haxe.Timer.stamp()`): every
	 * connection's deadlines while either timeout sets one, and every body
	 * being pumped out regardless. With both timeouts off only those are
	 * visited, so a server holding many idle connections pays for the
	 * transfers in flight, not for every connection, a few times a second.
	 */
	@:noCompletion private function __sweep(now:Float):Void {
		if (__timeoutsLive()) {
			__sweepConnections(now);
		}

		if (__pumpCount > 0) {
			// Gathered first: a check that ends its transfer drops it from the
			// map, from inside this loop.
			var checks:Array<Float->Void> = [for (check in __pumps) check];
			for (check in checks) {
				check(now);
			}
		}
	}

	@:noCompletion private function __sweepConnections(now:Float):Void {
		// Snapshot before checking, same discipline as drain(): an expired
		// idle connection is closed inside the check, and close()
		// synchronously re-enters cleanupSocket, which mutates __active
		// mid-iteration. Under keep-alive the sweep close is the routine
		// end of every idle connection, not a rare fault.
		var handlers:Array<HTTPRequestHandler> = [];
		for (handler in __active) {
			handlers.push(handler);
		}

		var http2:Array<H2ConnectionHandler> = [];
		for (handler in __activeHttp2) {
			http2.push(handler);
		}

		// A connection still silent at its deadline never began a request, so
		// there is nothing to answer it with; it is closed.
		var silent:Array<Dynamic> = [];
		for (socket in __sniffing.keys()) {
			var deadline:Float = __sniffing.get(socket);
			if (deadline > 0 && now >= deadline) {
				silent.push(socket);
			}
		}
		for (socket in silent) {
			try {
				(cast socket : CBSocket).close();
			} catch (_:Dynamic) {}
		}

		for (handler in handlers) {
			handler.__checkReceiveDeadline(now);
		}
		for (handler in http2) {
			handler.checkDeadline(now);
		}
	}
	private function cleanupSocket(sock:Dynamic):Void {
		if (__sniffing.exists(sock)) {
			__sniffing.remove(sock);
			__releaseConnection();
			return;
		}

		if (__active.exists(sock)) {
			__active.remove(sock);
			__releaseConnection();
			return;
		}

		if (__activeHttp2.exists(sock)) {
			__activeHttp2.remove(sock);
			__releaseConnection();
		}
	}

	private function this_onResponse(e:HTTPStatusEvent, handler:HTTPRequestHandler):Void {
		__recordResponse(e);

		// Observed per response, at response time. The old cleanup-time
		// observation billed a request for the whole connection's life,
		// which under keep-alive would charge request N for every request
		// and idle gap before it, and count once per connection instead
		// of once per response.
		if (__requestSeconds != null) {
			__requestSeconds.observe(haxe.Timer.stamp() - handler.__requestStartedAt);
		}
	}

	/**
		Registers this server's metrics when a registry is configured.

		Series are created up front so a scrape before the first request
		reports zero rather than omitting the series entirely, an absent
		series and a genuinely idle server look identical to a collector
		otherwise.
	**/
	@:noCompletion private function __initMetrics():Void {
		var registry = __config.metrics;
		if (registry == null) {
			return;
		}

		var prefix:String = (__config.metricsPrefix == null || __config.metricsPrefix == "") ? "http" : __config.metricsPrefix;

		__requestsTotal = registry.counter(prefix + "_requests_total", null, "Responses sent, labelled by status class.");
		__requestSeconds = registry.histogram(prefix + "_request_seconds", null, null, "Time from a request's first byte to its response being written.");

		// Bound to the live counter rather than mirrored, so the gauge
		// cannot drift from the server's own accounting.
		// Every runtime's, on a server spread over several.
		registry.gaugeFn(prefix + "_active_connections", () -> activeConnections, null, "Client connections currently being served.");

		// Aggregates across connections, never a series per peer: a label
		// carrying a client address would create a time series that
		// outlives the connection it describes, and a server with real
		// churn would take the metrics pipeline down with it.
		//
		// `maxOutputBufferSize` bounds one connection, but many peers each
		// sitting just under that bound is invisible from the limit alone.
		// The max identifies a single stuck client; the total identifies a
		// server-wide back-up.
		registry.gaugeFn(prefix + "_output_buffer_bytes_max", () -> __maxOutputBuffer(), null,
			"Largest amount of undrained response data held for any one connection.");
		registry.gaugeFn(prefix + "_output_buffer_bytes_total", () -> __totalOutputBuffer(), null,
			"Undrained response data held across all connections.");
	}

	/**
	 * Measured on scrape rather than tracked as a running maximum: a
	 * running maximum only rises, so one stalled peer would pin it high
	 * forever and it would stop describing the present.
	 */
	@:noCompletion private function __maxOutputBuffer():Int {
		var peak:Int = 0;
		for (socket in __active.keys()) {
			var pending:Int = (cast socket : crossbyte.net.Socket).outputBufferLength;
			if (pending > peak) {
				peak = pending;
			}
		}
		// HTTP/2 connections hold output too, and were left out of both gauges:
		// in the socket, and in what flow control holds back on each stream,
		// which counted nowhere.
		for (handler in __activeHttp2) {
			var pending:Int = handler.heldBytes;
			if (pending > peak) {
				peak = pending;
			}
		}
		#if (target.threaded && !js)
		// Spread: what each runtime's sweep last measured of its own.
		if (__spread != null) {
			for (replica in __spread.replicas) {
				var measured:Int = (cast replica : HTTPServer).__publishedMaxBuffer;
				if (measured > peak) {
					peak = measured;
				}
			}
		}
		#end
		return peak;
	}

	@:noCompletion private function __totalOutputBuffer():Int {
		var total:Int = 0;
		for (socket in __active.keys()) {
			total += (cast socket : crossbyte.net.Socket).outputBufferLength;
		}
		for (handler in __activeHttp2) {
			total += handler.heldBytes;
		}
		#if (target.threaded && !js)
		if (__spread != null) {
			for (replica in __spread.replicas) {
				total += (cast replica : HTTPServer).__publishedTotalBuffer;
			}
		}
		#end
		return total;
	}

	#if (target.threaded && !js)
	/** One runtime's share of this server: the same configuration, no listener. **/
	@:noCompletion override private function __replicate():ServerSocket {
		return new HTTPServer(__config);
	}
	#end

	@:noCompletion private function __recordResponse(e:HTTPStatusEvent):Void {
		if (__requestsTotal == null) {
			return;
		}

		// Status class rather than exact code: "2xx" and "5xx" are what
		// alerts are written against, and one series per code would grow
		// cardinality for no operational gain.
		//
		// Each class's counter is looked up once and kept. Looking it up per
		// response built a label map, sorted it into a key and took the
		// registry's lock, on top of the counter's own, for every response.
		var index:Int = Std.int(e.status / 100);
		var counter:Null<crossbyte.metrics.Counter> = (index >= 0 && index < 10) ? __statusCounters[index] : null;
		if (counter == null) {
			counter = __config.metrics.counter(__requestsTotal.name, ["status" => index + "xx"]);
			if (index >= 0 && index < 10) {
				__statusCounters[index] = counter;
			}
		}
		counter.inc();
	}
}
#end
