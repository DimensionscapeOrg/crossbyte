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
	private var __reading:Array<Outbound> = [];
	private var __scratch:Bytes = Bytes.alloc(8192);
	#end

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

		var payload:Bytes;

		try {
			payload = encodeRequest(env, req.body);
		} catch (e:Dynamic) {
			exchange.fail(Std.string(e));
			return exchange.future;
		}

		__begin(exchange, host, port, payload);
		return exchange.future;
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
	 * in both -- and a single pair too large for one record cannot be sent at
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

		var outbound = new Outbound(exchange, socket, payload);

		try {
			socket.connect(new Host(host), port);
			socket.setBlocking(false);
			// Most requests fit the socket's send buffer and leave in this
			// call. A larger body goes out over the ticks that follow, as the
			// backend reads it. It used to be written in one burst, and a
			// non-blocking socket with a full send buffer refuses the rest:
			// the upload failed as though the backend were down.
			__send(outbound);
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

		__reading.push(outbound);

		__track(exchange, function():Void {
			try {
				socket.close();
			} catch (_:Dynamic) {}
		});
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
	#end

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
			var writeFailure:String = null;

			// The rest of a request too large to leave in one write, before
			// reading: a backend answers only once it has the whole body.
			if (entry.written < entry.payload.length) {
				try {
					__send(entry);
				} catch (e:Dynamic) {
					writeFailure = Std.string(e);
				}
			}

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

			if (entry.exchange.settled) {
				continue;
			}

			// Read first, so a backend that answered before taking the whole
			// body -- a missing script, say -- is still heard.
			if (writeFailure != null) {
				entry.exchange.fail("PHP backend stopped taking the request after " + entry.written + " of " + entry.payload.length + " bytes: " + writeFailure);
				__finish(entry.exchange);
			} else if (closed) {
				entry.exchange.fail("PHP backend closed the connection before finishing the response.");
				__finish(entry.exchange);
			}
		}
		#end

		var waiting = __pending.copy();

		for (entry in waiting) {
			if (!entry.exchange.settled && entry.exchange.expired()) {
				entry.exchange.timeOut(__sending(entry.exchange) ? "sending the request" : "reading the response");
				__finish(entry.exchange);
			}
		}
	}

	/** Whether part of this exchange's request is still waiting to be written. **/
	private function __sending(exchange:PHPExchange):Bool {
		#if !nodejs
		for (entry in __reading) {
			if (entry.exchange == exchange) {
				return entry.written < entry.payload.length;
			}
		}
		#end

		return false;
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

#if !nodejs
/** A native exchange's socket, and how much of its request has been written. **/
private class Outbound {
	public final exchange:PHPExchange;
	public final socket:Socket;
	public final payload:Bytes;
	public var written:Int = 0;

	public function new(exchange:PHPExchange, socket:Socket, payload:Bytes) {
		this.exchange = exchange;
		this.socket = socket;
		this.payload = payload;
	}
}
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
