package crossbyte.http;

import haxe.io.Path;
import haxe.ds.ObjectMap;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.net.ServerSocket;
import crossbyte.http.HTTPRequestHandler;
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
	private var __maxConnections:Int;
	private var __connections:Int;
	private var docRoot:String;
	private var autoIndex:Array<String>;
	private var php:PHPBridge;

	@:noCompletion private var __requestsTotal:crossbyte.metrics.Counter;
	@:noCompletion private var __requestSeconds:crossbyte.metrics.Histogram;
	@:noCompletion private var __requestStarted:ObjectMap<Dynamic, Float>;
	@:noCompletion private static inline var RECEIVE_SWEEP_INTERVAL:Float = 0.25;
	@:noCompletion private var __sweepAccumulator:Float = 0;
	@:noCompletion private var __sweepArmed:Bool = false;

	public function new(config:HTTPServerConfig) {
		super(config.tlsEnabled);
		__connections = 0;
		__config = config;

		#if (!java && !jvm)
		if (config.tlsEnabled) {
			try {
				setCertificate(sys.ssl.Certificate.loadFile(config.tlsCertificatePath), sys.ssl.Key.loadFile(config.tlsKeyPath));
			} catch (e:Dynamic) {
				Logger.error('HTTP Server failed to load TLS material: ' + e);
				throw e;
			}
		}
		#end
		docRoot = config.rootDirectory.nativePath;
		autoIndex = (config.directoryIndex != null && config.directoryIndex.length > 0) ? config.directoryIndex : ["index.php", "index.html"];
		__active = new ObjectMap();
		__maxConnections = config.maxConnections;

		if (__config.phpEnabled) {
			var mode:PHPMode = switch (__config.phpMode) {
				case 0: Connect(__config.phpAddress, __config.phpPort);
				case 1: Launch(__config.phpAddress, __config.phpPort, __config.phpCGIPath, __config.phpINIPath);
				default:
					throw "Invalid PHPMode enum";
			}
			php = new PHPBridge(mode, docRoot, autoIndex);
		}

		__initMetrics();

		addEventListener(ServerSocketConnectEvent.CONNECT, this_onConnect);

		try {
			bind(__config.port, __config.address);
			listen(__config.backlog);
			Logger.info('HTTP Server started on ${__config.address}:${__config.port}');
		} catch (e:Dynamic) {
			Logger.error('HTTP Server failed to start on ${__config.address}:${__config.port}: ' + e);
			throw e;
		}
	}

	/**
		Number of client connections currently being served.
	**/
	public var activeConnections(get, never):Int;

	private function get_activeConnections():Int {
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

		@param timeoutSeconds How long to wait for active connections before
			forcing them closed. Values at or below zero close immediately.
		@param onComplete Invoked once shutdown finishes, on the runtime
			thread, whether it completed naturally or by timeout.
	**/
	public function drain(timeoutSeconds:Float = 30.0, ?onComplete:Void->Void):Void {
		if (draining) {
			return;
		}
		draining = true;

		stopAccepting();
		Logger.info('HTTP Server draining: ${__connections} active connection(s)');

		if (__connections <= 0 || timeoutSeconds <= 0) {
			__finishDrain(onComplete);
			return;
		}

		var deadline:Float = Sys.time() + timeoutSeconds;
		var runtime = __cbInstance;
		if (runtime == null) {
			// No runtime to poll on; complete synchronously rather than
			// leaving the caller waiting for a callback that cannot fire.
			__finishDrain(onComplete);
			return;
		}

		var onTick:TickEvent->Void = null;
		onTick = function(_:TickEvent):Void {
			if (__connections > 0 && Sys.time() < deadline) {
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
		for (socket in __active.keys()) {
			try {
				(cast socket : crossbyte.net.Socket).close();
			} catch (_:Dynamic) {}
		}
		__active = new ObjectMap();
		__connections = 0;

		try {
			close();
		} catch (_:Dynamic) {}

		Logger.info("HTTP Server drained");

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
		if (__connections >= __maxConnections) {
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

		var handler:HTTPRequestHandler = new HTTPRequestHandler(e.socket, __config, php);
		__active.set(e.socket, handler);
		__connections++;
		__beginRequestTiming(e.socket);
		__armReceiveSweep();

		handler.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, this_onResponse);

		e.socket.addEventListener("close", (_) -> cleanupSocket(e.socket));
		e.socket.addEventListener("error", (_) -> cleanupSocket(e.socket));
	}


	/**
	 * Starts the receive-deadline sweep, once, when the first connection
	 * arrives. Armed lazily because the runtime reference is only
	 * guaranteed by then, and a server with no connections has nothing to
	 * time out. Disarms itself the same way: the first sweep that finds no
	 * active connections unsubscribes, so an idle or drained server leaves
	 * nothing ticking.
	 */
	@:noCompletion private function __armReceiveSweep():Void {
		if (__sweepArmed || __config.requestTimeout <= 0) {
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

	@:noCompletion private function this_onReceiveSweep(e:TickEvent):Void {
		if (__connections <= 0) {
			var runtime:CrossByte = __cbInstance != null ? __cbInstance : CrossByte.current();
			if (runtime != null) {
				runtime.removeEventListener(TickEvent.TICK, this_onReceiveSweep);
			}
			__sweepArmed = false;
			return;
		}

		__sweepAccumulator += e.delta;
		if (__sweepAccumulator < RECEIVE_SWEEP_INTERVAL) {
			return;
		}
		__sweepAccumulator = 0;

		var now:Float = Sys.time();
		for (handler in __active) {
			handler.__checkReceiveDeadline(now);
		}
	}
	private function cleanupSocket(sock:Dynamic):Void {
		if (__active.exists(sock)) {
			__active.remove(sock);
			__endRequestTiming(sock);
			if (__connections > 0) {
				__connections--;
			}
		}
	}

	private function this_onResponse(e:HTTPStatusEvent):Void {
		Logger.info(e.toString());
		__recordResponse(e);
	}

	/**
		Registers this server's metrics when a registry is configured.

		Series are created up front so a scrape before the first request
		reports zero rather than omitting the series entirely — an absent
		series and a genuinely idle server look identical to a collector
		otherwise.
	**/
	@:noCompletion private function __initMetrics():Void {
		var registry = __config.metrics;
		if (registry == null) {
			return;
		}

		var prefix:String = (__config.metricsPrefix == null || __config.metricsPrefix == "") ? "http" : __config.metricsPrefix;
		__requestStarted = new ObjectMap();

		__requestsTotal = registry.counter(prefix + "_requests_total", null, "Responses sent, labelled by status class.");
		__requestSeconds = registry.histogram(prefix + "_request_seconds", null, null, "Time from accepting a connection to sending its response.");

		// Bound to the live counter rather than mirrored, so the gauge
		// cannot drift from the server's own accounting.
		registry.gaugeFn(prefix + "_active_connections", () -> __connections, null, "Client connections currently being served.");

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
		return peak;
	}

	@:noCompletion private function __totalOutputBuffer():Int {
		var total:Int = 0;
		for (socket in __active.keys()) {
			total += (cast socket : crossbyte.net.Socket).outputBufferLength;
		}
		return total;
	}

	@:noCompletion private function __recordResponse(e:HTTPStatusEvent):Void {
		if (__requestsTotal == null) {
			return;
		}

		// Status class rather than exact code: "2xx" and "5xx" are what
		// alerts are written against, and one series per code would grow
		// cardinality for no operational gain.
		var statusClass:String = Std.int(e.status / 100) + "xx";
		__config.metrics.counter(__requestsTotal.name, ["status" => statusClass]).inc();
	}

	@:noCompletion private function __beginRequestTiming(socket:Dynamic):Void {
		if (__requestStarted != null) {
			__requestStarted.set(socket, Sys.time());
		}
	}

	@:noCompletion private function __endRequestTiming(socket:Dynamic):Void {
		if (__requestStarted == null || !__requestStarted.exists(socket)) {
			return;
		}

		var started:Float = __requestStarted.get(socket);
		__requestStarted.remove(socket);
		__requestSeconds.observe(Sys.time() - started);
	}
}
