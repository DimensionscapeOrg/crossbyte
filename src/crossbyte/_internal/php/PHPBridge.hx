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
import sys.net.Host;
import sys.net.Socket;
import sys.io.Process;
#end

using StringTools;

class PHPBridge {
	/**
		Seconds a single FastCGI exchange may take before it is abandoned.

		`0` disables the deadline, which is what this class did unconditionally
		before: no socket timeout, and a read loop that would wait for a peer
		that had stopped talking. A CrossByte runtime serves every one of its
		connections from one tick, so that was not one slow request -- it was
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

	// Launch mode spawns php-cgi. Node has no sys.io.Process, so it uses
	// CrossByte's own NativeProcess -- the portable subprocess API this
	// framework already ships -- rather than a second bespoke wrapper. Both
	// answer close(), which is all stop() needs of them.
	#if nodejs
	private var _proc:Null<NativeProcess> = null;
	#else
	private var _proc:Null<Process> = null;
	#end
	private var __pending:Array<{exchange:PHPExchange, release:Void->Void}> = [];
	private var __runtime:Null<CrossByte> = null;
	private var __sweeping:Bool = false;
	#if !nodejs
	private var __reading:Array<{exchange:PHPExchange, socket:Socket}> = [];
	private var __scratch:Bytes = Bytes.alloc(8192);
	#end

	static final PAD_SCRATCH = Bytes.alloc(256);

	public function new(mode:PHPMode, ?docRoot:String, ?autoIndex:Array<String>, timeoutSeconds:Float = DEFAULT_TIMEOUT) {
		this.mode = mode;
		this.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 0;
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
	}

	/**
	 * Starts a FastCGI exchange and hands back its eventual response.
	 *
	 * This returned a `PHPResponse` before, and that signature was the whole
	 * problem. A blocking round trip inside a tick stops the runtime for every
	 * connection it serves, not just this one, and it cannot exist at all on a
	 * target with no synchronous socket read -- which is why PHP was the last
	 * thing unavailable on Node.
	 *
	 * `Future` rather than a callback pair, because the framework already has
	 * one way of saying "later" and a second would be a second.
	 */
	public function execute(req:PHPRequest):Future<PHPResponse> {
		var exchange = new PHPExchange(timeoutSeconds);

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

		final out = new BytesBuffer();
		out.add(Fcgi.rec(Fcgi.BEGIN_REQUEST, 1, beginRequestBody(Fcgi.ROLE_RESPONDER, false)));

		var paramsBuf:BytesBuffer = new BytesBuffer();
		for (k in env.keys()) {
			paramsBuf.add(Fcgi.nvpair(k, env.get(k)));
		}

		out.add(Fcgi.rec(Fcgi.PARAMS, 1, paramsBuf.getBytes()));
		out.add(Fcgi.rec(Fcgi.PARAMS, 1, Bytes.alloc(0)));

		var body:Bytes = req.body != null ? req.body : Bytes.alloc(0);
		if (body.length > 0) {
			out.add(Fcgi.rec(Fcgi.STDIN, 1, body));
		}

		out.add(Fcgi.rec(Fcgi.STDIN, 1, Bytes.alloc(0)));

		var payload:Bytes = out.getBytes();

		__begin(exchange, host, port, payload);
		return exchange.future;
	}

	/**
	 * Opens the transport and starts the exchange.
	 *
	 * The two targets differ only in how bytes come back. Node is told and a
	 * native build has to ask, so a native build reads from the tick it is
	 * already being given; everything else -- the parser, the deadline, the
	 * table -- is shared, and that is the point of the split.
	 */
	private function __begin(exchange:PHPExchange, host:String, port:Int, payload:Bytes):Void {
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

		__track(exchange, function():Void {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		});

		socket.connect(host, port);
		#else
		var socket:Socket = new Socket();
		socket.setFastSend(true);

		try {
			socket.connect(new Host(host), port);
			socket.setBlocking(false);
			socket.output.write(payload);
			socket.output.flush();
		} catch (e:Dynamic) {
			try {
				socket.close();
			} catch (_:Dynamic) {}

			if (exchange.expired()) {
				exchange.timeOut("connecting");
			} else {
				exchange.fail("Could not reach the PHP backend: " + Std.string(e));
			}

			return;
		}

		__reading.push({exchange: exchange, socket: socket});

		__track(exchange, function():Void {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		});
		#end
	}

	/**
	 * Records an exchange so the deadline sweep can see it, and starts the
	 * sweep if it is not already running.
	 *
	 * The tick listener is added with the first exchange and dropped with the
	 * last, so a server with PHP configured and nothing using it costs nothing
	 * per frame.
	 */
	private function __track(exchange:PHPExchange, release:Void->Void):Void {
		__pending.push({exchange: exchange, release: release});

		if (__runtime == null) {
			__runtime = CrossByte.current();
		}

		if (__runtime != null && !__sweeping) {
			__sweeping = true;
			__runtime.addEventListener(TickEvent.TICK, __onTick);
		}
	}

	private function __finish(exchange:PHPExchange, ?socket:Dynamic):Void {
		for (entry in __pending) {
			if (entry.exchange == exchange) {
				entry.release();
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

		if (__pending.length == 0 && __sweeping && __runtime != null) {
			__runtime.removeEventListener(TickEvent.TICK, __onTick);
			__sweeping = false;
		}
	}

	/**
	 * One frame's worth of work: read whatever has arrived, then fail whatever
	 * has run out of time.
	 *
	 * The deadline is swept here rather than left to a socket timeout because
	 * a socket timeout bounds one read. A backend sending a byte a second
	 * resets it forever and never trips it, while this notices.
	 */
	private function __onTick(_:TickEvent):Void {
		#if !nodejs
		var reading = __reading.copy();

		for (entry in reading) {
			if (entry.exchange.settled) {
				continue;
			}

			var closed:Bool = false;

			// Drains what is there and stops on the blocked error a
			// non-blocking socket raises when it is empty, which is the normal
			// end of a frame's reading rather than a failure.
			while (true) {
				var read:Int = 0;

				try {
					read = entry.socket.input.readBytes(__scratch, 0, __scratch.length);
				} catch (e:Dynamic) {
					if (!crossbyte._internal.socket.BlockedError.isBlocked(e)) {
						closed = true;
					}

					break;
				}

				if (read <= 0) {
					break;
				}

				if (entry.exchange.receive(__scratch, read)) {
					entry.exchange.succeed();
					__finish(entry.exchange);
					closed = false;
					break;
				}
			}

			if (closed && !entry.exchange.settled) {
				entry.exchange.fail("PHP backend closed the connection before finishing the response.");
				__finish(entry.exchange);
			}
		}
		#end

		var waiting = __pending.copy();

		for (entry in waiting) {
			if (!entry.exchange.settled && entry.exchange.expired()) {
				entry.exchange.timeOut("reading the response");
				__finish(entry.exchange);
			}
		}
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

	public static function rec(typ:Int, reqId:Int, content:Bytes):Bytes {
		var padLen:Int = (8 - (content.length & 7)) & 7;
		var bb:BytesBuffer = new BytesBuffer();
		bb.addByte(VERSION_1);
		bb.addByte(typ);
		bb.addByte((reqId >> 8) & 0xFF);
		bb.addByte(reqId & 0xFF);
		bb.addByte((content.length >> 8) & 0xFF);
		bb.addByte(content.length & 0xFF);
		bb.addByte(padLen);
		bb.addByte(0);
		if (content.length > 0) {
			bb.add(content);
		}

		if (padLen > 0) {
			bb.add(Bytes.alloc(padLen));
		}

		return bb.getBytes();
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
			var b:Bytes = Bytes.alloc(1);
			b.set(0, n);
			bb.add(b);
		} else {
			var b:Bytes = Bytes.alloc(4);
			b.set(0, ((n >> 24) & 0x7F) | 0x80);
			b.set(1, (n >> 16) & 0xFF);
			b.set(2, (n >> 8) & 0xFF);
			b.set(3, n & 0xFF);
			bb.add(b);
		}
	}
}

@:cppInclude("Windows.h")
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
