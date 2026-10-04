package crossbyte._internal.php;

// Not built for the browser: it launches and talks to a PHP CGI process.
#if !(js && !nodejs)

import haxe.io.Path;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
#if nodejs
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.sys.NativeProcess;
import crossbyte.sys.NativeProcessStartupInfo;
#end
import sys.FileSystem;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
#if !nodejs
import crossbyte._internal.socket.BlockedError;
import crossbyte._internal.socket.IPollableSocket;
import sys.net.Host;
import sys.net.Socket;
import sys.io.Process;
#if target.threaded
import sys.thread.Deque;
import sys.thread.Thread;
#end
#end

using StringTools;

class PHPBridge {
	/**
		Seconds a single FastCGI exchange may take before it is abandoned.

		`0` disables the deadline, which is what this class did unconditionally
		before: no socket timeout, and a read loop that would wait for a peer
		that had stopped talking. A CrossByte runtime serves every one of its
		connections from one tick, so that was not one slow request, it was
		the server, stopped, until the backend came back or the process was
		killed.
	**/
	public final timeoutSeconds:Float;

	/** Thirty seconds: long enough for a slow page, short of forever. **/
	public static inline var DEFAULT_TIMEOUT:Float = 30.0;

	/**
		How close to the deadline a failed read still counts as the deadline.

		The socket timeout and the deadline are set to the same instant, so
		whichever the operating system reports second lands marginally past it.
	**/
	private static inline var READ_DEADLINE_GRACE:Float = 0.1;

	public final mode:PHPMode;
	public final docRoot:String;
	public final autoIndex:Array<String>;

	/**
		The most bytes one response may take, the script's CGI header block
		and body together, before its exchange fails; `0` or less for no
		limit. `PHPExchange.DEFAULT_MAX_RESPONSE_SIZE`, 8 MB, unless the
		server's `phpMaxResponseSize` says otherwise.
	**/
	public final maxResponseSize:Int;

	/**
		Exchanges with the backend at once, at most, each holding a connection
		to it; `0` or less for no limit. More wait their turn, first come first
		served, within their own deadlines, and past `MAX_WAITING` of those a
		new one is refused with a `PHPBusy`. Nothing bounded them: every
		request for a script opened a connection to the backend, however many
		were already waiting on it, and a `php-cgi -b` answers one at a time.
	**/
	public final maxExchanges:Int;

	/** `maxExchanges` unless the server's `phpMaxExchanges` says otherwise. **/
	public static inline var DEFAULT_MAX_EXCHANGES:Int = 64;

	/** Exchanges, at most, waiting for one with the backend to end. **/
	public static inline var MAX_WAITING:Int = 1024;

	/**
		Bytes read from one exchange's connection in one pass, at most, before
		the rest is left for the next, as a `Socket` leaves it, and for the
		same reason: a backend sending fast held the runtime, and every other
		connection on it, for as long as it kept sending. The loop is told to
		poll again before it waits, so the rest is read at once, not a frame
		later.
	**/
	public static inline var READ_BUDGET:Int = 1024 * 1024;

	// This bridge's budget: `READ_BUDGET`, unless a test asks for less, so a
	// pass can be made to stop at it whatever the system's socket buffers hold.
	@:noCompletion private var __readBudget:Int = READ_BUDGET;

	// Launch mode spawns php-cgi. Node has no sys.io.Process, so it uses
	// CrossByte's own NativeProcess, the portable subprocess API this
	// framework already ships, rather than a second bespoke wrapper. Both
	// answer close(), which is all stop() needs of them.
	#if nodejs
	private var _proc:Null<NativeProcess> = null;
	#else
	private var _proc:Null<Process> = null;
	#end
	// Every exchange not yet settled, for the deadline sweep: with the backend,
	// or waiting to be.
	private var __pending:Array<Tracked> = [];
	// Those waiting for an exchange with the backend to end, in turn.
	private var __waiting:Array<Tracked> = [];
	// How many are with the backend.
	private var __inFlight:Int = 0;
	private var __runtime:Null<CrossByte> = null;
	private var __sweeping:Bool = false;
	#if !nodejs
	private var __reading:Array<Outbound> = [];
	private var __scratch:Bytes = Bytes.alloc(8192);
	#if target.threaded
	// Where connects go to be made; see __connectOffThread. Null until the
	// first exchange, and again after stop().
	private var __connector:Null<Deque<ConnectorJob>> = null;
	#end

	/**
		How many times the backend's name has been looked up. Written only by
		the thread that makes the connects, and read after an exchange it
		connected has settled, which the hand-back through the post queue
		orders after the write.
	**/
	@:noCompletion public var __lookups:Int = 0;
	#end

	public function new(mode:PHPMode, ?docRoot:String, ?autoIndex:Array<String>, timeoutSeconds:Float = DEFAULT_TIMEOUT,
			maxResponseSize:Int = PHPExchange.DEFAULT_MAX_RESPONSE_SIZE, maxExchanges:Int = DEFAULT_MAX_EXCHANGES) {
		this.mode = mode;
		this.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 0;
		this.maxResponseSize = maxResponseSize;
		this.maxExchanges = maxExchanges;
		this.docRoot = docRoot != null ? docRoot : "";
		this.autoIndex = autoIndex != null ? autoIndex : ["index.php", "index.html"];

		switch (mode) {
			case Launch(address, port, phpCgiPath, phpIniPath):
				var cgiPath:String = "";
				if (phpCgiPath != null && phpCgiPath != "" && FileSystem.exists(phpCgiPath)) {
					cgiPath = phpCgiPath;
				} else if (phpCgiPath != null && Sys.getEnv(phpCgiPath) != null) {
					cgiPath = Sys.getEnv(phpCgiPath);
				} else {
					cgiPath = Path.directory(Sys.programPath()) + "\\php\\php-cgi.exe";
				}

				if (_proc != null)
					try {
						_proc.close();
					} catch (_:Dynamic) {};
				var args:Array<String> = ["-b", address + ":" + port];
				if (phpIniPath != null && phpIniPath != "") {
					var iniPath:String = phpIniPath;
					if (iniPath == "php.ini") {
						iniPath = Path.join([Path.directory(Sys.programPath()), iniPath]);
					}
					if (FileSystem.exists(iniPath)) {
						args = ["-c", iniPath].concat(args);
					}
				}
				WindowsKillOnExit.attach();
				#if nodejs
				_proc = new NativeProcess();
				_proc.start(new NativeProcessStartupInfo(cgiPath, args));
				#else
				_proc = new Process(cgiPath, args);
				#end
				CrossByte.current().addEventListener(Event.EXIT, _onExit);
			case Connect(_, _):
				// nothing to do we’ll just dial per call
		}
	}

	public function stop():Void {
		if (_proc != null) {
			try {
				_proc.close();
			} catch (_:Dynamic) {};
			_proc = null;
		}

		#if (!nodejs && target.threaded)
		// The connector finishes what it was already given, then ends.
		if (__connector != null) {
			__connector.add(Stop);
			__connector = null;
		}
		#end
	}

	/**
	 * Starts a FastCGI exchange and hands back its eventual response.
	 *
	 * This returned a `PHPResponse` before, and that signature was the whole
	 * problem. A blocking round trip inside a tick stops the runtime for every
	 * connection it serves, not just this one, and it cannot exist at all on a
	 * target with no synchronous socket read, which is why PHP was the last
	 * thing unavailable on Node.
	 *
	 * `Future` rather than a callback pair, because the framework already has
	 * one way of saying "later" and a second would be a second.
	 */
	public function execute(req:PHPRequest):Future<PHPResponse> {
		var exchange = new PHPExchange(timeoutSeconds, maxResponseSize);

		if (docRoot != "" && req.scriptFilename.indexOf("..") >= 0) {
			exchange.fail("Traversal refused");
			return exchange.future;
		}

		var host:String;
		var port:Int;

		switch (mode) {
			case Connect(a, p):
				host = a;
				port = p;
			case Launch(a, p, _, _):
				host = a;
				port = p;
		}

		var env:Map<String, String> = new Map();
		put(env, "GATEWAY_INTERFACE", "CGI/1.1");
		put(env, "SERVER_PROTOCOL", "HTTP/1.1");
		put(env, "REQUEST_METHOD", req.requestMethod);
		put(env, "SCRIPT_FILENAME", req.scriptFilename);
		put(env, "SCRIPT_NAME", req.scriptName != null ? req.scriptName : safeScriptName(req.requestUri, autoIndex));
		put(env, "REQUEST_URI", req.requestUri);
		put(env, "QUERY_STRING", req.queryString != null ? req.queryString : "");
		put(env, "CONTENT_TYPE", req.contentType != null ? req.contentType : "");
		put(env, "CONTENT_LENGTH", req.body != null ? Std.string(req.body.length) : "0");
		put(env, "REMOTE_ADDR", req.remoteAddr != null ? req.remoteAddr : "0.0.0.0");
		if (docRoot != "") {
			put(env, "DOCUMENT_ROOT", docRoot);
		}

		if (req.serverName != null) {
			put(env, "SERVER_NAME", req.serverName);
		}

		if (req.serverPort != null) {
			put(env, "SERVER_PORT", req.serverPort);
		}

		if (req.extraHeaders != null) {
			for (k in req.extraHeaders.keys()) {
				final key = "HTTP_" + k.toUpperCase().replace("-", "_");
				put(env, key, req.extraHeaders.get(k));
			}
		}

		var payload:Bytes;

		try {
			payload = encodeRequest(env, req.body);
		} catch (e:Dynamic) {
			exchange.fail(Std.string(e));
			return exchange.future;
		}

		__admit(new Tracked(exchange, host, port, payload));
		return exchange.future;
	}

	/**
		Starts `tracked`'s exchange with the backend if one may start, queues
		it if not, and refuses it with a `PHPBusy` if the queue is full. Its
		deadline runs from here, waiting included.
	**/
	private function __admit(tracked:Tracked):Void {
		var exchange:PHPExchange = tracked.exchange;
		var free:Bool = maxExchanges <= 0 || __inFlight < maxExchanges;
		if (!free && __waiting.length >= MAX_WAITING) {
			var busy:PHPBusy = new PHPBusy(__inFlight, __waiting.length);
			exchange.fail(busy.toString(), busy);
			return;
		}

		__track(tracked);
		if (free) {
			__start(tracked);
		} else {
			__waiting.push(tracked);
		}
	}

	/** Starts `tracked`'s exchange with the backend: it holds one of `maxExchanges`. **/
	private function __start(tracked:Tracked):Void {
		tracked.started = true;
		__inFlight++;
		__begin(tracked);
	}

	/**
		Starts the next of those waiting, while there is room: an exchange with
		the backend has ended. One whose deadline has passed is failed as the
		sweep would fail it, rather than connected for nothing.
	**/
	private function __startWaiting():Void {
		while (__waiting.length > 0 && (maxExchanges <= 0 || __inFlight < maxExchanges)) {
			var next:Tracked = __waiting.shift();
			if (next.exchange.settled) {
				continue;
			}
			if (next.exchange.expired()) {
				next.exchange.timeOut(__waitingPhase());
				__finish(next.exchange);
				continue;
			}
			__start(next);
		}
	}

	private inline function __waitingPhase():String {
		return "waiting for one of the " + maxExchanges + " exchanges with the backend to end";
	}

	/**
	 * The FastCGI records for one request: BEGIN_REQUEST, the parameters, and
	 * the body as STDIN.
	 *
	 * A record's length field is sixteen bits, and both halves used to go in
	 * one record each: a 100,000-byte POST declared 34,464 bytes, and php-fpm
	 * then read the rest of the body as record headers. The body is now split
	 * across as many STDIN records as it needs, which php-fpm reads as one
	 * stream.
	 *
	 * Parameters are split too, but only between pairs. php-fpm parses each
	 * PARAMS record on its own, so a pair split across two would be malformed
	 * in both, and a single pair too large for one record cannot be sent at
	 * all, which is refused here rather than sent broken.
	 */
	@:noCompletion private static function encodeRequest(env:Map<String, String>, body:Null<Bytes>):Bytes {
		final out = new BytesBuffer();
		var begin:Bytes = beginRequestBody(Fcgi.ROLE_RESPONDER, false);
		Fcgi.record(out, Fcgi.BEGIN_REQUEST, 1, begin, 0, begin.length);

		var params:BytesBuffer = new BytesBuffer();

		for (k in env.keys()) {
			var pair:Bytes = Fcgi.nvpair(k, env.get(k));

			if (pair.length > Fcgi.MAX_CONTENT) {
				throw 'The request parameter $k is ${pair.length} bytes, more than a FastCGI record can carry, so it cannot be sent to PHP.';
			}

			if (params.length + pair.length > Fcgi.MAX_CONTENT) {
				var full:Bytes = params.getBytes();
				Fcgi.record(out, Fcgi.PARAMS, 1, full, 0, full.length);
				params = new BytesBuffer();
			}

			params.add(pair);
		}

		if (params.length > 0) {
			var last:Bytes = params.getBytes();
			Fcgi.record(out, Fcgi.PARAMS, 1, last, 0, last.length);
		}

		Fcgi.record(out, Fcgi.PARAMS, 1, null, 0, 0);

		if (body != null) {
			var offset:Int = 0;

			while (offset < body.length) {
				var length:Int = body.length - offset < Fcgi.MAX_CONTENT ? body.length - offset : Fcgi.MAX_CONTENT;
				Fcgi.record(out, Fcgi.STDIN, 1, body, offset, length);
				offset += length;
			}
		}

		Fcgi.record(out, Fcgi.STDIN, 1, null, 0, 0);
		return out.getBytes();
	}

	/**
	 * Opens the transport and starts the exchange.
	 *
	 * The two targets differ only in how they learn that bytes have come
	 * back: Node by an event, a native build from the runtime's poll set,
	 * which its socket joins the way `crossbyte.net.Socket`'s do. Everything
	 * else, the parser, the deadline, the table, is shared, and that is
	 * the point of the split.
	 *
	 * Sets `tracked.release`, which lets the transport go, before anything
	 * can settle the exchange.
	 */
	private function __begin(tracked:Tracked):Void {
		var exchange:PHPExchange = tracked.exchange;
		var host:String = tracked.host;
		var port:Int = tracked.port;
		var payload:Bytes = tracked.payload;
		#if nodejs
		var socket = new crossbyte.net.Socket();

		socket.addEventListener(Event.CONNECT, function(_):Void {
			socket.writeBytes(ByteArray.fromBytes(payload), 0, payload.length);
			socket.flush();
		});

		socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (exchange.settled) {
				return;
			}

			var available:Int = socket.bytesAvailable;

			if (available <= 0) {
				return;
			}

			var chunk = new ByteArray();
			socket.readBytes(chunk, 0, available);

			if (exchange.receive(chunk, chunk.length)) {
				exchange.succeed();
				__finish(exchange, socket);
			} else if (exchange.settled) {
				// Refused as it arrived: past a limit.
				__finish(exchange, socket);
			}
		});

		socket.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):Void {
			// Named, and never empty. A socket error can arrive with no text at
			// all, and "PHP backend failed: " on its own tells an operator
			// running more than one backend nothing about which one or why.
			var reason:String = e.text != null && e.text != "" ? e.text : "the connection failed without saying why";
			exchange.fail("PHP backend at " + host + ":" + port + " failed: " + reason);
			__finish(exchange, socket);
		});

		socket.addEventListener(Event.CLOSE, function(_):Void {
			// A peer that hung up before END_REQUEST. The response is
			// incomplete, and serving half a page is worse than saying so.
			exchange.fail("PHP backend at " + host + ":" + port + " closed the connection before finishing the response.");
			__finish(exchange, socket);
		});

		tracked.release = function():Void {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		};

		socket.connect(host, port);
		#else
		var outbound = new Outbound(this, exchange, host, port, payload);
		__reading.push(outbound);

		tracked.release = function():Void {
			__release(outbound);
		};

		#if target.threaded
		__connectOffThread(outbound);
		#else
		// No thread to connect on, so it is made here, as it always was,
		// within what is left of the exchange's deadline.
		var socket:Null<Socket> = null;
		var failure:Dynamic = null;

		try {
			__lookups++;
			var timeout:Float = exchange.remaining();
			socket = __open(crossbyte._internal.net.Resolver.lookup(host, timeout), port, timeout);
		} catch (e:Dynamic) {
			failure = e;
		}

		__connected(outbound, socket, failure);
		#end
		#end
	}

	#if !nodejs
	/**
	 * Writes as much of the request as the socket will take now, and returns
	 * whether all of it has gone. Stops without error when the send buffer is
	 * full; anything else is thrown.
	 */
	private static function __send(outbound:Outbound):Bool {
		var payload:Bytes = outbound.payload;

		while (outbound.written < payload.length) {
			var sent:Int = 0;

			try {
				sent = outbound.socket.output.writeBytes(payload, outbound.written, payload.length - outbound.written);
			} catch (e:Dynamic) {
				if (crossbyte._internal.socket.BlockedError.isBlocked(e)) {
					return false;
				}

				throw e;
			}

			if (sent <= 0) {
				return false;
			}

			outbound.written += sent;
		}

		return true;
	}

	#if target.threaded
	/**
	 * Hands the exchange's connect to the bridge's connector thread, starting
	 * it with the first one.
	 *
	 * The connect was made here, on the runtime's thread, for every request:
	 * a lookup of the backend's name and then a blocking connect, and every
	 * socket and timer on the runtime waited for both. For a backend given
	 * by name, a container's name, `localhost`, the lookup was repeated
	 * each time; for one that is slow to answer, or does not exist, the wait
	 * was as long as the resolver or the connect cared to take. Now this call
	 * costs a queue append, and the socket comes back through the runtime's
	 * post queue, which wakes the runtime for it.
	 *
	 * One thread, taking connects in turn: a connect to a backend that is up
	 * takes a fraction of a millisecond, and one to a backend that is not
	 * would keep a second waiting no less than the first. The deadline covers
	 * an exchange from the moment it is queued.
	 */
	private function __connectOffThread(outbound:Outbound):Void {
		var runtime:Null<CrossByte> = __runtime;

		if (runtime == null) {
			outbound.exchange.fail("PHP backend at " + outbound.host + ":" + outbound.port + " was not tried: there is no runtime to hand the connection back to.");
			__finish(outbound.exchange);
			return;
		}

		if (__connector == null) {
			var jobs = new Deque<ConnectorJob>();
			__connector = jobs;
			Thread.create(() -> __connectLoop(jobs, runtime));
		}

		__connector.add(Connect(outbound));
	}

	/**
	 * The connector thread: looks the backend up and connects to it, blocking
	 * here rather than on the runtime, and hands each socket back through the
	 * runtime's post queue.
	 *
	 * The address a name resolves to is kept, and looked up again only after
	 * a connect to it fails: a backend that moved, a container restarted
	 * under a new address, is found at its new one on the next request,
	 * and one that stays put is looked up once. Kept here, on this thread,
	 * so it needs no lock.
	 */
	private function __connectLoop(jobs:Deque<ConnectorJob>, runtime:CrossByte):Void {
		var resolvedName:Null<String> = null;
		var resolved:Null<Host> = null;

		while (true) {
			var outbound:Outbound = switch (jobs.pop(true)) {
				case Connect(queued): queued;
				case Stop: return;
			}

			// Read across threads without a lock, so possibly stale; a connect
			// made for an exchange that has already given up is closed on the
			// runtime's thread instead. This only saves making it.
			if (outbound.exchange.settled) {
				continue;
			}

			var socket:Null<Socket> = null;
			var failure:Dynamic = null;

			try {
				// Within what is left of the exchange's deadline, the lookup
				// and the connect both: neither had a bound, and a backend
				// whose host dropped the connect held this thread, and every
				// exchange queued behind it, for as long as the system tried.
				var timeout:Float = outbound.exchange.remaining();
				if (resolved == null || resolvedName != outbound.host) {
					__lookups++;
					resolved = crossbyte._internal.net.Resolver.lookup(outbound.host, timeout);
					resolvedName = outbound.host;
				}

				socket = __open(resolved, outbound.port, timeout);
			} catch (e:Dynamic) {
				failure = e;
				resolved = null;
				resolvedName = null;
			}

			var connected:Null<Socket> = socket;
			var why:Dynamic = failure;

			if (!runtime.post(() -> __connected(outbound, connected, why))) {
				// The runtime has exited, and nothing will ever run that.
				if (connected != null) {
					try {
						connected.close();
					} catch (_:Dynamic) {}
				}
				return;
			}
		}
	}
	#end

	/**
		A socket connected to `host`, blocking until it is or cannot be, or
		for `timeout` seconds at most when that is more than `0`.
	**/
	private static function __open(host:Host, port:Int, timeout:Float):Socket {
		var socket:Socket = new Socket();

		try {
			socket.setFastSend(true);
			if (timeout > 0) {
				socket.setTimeout(timeout);
			}
			socket.connect(host, port);
		} catch (e:Dynamic) {
			try {
				socket.close();
			} catch (_:Dynamic) {}

			#if cpp
			cpp.Lib.rethrow(e);
			#else
			throw e;
			#end
		}

		return socket;
	}

	/**
	 * The connect's outcome, on the runtime's thread: sends the request and
	 * puts the socket in the poll set, or fails the exchange.
	 */
	private function __connected(outbound:Outbound, socket:Null<Socket>, failure:Dynamic):Void {
		var exchange:PHPExchange = outbound.exchange;

		// Timed out, or let go, while the connect was under way.
		if (outbound.closed || exchange.settled) {
			if (socket != null) {
				try {
					socket.close();
				} catch (_:Dynamic) {}
			}

			return;
		}

		if (socket == null) {
			if (exchange.expired()) {
				exchange.timeOut("connecting");
			} else {
				exchange.fail("Could not reach the PHP backend at " + outbound.host + ":" + outbound.port + ": " + Std.string(failure));
			}

			__finish(exchange);
			return;
		}

		outbound.socket = socket;

		try {
			socket.setBlocking(false);
			// Most requests fit the socket's send buffer and leave in this
			// call. A larger body goes out over the passes that follow, as the
			// backend reads it. It used to be written in one burst, and a
			// non-blocking socket with a full send buffer refuses the rest:
			// the upload failed as though the backend were down.
			__send(outbound);
		} catch (e:Dynamic) {
			exchange.fail("Could not reach the PHP backend at " + outbound.host + ":" + outbound.port + ": " + Std.string(e));
			__finish(exchange);
			return;
		}

		__watch(outbound);
	}

	/**
	 * Puts the exchange's socket in the runtime's poll set, so the reply is
	 * read the moment it arrives.
	 *
	 * It was read from the tick instead, which the runtime dispatches twelve
	 * times a second by default: every PHP response waited for the next one,
	 * up to 84ms and 42ms on average, whatever the backend took. A server's
	 * loop spends the time between ticks waiting in poll, and a socket in its
	 * set ends that wait when data arrives.
	 */
	private function __watch(outbound:Outbound):Void {
		var runtime:CrossByte = __runtime;

		if (runtime == null) {
			return;
		}

		outbound.socket.custom = outbound;
		@:privateAccess runtime.registerSocket(outbound.socket);
		outbound.runtime = runtime;

		// What did not fit the send buffer goes when the registry next asks,
		// and again after that for as long as the buffer stays full.
		if (outbound.written < outbound.payload.length) {
			@:privateAccess runtime.queueWritable(outbound.socket);
		}
	}

	/**
	 * Takes the socket out of the poll set and closes it. An exchange let go
	 * while its connect is under way has no socket yet; the connect's
	 * outcome finds it closed, and closes the socket itself.
	 */
	private function __release(outbound:Outbound):Void {
		outbound.closed = true;

		if (outbound.runtime != null) {
			@:privateAccess outbound.runtime.deregisterSocket(outbound.socket);
			outbound.runtime = null;
		}

		if (outbound.socket != null) {
			try {
				outbound.socket.close();
			} catch (_:Dynamic) {}
		}
	}

	/**
	 * The backend sent something, or hung up: reads what is there, and
	 * settles the exchange once the response is whole or cannot be.
	 */
	private function __onReadable(entry:Outbound):Void {
		if (entry.exchange.settled) {
			return;
		}

		try {
			if (__drain(entry) && !entry.exchange.settled) {
				entry.exchange.fail("PHP backend closed the connection before finishing the response.");
				__finish(entry.exchange);
			}
		} catch (e:Dynamic) {
			__abandon(entry, e);
		}
	}

	/** The socket may take more of a request too large for one write. **/
	private function __onWritable(entry:Outbound):Void {
		if (entry.exchange.settled || entry.written >= entry.payload.length) {
			return;
		}

		var failure:Dynamic = null;

		try {
			if (!__send(entry) && entry.runtime != null) {
				@:privateAccess entry.runtime.queueWritable(entry.socket);
			}
			return;
		} catch (e:Dynamic) {
			failure = e;
		}

		try {
			// Read first, so a backend that answered before taking the whole
			// body, a missing script, say, is still heard.
			__drain(entry);
		} catch (e:Dynamic) {
			__abandon(entry, e);
			return;
		}

		if (!entry.exchange.settled) {
			entry.exchange.fail("PHP backend stopped taking the request after " + entry.written + " of " + entry.payload.length + " bytes: "
				+ Std.string(failure));
			__finish(entry.exchange);
		}
	}

	/**
	 * Fails an exchange whose handling threw. Settled here rather than left to
	 * the registry, which reports a throw and keeps the socket: still
	 * readable, so handled, and thrown, again on every pass until the
	 * deadline.
	 */
	private function __abandon(entry:Outbound, error:Dynamic):Void {
		if (!entry.exchange.settled) {
			entry.exchange.fail("Reading the PHP backend's response failed: " + Std.string(error), error);
		}

		__finish(entry.exchange);
	}

	/**
	 * Reads what has arrived into the exchange, and succeeds it once
	 * END_REQUEST is in, or lets it go once the exchange has refused what
	 * arrived. Returns whether the backend hung up first.
	 *
	 * `READ_BUDGET` bytes a pass at most: the loop is told there is more, and
	 * polls again before it waits.
	 */
	private function __drain(entry:Outbound):Bool {
		var taken:Int = 0;
		while (true) {
			if (taken >= __readBudget) {
				if (entry.runtime != null) {
					@:privateAccess entry.runtime.__noteMoreToRead();
				}
				return false;
			}

			#if eval
			// A socket cannot be made non-blocking on eval, and a read with
			// nothing there would stop the runtime until the backend sent more.
			if (Socket.select([entry.socket], [], [], 0).read.length == 0) {
				return false;
			}
			#end

			var read:Int = 0;

			try {
				read = entry.socket.input.readBytes(__scratch, 0, __scratch.length);
			} catch (e:Dynamic) {
				// Blocked is the end of what has arrived; anything else is the
				// end of the connection.
				return !BlockedError.isBlocked(e);
			}

			if (read <= 0) {
				return false;
			}
			taken += read;

			if (entry.exchange.receive(__scratch, read)) {
				entry.exchange.succeed();
				__finish(entry.exchange);
				return false;
			}
			if (entry.exchange.settled) {
				// Refused as it arrived: past a limit.
				__finish(entry.exchange);
				return false;
			}

			// Short of the buffer: that was everything there was, and the
			// registry will say when there is more.
			if (read < __scratch.length) {
				return false;
			}
		}
	}
	#end

	/**
	 * Records an exchange so the deadline sweep can see it, and starts the
	 * sweep if it is not already running.
	 *
	 * The tick listener is added with the first exchange and dropped with the
	 * last, so a server with PHP configured and nothing using it costs nothing
	 * per frame.
	 */
	private function __track(tracked:Tracked):Void {
		__pending.push(tracked);

		if (__runtime == null) {
			__runtime = CrossByte.current();
		}

		if (__runtime != null && !__sweeping) {
			__sweeping = true;
			__runtime.addEventListener(TickEvent.TICK, __onTick);
		}
	}

	/**
		Lets an exchange that has settled go: its transport, its place among
		those with the backend, which the next waiting takes, or its place
		in the queue.
	**/
	private function __finish(exchange:PHPExchange, ?socket:Dynamic):Void {
		var finished:Null<Tracked> = null;
		for (entry in __pending) {
			if (entry.exchange == exchange) {
				finished = entry;
				__pending.remove(entry);
				break;
			}
		}

		#if !nodejs
		for (entry in __reading) {
			if (entry.exchange == exchange) {
				__reading.remove(entry);
				break;
			}
		}
		#end

		if (finished != null) {
			if (finished.release != null) {
				finished.release();
				finished.release = null;
			}
			if (finished.started) {
				finished.started = false;
				__inFlight--;
				__startWaiting();
			} else {
				__waiting.remove(finished);
			}
		}

		if (__pending.length == 0 && __sweeping && __runtime != null) {
			__runtime.removeEventListener(TickEvent.TICK, __onTick);
			__sweeping = false;
		}
	}

	/**
	 * Fails whatever has run out of time. The sockets are not read here: the
	 * runtime reads them when they are ready.
	 *
	 * The deadline is swept here rather than left to a socket timeout because
	 * a socket timeout bounds one read. A backend sending a byte a second
	 * resets it forever and never trips it, while this notices.
	 */
	private function __onTick(_:TickEvent):Void {
		var waiting = __pending.copy();

		for (entry in waiting) {
			if (!entry.exchange.settled && entry.exchange.expired()) {
				entry.exchange.timeOut(__phase(entry.exchange));
				__finish(entry.exchange);
			}
		}
	}

	/** What an exchange that ran out of time was doing: how its timeout is described. **/
	private function __phase(exchange:PHPExchange):String {
		for (entry in __waiting) {
			if (entry.exchange == exchange) {
				return __waitingPhase();
			}
		}
		#if !nodejs
		for (entry in __reading) {
			if (entry.exchange == exchange) {
				if (entry.socket == null) {
					return "connecting";
				}

				return entry.written < entry.payload.length ? "sending the request" : "reading the response";
			}
		}
		#end

		return "reading the response";
	}

	private inline function _onExit(e:Event):Void {
		stop();
	}

	private static inline function put(m:Map<String, String>, k:String, v:String):Void {
		if (v != null) {
			m.set(k, v);
		}
	}

	private static function safeScriptName(requestUri:String, index:Array<String>):String {
		if (requestUri == null) {
			return "/index.php";
		}

		if (requestUri.endsWith("/")) {
			return (index != null && index.length > 0) ? requestUri + index[0] : requestUri + "index.php";
		}
		return requestUri;
	}

	private static function beginRequestBody(role:Int, keepAlive:Bool):Bytes {
		var b:Bytes = Bytes.alloc(8);
		b.set(0, (role >> 8) & 0xFF);
		b.set(1, role & 0xFF);
		b.set(2, keepAlive ? 1 : 0);
		return b;
	}
}

private class Fcgi {
	public static inline var VERSION_1:Int = 1;
	public static inline var BEGIN_REQUEST:Int = 1;
	public static inline var END_REQUEST:Int = 3;
	public static inline var PARAMS:Int = 4;
	public static inline var STDIN:Int = 5;
	public static inline var STDOUT:Int = 6;
	public static inline var STDERR:Int = 7;
	public static inline var ROLE_RESPONDER:Int = 1;

	/**
	 * The most content one record carries here: a multiple of eight, so a
	 * full record needs no padding. The length field would take 65,535, but
	 * php-fpm refuses a PARAMS record whose content and padding together pass
	 * that, and padding 65,535 to eight would.
	 */
	public static inline var MAX_CONTENT:Int = 65528;

	static final PADDING:Bytes = Bytes.alloc(8);

	/** Appends one record carrying `length` bytes of `content` from `offset`. **/
	public static function record(out:BytesBuffer, type:Int, reqId:Int, content:Null<Bytes>, offset:Int, length:Int):Void {
		var padding:Int = (8 - (length & 7)) & 7;
		out.addByte(VERSION_1);
		out.addByte(type);
		out.addByte((reqId >> 8) & 0xFF);
		out.addByte(reqId & 0xFF);
		out.addByte((length >> 8) & 0xFF);
		out.addByte(length & 0xFF);
		out.addByte(padding);
		out.addByte(0);

		if (length > 0) {
			out.addBytes(content, offset, length);
		}

		if (padding > 0) {
			out.addBytes(PADDING, 0, padding);
		}
	}

	public static function nvpair(name:String, value:String):Bytes {
		var nb:Bytes = Bytes.ofString(name), vb = Bytes.ofString(value);
		var bb:BytesBuffer = new BytesBuffer();
		encLen(bb, nb.length);
		encLen(bb, vb.length);
		bb.add(nb);
		bb.add(vb);
		return bb.getBytes();
	}

	private static inline function encLen(bb:BytesBuffer, n:Int):Void {
		if (n < 128) {
			bb.addByte(n);
		} else {
			bb.addByte(((n >> 24) & 0x7F) | 0x80);
			bb.addByte((n >> 16) & 0xFF);
			bb.addByte((n >> 8) & 0xFF);
			bb.addByte(n & 0xFF);
		}
	}
}

/**
	An exchange the bridge has taken on, with what its connection to the
	backend needs: waiting for one, or with the backend.
**/
private class Tracked {
	public final exchange:PHPExchange;
	public final host:String;
	public final port:Int;
	public final payload:Bytes;

	/** Lets the transport go; null while there is none. **/
	public var release:Null<Void->Void> = null;

	/** Whether it is with the backend, holding one of `maxExchanges`. **/
	public var started:Bool = false;

	public function new(exchange:PHPExchange, host:String, port:Int, payload:Bytes) {
		this.exchange = exchange;
		this.host = host;
		this.port = port;
		this.payload = payload;
	}
}

#if !nodejs
/** A native exchange's socket, and how much of its request has been written. **/
@:access(crossbyte._internal.php.PHPBridge)
private class Outbound implements IPollableSocket {
	public final bridge:PHPBridge;
	public final exchange:PHPExchange;
	public final host:String;
	public final port:Int;
	public final payload:Bytes;
	public var written:Int = 0;

	/** Null while the connect is under way. **/
	public var socket:Null<Socket> = null;

	/** The runtime whose poll set holds the socket, while one does. **/
	public var runtime:Null<CrossByte> = null;

	/** Set once the bridge has let the socket go. **/
	public var closed:Bool = false;

	public var registryClosed(get, never):Bool;

	public function new(bridge:PHPBridge, exchange:PHPExchange, host:String, port:Int, payload:Bytes) {
		this.bridge = bridge;
		this.exchange = exchange;
		this.host = host;
		this.port = port;
		this.payload = payload;
	}

	public function registryOnReadable():Void {
		bridge.__onReadable(this);
	}

	public function registryOnWritable():Void {
		bridge.__onWritable(this);
	}

	public function registryHasBufferedInput():Bool {
		return false;
	}

	private function get_registryClosed():Bool {
		return closed || exchange.settled;
	}
}

#if target.threaded
/** What the connector thread is handed. An enum, since the jvm's queue refuses null. **/
private enum ConnectorJob {
	Connect(outbound:Outbound);
	Stop;
}
#end
#end

// The include is metadata on the class, so it lands in the generated .cpp
// whatever the body's own guard says; left unguarded, a Linux or macOS build
// fails looking for a header only Windows has.
#if (cpp && windows)
@:cppInclude("Windows.h")
#end
private class WindowsKillOnExit {
	public static function attach():Void {
		#if (cpp && windows)
		_attach();
		#end
	}

	#if (cpp && windows)
	static function _attach():Void {
		untyped __cpp__(" 
			HANDLE gJob = NULL;
            if (gJob) return;
            gJob = CreateJobObjectW(NULL, NULL);
            if (!gJob) return;
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli = {};
            jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(gJob, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
            // Put *current* process into the job; children inherit membership.
            AssignProcessToJobObject(gJob, GetCurrentProcess());
			");
	}
	#end
}
#end
