package crossbyte.http;

import haxe.ds.StringMap;
import crossbyte.events.EventDispatcher;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import crossbyte.url.URLRequestHeader;
import crossbyte.utils.Logger;
import crossbyte._internal.php.PHPBridge;
import crossbyte._internal.php.PHPRequest;
import crossbyte._internal.php.PHPResponse;
import crossbyte._internal.http.Http;

final class HTTPRequestHandler extends EventDispatcher {
	@:noCompletion private static inline var MAX_BUFFER_SIZE:Int = 1024 * 1024; // 1 MB
	@:noCompletion private static final ALLOWED_METHODS:Array<String> = ["GET", "HEAD", "OPTIONS", "POST"];

	@:noCompletion private var __origin:Socket;
	@:noCompletion private var __incomingBuffer:ByteArray;
	@:noCompletion private var __config:HTTPServerConfig;
	@:noCompletion private var __headers:Map<String, String>;
	@:noCompletion private var __method:String;
	@:noCompletion private var __filePath:String;
	@:noCompletion private var __httpVersion:String;
	@:noCompletion private var __php:PHPBridge;
	@:noCompletion private var __queryString:String = "";
	@:noCompletion private var __requestPath:String = "/";
	@:noCompletion private var __awaitingBody:Bool = false;
	@:noCompletion private var __expectBody:Int = 0;
	@:noCompletion private var __bodyBuf:ByteArray = null;
	@:noCompletion private var __bodyTargetPhpPath:String = null;
	@:noCompletion private var __bodyHeadOnly:Bool = false;

	public function new(socket:Socket, config:HTTPServerConfig, ?php:PHPBridge) {
		super();
		__origin = socket;
		__config = config;
		__incomingBuffer = new ByteArray();
		__headers = new Map<String, String>();
		__setup();
		__php = php;
	}

	public function getCookie(name:String):String {
		var h:String = __getCookieHeader();
		if (h == null) {
			return null;
		}

		var parts:Array<String> = h.split(";");
		for (p in parts) {
			var kv:String = StringTools.trim(p);
			var eq:Int = kv.indexOf("=");
			if (eq > 0) {
				var k:String = StringTools.trim(kv.substr(0, eq));
				var v:String = StringTools.trim(kv.substr(eq + 1));
				if (k == name) {
					return v;
				}
			}
		}
		return null;
	}

	public function getAllCookies():StringMap<String> {
		var out:StringMap<String> = new StringMap();
		var h:String = __getCookieHeader();
		if (h == null)
			return out;
		var parts:Array<String> = h.split(";");
		for (p in parts) {
			var kv:String = StringTools.trim(p);
			var eq:Int = kv.indexOf("=");
			if (eq > 0) {
				var k:String = StringTools.trim(kv.substr(0, eq));
				var v:String = StringTools.trim(kv.substr(eq + 1));
				out.set(k, v);
			}
		}
		return out;
	}

	@:noCompletion private function __setup():Void {
		__origin.addEventListener(ProgressEvent.SOCKET_DATA, __onData);
	}

	@:noCompletion private inline function __getCookieHeader():String {
		return __headers.exists("cookie") ? __headers.get("cookie") : null;
	}

	@:noCompletion private function __onData(e:ProgressEvent):Void {
		try {
			__origin.readBytes(__incomingBuffer, __incomingBuffer.length);

			if (__incomingBuffer.length > MAX_BUFFER_SIZE) {
				__sendErrorResponse(413, "Payload Too Large");
				if (__origin.connected) {
					__origin.close();
				}

				return;
			}

			if (__awaitingBody) {
				__readBodyFromBuffer();
				if (!__awaitingBody) {
					__finishPhpWithBody();
				}

				return;
			}

			__parseRequest();
		} catch (error:Dynamic) {
			Logger.error("Error reading data: " + error);
			__sendErrorResponse(500, "Internal Server Error");
		}
	}

	@:noCompletion private inline function __sendMethodNotAllowed():Void {
		var hdrs:Array<URLRequestHeader> = [new URLRequestHeader("Allow", ALLOWED_METHODS.join(", "))];
		__dispatchResponse(405, "Method Not Allowed", hdrs, "text/plain", "405 Method Not Allowed");
		if (__origin.connected) {
			__origin.close();
		}
	}

	@:noCompletion private function __parseRequest():Void {
		var requestLine:Null<String> = __readLine(__incomingBuffer);
		if (requestLine == null) {
			return;
		}

		requestLine = StringTools.trim(requestLine);
		var parts:Array<String> = requestLine.split(" ");
		if (parts.length < 3) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}

		__method = parts[0].toUpperCase();
		var rawTarget:String = parts[1];
		__httpVersion = parts[2];

		if (!Http.validateHttpVersion(__httpVersion)) {
			__sendErrorResponse(505, "HTTP Version Not Supported");
			return;
		}

		var qPos:Int = rawTarget.indexOf("?");
		if (qPos >= 0) {
			__queryString = rawTarget.substr(qPos + 1);
		} else {
			__queryString = "";
		}

		var pathOnly:String = (qPos >= 0) ? rawTarget.substr(0, qPos) : rawTarget;
		var h:Int = pathOnly.indexOf("#");
		if (h >= 0)
			pathOnly = pathOnly.substr(0, h);

		try {
			pathOnly = StringTools.urlDecode(pathOnly);
			__requestPath = pathOnly;
		} catch (_:Dynamic) {
			__sendErrorResponse(400, "Bad Request");
			return;
		}

		var resolvedFile:File = __resolveSafePath(__config.rootDirectory, pathOnly);
		if (resolvedFile == null) {
			__sendErrorResponse(403, "Forbidden");
			return;
		}
		__filePath = resolvedFile.nativePath;
		while (true) {
			var headerLine:Null<String> = __readLine(__incomingBuffer);
			if (headerLine == null) {
				return;
			}

			headerLine = StringTools.trim(headerLine);
			if (headerLine.length == 0) {
				break;
			}

			var sep:Int = headerLine.indexOf(":");
			if (sep <= 0) {
				continue;
			}

			var key:String = StringTools.trim(headerLine.substr(0, sep)).toLowerCase();
			var value:String = StringTools.trim(headerLine.substr(sep + 1));

			if (__headers.exists(key)) {
				if (key == "cookie") {
					__headers.set(key, __headers.get(key) + "; " + value);
				} else {
					__headers.set(key, __headers.get(key) + ", " + value);
				}
			} else {
				__headers.set(key, value);
			}
		}

		switch (__method) {
			case "GET":
				__serveFile(__filePath);
			case "HEAD":
				__serveFile(__filePath, true);
			case "OPTIONS":
				if (__config.corsEnabled) {
					__handleOptionsRequest();
				} else {
					__sendMethodNotAllowed();
				}
			case "POST":
				__handlePost(__filePath);

			default:
				__sendMethodNotAllowed();
		}
	}

	@:noCompletion private function __handleOptionsRequest():Void {
		var response:String = "HTTP/1.1 204 No Content\r\n";

		response += "Date: " + __formatHttpDate() + "\r\n";
		response += "Server: CrossByte\r\n";
		response += "X-Content-Type-Options: nosniff\r\n";
		response += "Connection: close\r\n";

		var allowOrigin = __computeAllowOrigin();
		if (allowOrigin != null) {
			response += "Access-Control-Allow-Origin: " + allowOrigin + "\r\n";
		}
		if (__config.corsAllowCredentials && allowOrigin != "*") {
			response += "Access-Control-Allow-Credentials: true\r\n";
		}
		response += "Vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\n";

		var reqMethod:String = __headers.exists("access-control-request-method") ? __headers.get("access-control-request-method") : null;
		response += "Access-Control-Allow-Methods: " + (reqMethod != null ? reqMethod : __config.corsAllowedMethods.join(", ")) + "\r\n";

		var reqHdrs:String = __headers.exists("access-control-request-headers") ? __headers.get("access-control-request-headers") : null;
		response += "Access-Control-Allow-Headers: " + (reqHdrs != null ? reqHdrs : __config.corsAllowedHeaders.join(", ")) + "\r\n";

		if (__config.corsMaxAge > 0) {
			response += "Access-Control-Max-Age: " + __config.corsMaxAge + "\r\n";
		}
		response += "Allow: " + ALLOWED_METHODS.join(", ") + "\r\n";
		response += "Content-Length: 0\r\n\r\n";

		__origin.writeUTFBytes(response);
		__origin.flush();
		__origin.close();
	}

	@:noCompletion private function __serveFile(filePath:String, headOnly:Bool = false):Void {
		var file:File = new File(filePath);

		if (__config.blacklist.indexOf(file.nativePath) != -1) {
			__dispatchResponse(403, "Forbidden", null, "text/plain", "403 Forbidden");
			return;
		}
		if (__config.whitelist.length > 0 && __config.whitelist.indexOf(file.nativePath) == -1) {
			__dispatchResponse(403, "Forbidden", null, "text/plain", "403 Forbidden");
			return;
		}

		if (!file.exists) {
			__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
			if (!headOnly && __origin.connected) {
				__origin.close();
			}

			return;
		}

		if (file.isDirectory) {
			var indexFile:String = __findIndexFile(file);
			if (indexFile != null) {
				__serveFile(indexFile, headOnly);
			} else {
				__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
				if (!headOnly && __origin.connected)
					__origin.close();
			}
			return;
		} else {
			if (__php != null && __isPhp(file.nativePath)) {
				__servePhp(file.nativePath, headOnly);
				return;
			}
		}

		file.load();
		var total:UInt = file.data.length;
		var lastModifiedTime:Float = file.modificationDate.getTime();
		var lastModHeader = new URLRequestHeader("Last-Modified", __toHttpDate(lastModifiedTime));
		var mimeType:String = __getMimeType(file.nativePath);

		var ims:String = __headers.exists("if-modified-since") ? __headers.get("if-modified-since") : null;
		if (ims != null) {
			try {
				var since = Date.fromString(ims);
				if (since != null && lastModifiedTime <= since.getTime()) {
					var h = [new URLRequestHeader("Accept-Ranges", "bytes"), lastModHeader];
					__dispatchResponse(304, "Not Modified", h, "text/plain", "", true);
					if (__origin.connected) {
						__origin.close();
					}

					return;
				}
			} catch (_:Dynamic) {}
		}

		var baseHeaders:Array<URLRequestHeader> = [new URLRequestHeader("Accept-Ranges", "bytes"), lastModHeader];
		var rangeHdr:String = __headers.exists("range") ? __headers.get("range") : null;

		if (rangeHdr != null) {
			var r:Dynamic = __parseRange(rangeHdr, total);
			if (r == null) {
				var h:Array<URLRequestHeader> = baseHeaders.concat([new URLRequestHeader("Content-Range", 'bytes */${total}')]);
				__dispatchResponse(416, "Range Not Satisfiable", h, "text/plain", "Requested Range Not Satisfiable", headOnly);
			} else {
				var start:Int = r.start;
				var end:Int = r.end;
				var len:Int = end - start + 1;

				var slice = new ByteArray();
				slice.writeBytes(file.data, start, len);

				var h = baseHeaders.concat([new URLRequestHeader("Content-Range", 'bytes ${start}-${end}/${total}')]);
				__dispatchResponseBytes(206, "Partial Content", h, mimeType, slice, headOnly);
			}
		} else {
			__dispatchResponseBytes(200, "OK", baseHeaders, mimeType, file.data, headOnly);
		}

		if (__origin.connected) {
			__origin.close();
		}
	}

	@:noCompletion private function __dispatchResponseBytes(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String,
			data:ByteArray, headOnly:Bool = false):Void {
		var clientAddress:String = __origin.remoteAddress;
		Logger.info("Client " + clientAddress + " requested " + __origin.remoteAddress + " - Status: " + statusCode);

		var statusEvent:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusCode, false);
		statusEvent.responseURL = __origin.remoteAddress;
		statusEvent.responseHeaders = headers;
		dispatchEvent(statusEvent);

		if (!__origin.connected) {
			return;
		}

		var response:String = "HTTP/1.1 " + statusCode + " " + statusMessage + "\r\n";
		response += "Date: " + __formatHttpDate() + "\r\n";
		response += "Connection: close\r\n";
		response += "Content-Type: " + contentType + "\r\n";
		response += "X-Content-Type-Options: nosniff\r\n";
		response += "Server: CrossByte\r\n";

		if (headers != null) {
			for (h in headers) {
				response += h.name + ": " + h.value + "\r\n";
			}
		}

		if (__config.corsEnabled) {
			var allowOrigin = __computeAllowOrigin();
			if (allowOrigin != null) {
				response += "Access-Control-Allow-Origin: " + allowOrigin + "\r\n";
			}
			if (__config.corsAllowCredentials && allowOrigin != "*") {
				response += "Access-Control-Allow-Credentials: true\r\n";
			}
			response += "Vary: Origin\r\n";
			response += "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, Last-Modified\r\n";
		}

		for (header in __config.customHeaders) {
			response += header.name + ": " + header.value + "\r\n";
		}

		var byteLen:UInt = (data != null) ? data.length : 0;
		response += "Content-Length: " + byteLen + "\r\n";
		response += "\r\n";

		__origin.writeUTFBytes(response);

		if (!headOnly && data != null && byteLen > 0) {
			__origin.writeBytes(data, 0, byteLen);
		}

		__origin.flush();
	}

	@:noCompletion private function __findIndexFile(directory:File):Null<String> {
		for (index in __config.directoryIndex) {
			var indexPath:File = directory.resolvePath(index);
			if (indexPath.exists) {
				return indexPath.nativePath;
			}
		}
		return null;
	}

	@:noCompletion private function __dispatchResponse(statusCode:Int, statusMessage:String, headers:Array<URLRequestHeader>, contentType:String,
			content:String, headOnly:Bool = false):Void {
		var clientAddress:String = __origin.remoteAddress;
		Logger.info("Client " + clientAddress + " requested " + __origin.remoteAddress + " - Status: " + statusCode);

		var statusEvent:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, statusCode, false);
		statusEvent.responseURL = __origin.remoteAddress;
		statusEvent.responseHeaders = headers;
		dispatchEvent(statusEvent);

		if (!__origin.connected) {
			return;
		}

		var bodyBytes:ByteArray = new ByteArray();
		if (!headOnly && content != null && content.length > 0) {
			bodyBytes.writeUTFBytes(content);
		}

		var response:String = "HTTP/1.1 " + statusCode + " " + statusMessage + "\r\n";
		response += "Date: " + __formatHttpDate() + "\r\n";
		response += "Connection: close\r\n";
		response += "Content-Type: " + contentType + "\r\n";
		response += "X-Content-Type-Options: nosniff\r\n";
		response += "Server: CrossByte\r\n";

		if (headers != null) {
			for (h in headers) {
				response += h.name + ": " + h.value + "\r\n";
			}
		}

		if (__config.corsEnabled) {
			var allowOrigin = __computeAllowOrigin();
			if (allowOrigin != null) {
				response += "Access-Control-Allow-Origin: " + allowOrigin + "\r\n";
			}
			if (__config.corsAllowCredentials && allowOrigin != "*") {
				response += "Access-Control-Allow-Credentials: true\r\n";
			}
			response += "Vary: Origin\r\n";
			response += "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, Last-Modified\r\n";
		}

		for (header in __config.customHeaders) {
			response += header.name + ": " + header.value + "\r\n";
		}

		response += "Content-Length: " + bodyBytes.length + "\r\n";
		response += "\r\n";

		__origin.writeUTFBytes(response);

		if (!headOnly && bodyBytes.length > 0) {
			__origin.writeBytes(bodyBytes, 0, bodyBytes.length);
		}

		__origin.flush();
	}

	@:noCompletion private function __sendErrorResponse(statusCode:Int, message:String):Void {
		__dispatchResponse(statusCode, message, null, "text/plain", message);
		if (__origin.connected) {
			__origin.close();
		}
	}

	@:noCompletion private function __readLine(buffer:ByteArray):Null<String> {
		var startPos:UInt = buffer.position;
		var line:String = "";
		while (buffer.position < buffer.length) {
			var b:Int = buffer.readByte();
			line += String.fromCharCode(b);
			if (b == 10) {
				return line;
			}
		}
		buffer.position = startPos;
		return null;
	}

	@:noCompletion private function __getMimeType(filePath:String):String {
		final ext = filePath.split('.').pop().toLowerCase();
		var mimeType:String = switch (ext) {
			case "html", "htm": "text/html; charset=utf-8";
			case "css": "text/css; charset=utf-8";
			case "js", "mjs": "application/javascript; charset=utf-8";
			case "txt": "text/plain; charset=utf-8";
			case "json", "map": "application/json; charset=utf-8";
			case "csv": "text/csv; charset=utf-8";
			case "xml": "application/xml; charset=utf-8";
			case "webmanifest", "manifest": "application/manifest+json";
			case "svg": "image/svg+xml";

			case "png": "image/png";
			case "jpg", "jpeg": "image/jpeg";
			case "gif": "image/gif";
			case "webp": "image/webp";
			case "ico": "image/x-icon";

			case "woff2": "font/woff2";
			case "woff": "font/woff";
			case "ttf": "font/ttf";
			case "otf": "font/otf";

			case "wasm": "application/wasm";
			case "mp3": "audio/mpeg";
			case "wav": "audio/wav";
			case "mp4": "video/mp4";
			case "pdf": "application/pdf";

			default: "application/octet-stream";
		}
		return mimeType;
	}

	@:noCompletion private function __resolveSafePath(root:File, targetPath:String):File {
		if (targetPath == null || targetPath == "") {
			targetPath = "/";
		}

		if (targetPath.charAt(0) != "/") {
			targetPath = "/" + targetPath;
		}

		var resolved:File = root.resolvePath("." + targetPath);
		var rootPath = root.nativePath;
		var fullPath = resolved.nativePath;

		if (fullPath.length < rootPath.length || fullPath.substr(0, rootPath.length) != rootPath) {
			return null;
		}
		return resolved;
	}

	@:noCompletion private static inline function __formatHttpDate():String {
		var d:Date = Date.now();
		var utc = d.getTime() + d.getTimezoneOffset() * 60000; // adjust to UTC
		d = Date.fromTime(utc);

		var w:Array<String> = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
		var m:Array<String> = [
			"Jan", "Feb", "Mar", "Apr", "May", "Jun",
			"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
		];
		return w[d.getDay()] + ", " + StringTools.lpad(Std.string(d.getDate()), "0", 2) + " " + m[d.getMonth()] + " " + d.getFullYear() + " "
			+ StringTools.lpad(Std.string(d.getHours()), "0", 2) + ":" + StringTools.lpad(Std.string(d.getMinutes()), "0", 2) + ":"
			+ StringTools.lpad(Std.string(d.getSeconds()), "0", 2) + " GMT";
	}

	@:noCompletion private function __parseRange(h:String, total:UInt):{start:UInt, end:UInt} {
		if (h == null) {
			return null;
		}

		var m:EReg = ~/^bytes=(\d*)-(\d*)$/;
		if (!m.match(StringTools.trim(h))) {
			return null;
		}

		var sStr:String = m.matched(1), eStr = m.matched(2);
		var start:UInt;
		var end:UInt;

		if (sStr == "" && eStr == "") {
			return null;
		}

		if (sStr == "") {
			var n:Null<Int> = Std.parseInt(eStr);
			if (n == null || n <= 0) {
				return null;
			}

			start = (total > n) ? (total - n) : 0;
			end = total - 1;
		} else {
			start = Std.parseInt(sStr);
			end = (eStr == "") ? (total - 1) : Std.parseInt(eStr);
			if (start >= total) {
				return null;
			}

			if (end >= total) {
				end = total - 1;
			}

			if (end < start) {
				return null;
			}
		}
		return {start: start, end: end};
	}

	@:noCompletion private inline function __toHttpDate(t:Float):String {
		var d:Date = Date.fromTime(t);
		var w:Array<String> = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
		var m:Array<String> = [
			"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
		];
		return w[d.getDay()] + ", " + StringTools.lpad(Std.string(d.getDate()), "0", 2) + " " + m[d.getMonth()] + " " + d.getFullYear() + " "
			+ StringTools.lpad(Std.string(d.getHours()), "0", 2) + ":" + StringTools.lpad(Std.string(d.getMinutes()), "0", 2) + ":"
			+ StringTools.lpad(Std.string(d.getSeconds()), "0", 2) + " GMT";
	}

	@:noCompletion private inline function __isPhp(path:String):Bool {
		var dot:Int = path.lastIndexOf(".");
		return (dot >= 0) && (path.substr(dot + 1).toLowerCase() == "php");
	}

	@:noCompletion private function __servePhp(absPhpPath:String, headOnly:Bool, ?body:ByteArray):Void {
		final reqUri = (__queryString != "" ? (__extractPathOnly() + "?" + __queryString) : __extractPathOnly());

		var hostHeader:String = __headers.exists("host") ? __headers.get("host") : null;
		var sName:String = hostHeader;
		var sPort:String = null;
		if (hostHeader != null) {
			var i:Int = hostHeader.indexOf(":");
			if (i > 0) {
				sName = hostHeader.substr(0, i);
				var p:Null<Int> = Std.parseInt(hostHeader.substr(i + 1));
				if (p != null) {
					sPort = Std.string(p);
				}
			}
		}

		final phpReq:PHPRequest = {
			scriptFilename: absPhpPath,
			requestMethod: __method,
			requestUri: reqUri,
			scriptName: __extractPathOnly(),
			queryString: __queryString,
			contentType: __headers.exists("content-type") ? __headers.get("content-type") : null,
			remoteAddr: __origin.remoteAddress,
			serverName: sName,
			serverPort: sPort,
			extraHeaders: __forwardSubset(__headers),
			body: body
		};

		var phpRes:PHPResponse;
		try {
			phpRes = __php.execute(phpReq);
		} catch (e:Dynamic) {
			__dispatchResponse(502, "Bad Gateway", null, "text/plain", "Bad Gateway", true);
			if (__origin.connected) {
				__origin.close();
			}

			return;
		}

		var ctype:String = phpRes.headers.exists("content-type") ? phpRes.headers.get("content-type") : "text/html; charset=utf-8";

		var out:Array<URLRequestHeader> = [];
		if (phpRes.headers.exists("cache-control")) {
			out.push(new URLRequestHeader("Cache-Control", phpRes.headers.get("cache-control")));
		}
		if (phpRes.headers.exists("location")) {
			out.push(new URLRequestHeader("Location", phpRes.headers.get("location")));
		}
		if (phpRes.headers.exists("set-cookie")) {
			out.push(new URLRequestHeader("Set-Cookie", phpRes.headers.get("set-cookie"))); // TODO: multi-cookie support
		}

		var bodyBytes:ByteArray = phpRes.body;
		__dispatchResponseBytes(phpRes.status, __statusMessage(phpRes.status), out, ctype, bodyBytes, (__method == "HEAD" || headOnly));
		if (__origin.connected) {
			__origin.close();
		}
	}

	@:noCompletion private inline function __extractPathOnly():String {
		return __requestPath;
	}

	@:noCompletion private function __forwardSubset(h:Map<String, String>):Map<String, String> {
		var m:Map<String, String> = new Map();
		inline function put(k:String) {
			if (h.exists(k)) {
				final v = h.get(k);
				if (v != null)
					m.set(k, v);
			}
		}
		put("host");
		put("user-agent");
		put("accept");
		put("accept-language");
		put("accept-encoding");
		put("referer");
		put("cookie");
		put("authorization");
		return m;
	}

	@:noCompletion private inline function __statusMessage(code:Int):String {
		return switch (code) {
			case 200: "OK";
			case 201: "Created";
			case 204: "No Content";
			case 301: "Moved Permanently";
			case 302: "Found";
			case 304: "Not Modified";
			case 400: "Bad Request";
			case 401: "Unauthorized";
			case 403: "Forbidden";
			case 404: "Not Found";
			case 413: "Payload Too Large";
			case 416: "Range Not Satisfiable";
			case 500: "Internal Server Error";
			case 502: "Bad Gateway";
			case 501: "Not Implemented";
			case 504: "Gateway Timeout";
			case 505: "HTTP Version Not Supported";
			default: "OK";
		}
	}

	@:noCompletion private function __readBodyFromBuffer():Void {
		if (__bodyBuf == null || __expectBody <= 0) {
			__awaitingBody = false;
			return;
		}
		var avail:UInt = __incomingBuffer.length - __incomingBuffer.position;
		var need:UInt = __expectBody - __bodyBuf.length;
		var take:UInt = (avail < need) ? avail : need;
		if (take > 0) {
			__bodyBuf.writeBytes(__incomingBuffer, __incomingBuffer.position, take);
			__incomingBuffer.position += take;
		}
		__awaitingBody = (__bodyBuf.length < __expectBody);
	}

	@:noCompletion private function __finishPhpWithBody():Void {
		__servePhp(__bodyTargetPhpPath, __bodyHeadOnly, __bodyBuf);
		__bodyBuf = null;
		__expectBody = 0;
		__awaitingBody = false;
		__bodyTargetPhpPath = null;
		__bodyHeadOnly = false;
	}

	@:noCompletion private function __handlePost(filePath:String):Void {
		var file:File = new File(filePath);
		if (!file.exists) {
			__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
			if (__origin.connected) {
				__origin.close();
			}

			return;
		}

		if (file.isDirectory) {
			var indexFile:String = __findIndexFile(file);
			if (indexFile != null) {
				__handlePost(indexFile);
			} else {
				__dispatchResponse(404, "Not Found", null, "text/plain", "404 Not Found");
				if (__origin.connected) {
					__origin.close();
				}
			}
			return;
		}

		if (__php == null || !__isPhp(file.nativePath)) {
			__sendMethodNotAllowed();
			return;
		}

		var te:String = __headers.exists("transfer-encoding") ? __headers.get("transfer-encoding") : null;
		if (te != null && te.toLowerCase().indexOf("chunked") >= 0) {
			__dispatchResponse(501, "Not Implemented", null, "text/plain", "Chunked TE not supported yet");
			if (__origin.connected) {
				__origin.close();
			}

			return;
		}

		var cls:String = __headers.exists("content-length") ? __headers.get("content-length") : null;
		var n:Null<Int> = (cls != null) ? Std.parseInt(cls) : 0;
		if (n == null || n < 0) {
			n = 0;
		}

		if (n > MAX_BUFFER_SIZE) {
			__sendErrorResponse(413, "Payload Too Large");
			return;
		}

		__expectBody = n;
		__bodyBuf = new ByteArray();
		__bodyTargetPhpPath = file.nativePath;
		__bodyHeadOnly = false;
		__awaitingBody = true;

		__readBodyFromBuffer();
		if (!__awaitingBody) {
			__finishPhpWithBody();
		}
	}

	@:noCompletion private inline function __computeAllowOrigin():Null<String> {
		var origin:String = __headers.exists("origin") ? __headers.get("origin") : null;
		if (__config.corsAllowedOrigins.indexOf("*") != -1) {
			if (__config.corsAllowCredentials && origin != null) {
				return origin;
			}
			return "*";
		}
		if (origin != null && __config.corsAllowedOrigins.indexOf(origin) != -1) {
			return origin;
		}
		return null;
	}
}
