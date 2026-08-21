package crossbyte._internal.php;

// Not built for the browser: it launches and talks to a PHP CGI process.
#if nodejs
import crossbyte.errors.IllegalOperationError;

/**
 * The bridge's shape on Node, which cannot yet be one.
 *
 * Not for want of a transport or a way to start php-cgi. Both arrived with the
 * Node work: `crossbyte.net.Socket` speaks to a FastCGI listener over
 * `js.node.net`, and `crossbyte.sys.NativeProcess` launches a process over
 * `child_process`. What stands in the way is the signature -- `execute()`
 * returns a response, and Node has no synchronous socket read to produce one
 * with. hxnodejs ships a `sys.net.Socket` that blocks, but it has no output
 * side at all and its wait needs `deasync`, a native npm addon, so it is not a
 * way round this.
 *
 * The way round it is to stop returning a response. A bridge that hands its
 * result to a callback works on every target, and CrossByte is already shaped
 * for it: middleware is `(HTTPRequestHandler, ?Dynamic->Void) -> Void`, and
 * responses already stream. It would also stop a PHP request stalling a native
 * runtime for its whole duration, which is what a blocking call in a tick does
 * today. That is a change to the request handler on every target, though, and
 * belongs in its own proposal rather than arriving as a side effect of a Node
 * port.
 *
 * The type is kept rather than compiled away because `HTTPRequestHandler`
 * threads it through a dozen places, and because `__php == null` is already the
 * state the whole handler is written for -- it is what a server with PHP off
 * looks like, which is the default everywhere. That includes refusing to serve
 * a `.php` file as its own source, which is the part that would become a
 * security hole if this type simply vanished.
 */
class PHPBridge {
	/** Matches the native bridge's field so a caller reads the same shape. **/
	public final timeoutSeconds:Float = 0;

	public function new(mode:PHPMode, ?docRoot:String, ?autoIndex:Array<String>, timeoutSeconds:Float = 0) {
		throw new IllegalOperationError("PHP is not available on Node yet: the bridge returns a response, and Node has no synchronous socket read to produce one with. Put PHP-FPM behind a proxy, or run the server on a native target.");
	}

	public function stop():Void {}

	public function execute(req:PHPRequest):PHPResponse {
		throw new IllegalOperationError("PHP is not available on Node yet.");
	}
}
#elseif !js

import haxe.io.Path;
import crossbyte.events.Event;
import crossbyte.core.CrossByte;
import sys.FileSystem;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.net.Host;
import sys.net.Socket;
import sys.io.Process;

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

	private var _proc:Null<Process> = null;

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
				_proc = new Process(cgiPath, args);
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

	public function execute(req:PHPRequest):PHPResponse {
		if (docRoot != "" && req.scriptFilename.indexOf("..") >= 0) {
			throw "Traversal refused";
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

		var sock:Socket = new Socket();
		sock.setFastSend(true);

		// Applies to connect and to every read below. A backend that is not
		// listening at all fails here rather than blocking, which it did.
		if (timeoutSeconds > 0) {
			sock.setTimeout(timeoutSeconds);
		}

		var deadline:Float = timeoutSeconds > 0 ? Sys.time() + timeoutSeconds : 0;

		try {
			sock.connect(new Host(host), port);
		} catch (e:Dynamic) {
			try {
				sock.close();
			} catch (_:Dynamic) {}

			if (deadline > 0 && Sys.time() >= deadline) {
				throw new PHPTimeout(timeoutSeconds, "connecting");
			}

			throw e;
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

		sock.output.write(out.getBytes());
		sock.output.flush();

		var rawBytes:BytesBuffer = new BytesBuffer();
		var done:Bool = false;
		while (!done) {
			// Checked per record, not only per read. A socket timeout bounds
			// one operation; a peer dribbling a byte at a time resets it
			// forever and never trips it. The deadline bounds the exchange.
			if (deadline > 0 && Sys.time() >= deadline) {
				try {
					sock.close();
				} catch (_:Dynamic) {}

				throw new PHPTimeout(timeoutSeconds, "reading the response");
			}

			var hdr:Bytes = Bytes.alloc(8);
			var typ:Int;
			var content:Bytes;

			// The clock decides what a read failure meant, because the socket
			// cannot say. A read that expires on SO_RCVTIMEO surfaces as Eof
			// here -- identical to a peer that closed -- so distinguishing the
			// two by the error is not possible. Distinguishing them by the
			// deadline is, and it is the distinction that matters: one is a
			// backend that stopped answering, the other is one that hung up.
			try {
				var r:Int = sock.input.readBytes(hdr, 0, 8);
				if (r != 8)
					throw "FastCGI short header";
				typ = hdr.get(1);
				var cLen:Int = (hdr.get(4) << 8) | hdr.get(5);
				var pad:Int = hdr.get(6);

				content = Bytes.alloc(cLen);
				if (cLen > 0) {
					sock.input.readFullBytes(content, 0, cLen);
				}

				if (pad > 0) {
					sock.input.readFullBytes(PAD_SCRATCH, 0, pad);
				}
			} catch (e:Dynamic) {
				try {
					sock.close();
				} catch (_:Dynamic) {}

				// The grace is because the socket timeout and this deadline
				// are the same instant, and whichever is read second is a
				// hair past it.
				if (deadline > 0 && Sys.time() + READ_DEADLINE_GRACE >= deadline) {
					throw new PHPTimeout(timeoutSeconds, "reading the response");
				}

				throw e;
			}

			switch (typ) {
				case Fcgi.STDOUT:
					rawBytes.add(content);

				case Fcgi.STDERR:
					// c apture stderr but DO NOT terminate the read loop.
					// var err = content.toString();
					// Logger.log('[php-cgi] ' + err);

				case Fcgi.END_REQUEST:
					done = true;

				default:
			}
		}
		sock.close();

		var buf:Bytes = rawBytes.getBytes();
		var s:String = buf.toString();
		var sep:Int = s.indexOf("\r\n\r\n");
		var headers:Map<String, String> = new Map();
		var status = 200;
		var bodyBytes = Bytes.alloc(0);

		if (sep >= 0) {
			var headerLines:Array<String> = s.substr(0, sep).split("\r\n");
			for (line in headerLines) {
				var i:Int = line.indexOf(":");
				if (i > 0) {
					var hk:String = line.substr(0, i).toLowerCase();
					var hv:String = StringTools.trim(line.substr(i + 1));
					headers.set(hk, hv);
					if (hk == "status") {
						var sp:Array<String> = hv.split(" ");
						if (sp.length > 0) {
							var parsedStatus = Std.parseInt(sp[0]);
							if (parsedStatus != null) {
								status = parsedStatus;
							}
						}
					}
				}
			}
			bodyBytes = Bytes.ofString(s.substr(sep + 4));
		} else {
			bodyBytes = buf;
		}

		return {status: status, headers: headers, body: bodyBytes};
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
