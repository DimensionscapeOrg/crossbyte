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
import crossbyte._internal.http.Http;

final class HTTPRequestHandler extends EventDispatcher {
	@:noCompletion private static inline var MAX_BUFFER_SIZE:Int = 1024 * 1024; // 1 MB
	@:noCompletion private static final ALLOWED_METHODS:Array<String> = ["GET", "HEAD", "OPTIONS"];

	@:noCompletion private var __origin:Socket;
	@:noCompletion private var __incomingBuffer:ByteArray;
	@:noCompletion private var __config:HTTPServerConfig;
	@:noCompletion private var __headers:Map<String, String>;
	@:noCompletion private var __method:String;
	@:noCompletion private var __filePath:String;
	@:noCompletion private var __httpVersion:String;

	public function new(socket:Socket, config:HTTPServerConfig) {
		super();
		__origin = socket;
		__config = config;
		__incomingBuffer = new ByteArray();
		__headers = new Map<String, String>();
		__setup();
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

		var supportsHttpVersion:Bool = Http.validateHttpVersion(__httpVersion);
		if (!supportsHttpVersion) {
			__sendErrorResponse(505, "HTTP Version Not Supported");
			return;
		}

		var pathOnly:String = rawTarget;
		var q:Int = pathOnly.indexOf("?");
		if (q >= 0) {
			pathOnly = pathOnly.substr(0, q);
		}
		var h:Int = pathOnly.indexOf("#");
		if (h >= 0)
			pathOnly = pathOnly.substr(0, h);

		try {
			pathOnly = StringTools.urlDecode(pathOnly);
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

			default:
				__sendMethodNotAllowed();
		}
	}

	@:noCompletion private function __handleOptionsRequest():Void {
		var response = "HTTP/1.1 204 No Content\r\n";
		response += "Access-Control-Allow-Origin: " + __config.corsAllowedOrigins.join(", ") + "\r\n";
		response += "Access-Control-Allow-Methods: " + __config.corsAllowedMethods.join(", ") + "\r\n";
		response += "Access-Control-Allow-Headers: " + __config.corsAllowedHeaders.join(", ") + "\r\n";
		response += "Allow: " + ALLOWED_METHODS.join(", ") + "\r\n";
		response += "Vary: Origin\r\n";
		if (__config.corsMaxAge > 0){
			response += "Access-Control-Max-Age: " + __config.corsMaxAge + "\r\n";
		}
			
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

		if (!headOnly && __origin.connected) {
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
			response += "Access-Control-Allow-Origin: " + __config.corsAllowedOrigins.join(", ") + "\r\n";
			response += "Vary: Origin\r\n";
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
			response += "Access-Control-Allow-Origin: " + __config.corsAllowedOrigins.join(", ") + "\r\n";
			response += "Vary: Origin\r\n";
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
		// rewind if we need to
		buffer.position = startPos;
		return null;
	}

	@:noCompletion private function __getMimeType(filePath:String):String {
		var extension:String = filePath.split('.').pop().toLowerCase();
		return switch (extension) {
			case "html", "htm": "text/html";
			case "css": "text/css";
			case "js": "application/javascript";
			case "png": "image/png";
			case "jpg", "jpeg": "image/jpeg";
			case "gif": "image/gif";
			case "txt": "text/plain";
			default: "application/octet-stream";
		}
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
}
