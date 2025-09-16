package crossbyte._internal.php;

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
	public final mode:PHPMode;
	public final docRoot:String;
	public final autoIndex:Array<String>;

	private var _proc:Null<Process> = null;

	static final PAD_SCRATCH = Bytes.alloc(256);

	public function new(mode:PHPMode, ?docRoot:String, ?autoIndex:Array<String>) {
		this.mode = mode;
		this.docRoot = docRoot != null ? docRoot : "";
		this.autoIndex = autoIndex != null ? autoIndex : ["index.php", "index.html"];

		switch (mode) {
			case Launch(address, port, phpCgiPath, phpIniPath):
				if (_proc != null)
					try {
						_proc.close();
					} catch (_:Dynamic) {};
				var args:Array<String> = ["-b", address + ":" + port];
				if (phpIniPath != null && phpIniPath != "") {
					var iniPath:String = phpIniPath;
					if (iniPath == "php.ini") {
						iniPath = Sys.programPath() + iniPath;
					}
					if (FileSystem.exists(iniPath)) {
						args = ["-c", iniPath].concat(args);
					}
				}
				WindowsKillOnExit.attach();
				_proc = new Process(phpCgiPath, args);
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
		sock.connect(new Host(host), port);

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
			var hdr:Bytes = Bytes.alloc(8);
			var r:Int = sock.input.readBytes(hdr, 0, 8);
			if (r != 8)
				throw "FastCGI short header";
			var typ:Int = hdr.get(1);
			var cLen:Int = (hdr.get(4) << 8) | hdr.get(5);
			var pad:Int = hdr.get(6);

			var content:Bytes = Bytes.alloc(cLen);
			if (cLen > 0) {
				sock.input.readBytes(content, 0, cLen);
			}

			if (pad > 0) {
				sock.input.readBytes(PAD_SCRATCH, 0, pad);
			}

			switch (typ) {
				case Fcgi.STDOUT:
					rawBytes.add(content);
				case Fcgi.STDERR:
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
							status = Std.parseInt(sp[0]);
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
