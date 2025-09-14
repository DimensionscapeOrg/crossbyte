package crossbyte._internal.http;

import haxe.exceptions.NotImplementedException;
import crossbyte.Function;
import crossbyte._internal.http.headers.Connection;
import crossbyte._internal.socket.FlexSocket;
import crossbyte.url.URL;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * ...
 * @author Christopher Speciale
 */
class Http {
	public static var MAX_REDIRECTS:Int = 10;
	private static inline final CRLF:String = "\r\n";
	private static inline final CRLFCRLF:String = "\r\n\r\n";
	private static inline final HEADER_LOCATION = "location";
	private static inline final HEADER_CONTENT_LENGTH = "content-length";
	private static inline final HEADER_TRANSFER_ENCODING = "transfer-encoding";
	private static final SUPPORTED_VERSIONS:Array<HttpVersion> = [HttpVersion.HTTP_1, HttpVersion.HTTP_1_1];

	public var onProgress:Function = () -> {};
	public var onError:Function = () -> {};
	public var onComplete:Function = () -> {};
	public var onStatus:Function = () -> {};

	private var __socket:FlexSocket;
	private var __url:URL;
	private var __headers:Array<String>;
	private var __status:Int = 0;
	private var __data:Dynamic;
	private var __requestData:Dynamic;
	private var __timeout:Int;
	private var __connected:Bool = false;
	private var __version:String;
	private var __method:String;
	private var __contentType:String;
	private var __userAgent:String;
	private var __responseHeaders:StringMap<String>;
	private var __followRedirects:Bool;
	private var __redirect:Bool = false;

	public function new(url:String, method:String = "GET", headers:Array<String> = null, requestData = null, contentType:Null<String> = null,
			data:Dynamic = null, version:HttpVersion = HttpVersion.HTTP_1_1, timeout:Int = 10000, userAgent:String = "CrossByte", followRedirects:Bool = true) {
		__url = new URL(url);
		__headers = headers;
		__requestData = requestData;
		__timeout = timeout;
		__method = method;
		__contentType = contentType;
		__data = data;
		__userAgent = userAgent;
		__followRedirects = followRedirects;

		switch (version) {
			case HTTP_1:
				__version = HttpVersion.HTTP_1;
			case HTTP_1_1:
				__version = HttpVersion.HTTP_1_1;
			case HTTP_2:
				throw new NotImplementedException("HTTP/2 not supported yet");
			case HTTP_3:
				throw new NotImplementedException("HTTP/3 not supported yet");
		}
	}

	public function advance():Void {}

	public function loadAsync():Void {}

	public function load():Void {
		__redirect = false;
		var redirects:Array<String> = [__url];

		__tryRequest();

		if (__followRedirects) {
			while (__connected
				&& (__status == 301 || __status == 302 || __status == 303 || __status == 307 || __status == 308)
				&& (redirects.length - 1) < MAX_REDIRECTS) {
				if (__responseHeaders.exists(HEADER_LOCATION)) {
					var location:String = __responseHeaders.get(HEADER_LOCATION);

					if (location.length > 0) {
						__redirect = true;

						var url:URL = new URL(__resolveLocation(__url, location));

						if (redirects.indexOf(url) > -1) {
							__close();
							onError("Redirect loop detected");
							return;
						}

						if (__status == 301 || __status == 302 || __status == 303) {
							__method = "GET";
							__data = null;
							__contentType = null;
							__requestData = null;
						}

						__url = url;
					} else {
						__close();
						onError("Could not complete redirect");
						return;
					}
				} else {
					__close();
					onError("Could not complete redirect");
					return;
				}

				redirects.push(__url);
				__close();
				__tryRequest();
			}

			if ((redirects.length - 1) == MAX_REDIRECTS) {
				__close();
				onError("Exceeded the number of allowed redirects");
			}
		}

		__parseResponse();
	}

	public static function validateHttpVersion(version:HttpVersion):Bool {
		return SUPPORTED_VERSIONS.indexOf(version) > -1;
	}

	private function __parseResponse():Void {
		if (!__connected) {
			__close();
			return;
		}

		var contentLengthHeader:String = __responseHeaders.get(HEADER_CONTENT_LENGTH);
		var contentLength:Null<Int> = (contentLengthHeader != null) ? Std.parseInt(contentLengthHeader) : null;

		var transferEncodingHeader:String = __responseHeaders.get(HEADER_TRANSFER_ENCODING);
		var isChunked:Bool = false;
		if (transferEncodingHeader != null) {
			var encodings:Array<String> = transferEncodingHeader.toLowerCase().split(",");
			for (i in 0...encodings.length) {
				if (StringTools.trim(encodings[i]) == "chunked") {
					isChunked = true;
					break;
				}
			}
		}

		var bytesTotalForProgress:Int = (contentLength != null) ? contentLength : -1;

		var isNoContentStatus:Bool = (__status == 204 || __status == 304);

		var isHttpError:Bool = (__status >= 400);
		var isHead:Bool = (__method == "HEAD");
		var mode:String = "undefined";

		if (isHead) {
			mode = "nocontent";
		} else if (isNoContentStatus) {
			mode = "nocontent";
		} else if (isChunked) {
			mode = "chunked";
		} else if (contentLength != null && contentLength >= 0) {
			mode = "fixed";
		} else {
			mode = "unknown";
		}

		var bytesLoaded:UInt = 0;
		var data:Bytes = null;

		onProgress(bytesLoaded, bytesTotalForProgress);

		try {
			switch (mode) {
				case "nocontent":
					data = Bytes.alloc(0);

				case "fixed":
					var total:Int = contentLength;
					data = Bytes.alloc(total);
					var offset:Int = 0;

					while (offset < total) {
						var n:Int = __socket.input.readBytes(data, offset, total - offset);
						if (n <= 0) {
							break;
						}

						offset += n;
						bytesLoaded = offset;
						onProgress(bytesLoaded, bytesTotalForProgress);
					}

					if (offset != total) {
						__close();
						onError("Download failed: expected " + total + " bytes, got " + offset);
						return;
					}

				case "chunked":
					var buffer:BytesBuffer = new BytesBuffer();
					while (true) {
						var sizeLine:String = __socket.input.readLine();
						if (sizeLine == null) {
							throw "Unexpected EOF while reading chunk size";
						}

						var semi:Int = sizeLine.indexOf(";");
						if (semi >= 0) {
							sizeLine = sizeLine.substr(0, semi);
						}

						var hexStr:String = StringTools.trim(sizeLine);
						var parsed:Null<Int> = Std.parseInt('0x' + hexStr);
						if (parsed == null || parsed < 0) {
							throw "Invalid chunk size: " + hexStr;
						}

						var chunkSize:Int = parsed;

						if (chunkSize == 0) {
							var trailer:String = "";
							do {
								trailer = __socket.input.readLine();
								if (trailer == null) {
									throw "Unexpected EOF while reading trailers";
								}

								trailer = StringTools.trim(trailer);
							} while (trailer.length > 0);
							break;
						}

						var chunk:Bytes = __socket.input.read(chunkSize);
						if (chunk == null || chunk.length != chunkSize)
							throw "Truncated chunk";
						buffer.add(chunk);

						bytesLoaded += chunkSize;
						onProgress(bytesLoaded, bytesTotalForProgress);

						__socket.input.read(2);
					}
					data = buffer.getBytes();

				case "unknown":
					var buffer:BytesBuffer = new BytesBuffer();
					var b:Bytes = Bytes.alloc(64 * 1024);
					while (true) {
						var n:Int;
						try {
							n = __socket.input.readBytes(b, 0, b.length);
						} catch (e:Dynamic) {
							n = 0;
						}
						if (n <= 0)
							break;
						buffer.addBytes(b, 0, n);
						bytesLoaded += n;
						onProgress(bytesLoaded, bytesTotalForProgress);
					}
					data = buffer.getBytes();

				default:
					__close();
					onError("Download failed: unsupported response mode");
					return;
			}
		} catch (e:Dynamic) {
			__close();
			onError("Download failed");
			return;
		}

		if (isHttpError) {
			var status:Int = __status;
			__close();
			onError('HTTP error ' + status);
			return;
		}

		if (data != null) {
			onComplete(data);
		}

		__close();
	}

	private function __tryRequest():Void {
		__responseHeaders = new StringMap();

		try {
			__socket = new FlexSocket(__url.ssl);
			__socket.setTimeout(__timeout);
			__socket.connect(__url.host, __url.port);
			__connected = true;
		} catch (e:Dynamic) {
			__close();
			onError("Connection Failed");
			return;
		}

		if (__connected) {
			__handleRequest();
		}

		__handleResponse();
	}

	private function __handleResponse():Void {
		if (!__connected) {
			return;
		}

		var line:String = '';
		while (true) {
			try {
				line = __socket.input.readLine();
			} catch (e:Dynamic) {
				__close();
				onError("Failed to read response");
				return;
			}

			if (line == null) {
				__close();
				onError("Connection closed while reading headers");
				return;
			}

			line = StringTools.trim(line);
			#if http_debug
			trace(line);
			#end

			if (line == '') {
				if (__status >= 100 && __status < 200) {
					__status = 0;
					__responseHeaders = new StringMap();
					continue;
				}
				break;
			}

			if (__status == 0) {
				var regex:EReg = ~/^HTTP\/\d+\.\d+\s+(\d+)/;
				if (!regex.match(line)) {
					__close();
					onError('Malformed status line: ' + line);
					return;
				}
				__status = Std.parseInt(regex.matched(1));
				onStatus(__status);
			} else {
				var i:Int = line.indexOf(":");
				if (i <= 0) {
					continue;
				}

				var key:String = line.substr(0, i).toLowerCase();
				var value:String = StringTools.trim(line.substr(i + 1));

				if (__responseHeaders.exists(key)) {
					if (key == "set-cookie") {
						var prev = __responseHeaders.get(key);
						__responseHeaders.set(key, prev + "\n" + value);
					} else {
						__responseHeaders.set(key, __responseHeaders.get(key) + ", " + value);
					}
				} else {
					__responseHeaders.set(key, value);
				}
			}
		}
	}

	private function __handleRequest():Void {
		try {
			var isGetLike:Bool = (__method == "GET" || __method == "HEAD");

			var baseQuery:String = __url.query;
			var extraQuery:String = "";
			if (!__redirect && isGetLike && __requestData != null && Reflect.isObject(__requestData)) {
				extraQuery = __buildQuery(__requestData);
			}
			var combined:String = (baseQuery.length > 0 && extraQuery.length > 0) ? (baseQuery + "&" + extraQuery) : (baseQuery + extraQuery);
			var queryString:String = (combined.length > 0) ? ("?" + combined) : "";

			var path:String = (__url.path != null && __url.path.length > 0) ? __url.path : "/";
			__socket.output.writeString('${__method} ${path}${queryString} $__version${CRLF}');
			__socket.output.writeString('User-Agent: ${__userAgent}${CRLF}');
			var hostHeader:String = (__url.port != 80 && __url.port != 443) ? '${__url.host}:${__url.port}' : __url.host;
			__socket.output.writeString('Host: ${hostHeader}${CRLF}');
			if (__version == HttpVersion.HTTP_1_1 || __version == HttpVersion.HTTP_1) {
				__socket.output.writeString('Connection: ${Connection.CLOSE}${CRLF}');
			}

			var sentAcceptEncoding:Bool = false;
			if (__headers != null) {
				for (h in __headers) {
					if (StringTools.startsWith(h.toLowerCase(), "accept-encoding:")) {
						sentAcceptEncoding = true;
						break;
					}
				}
			}
			if (!sentAcceptEncoding) {
				__socket.output.writeString('Accept-Encoding: ' + crossbyte._internal.http.headers.AcceptEncoding.IDENTITY + CRLF);
			}

			__writeHeaders();

			var hasContentType:Bool = false;
			var hasContentLength:Bool = false;
			if (__headers != null) {
				for (header in __headers) {
					var hl:String = header.toLowerCase();
					if (StringTools.startsWith(hl, "content-type:"))
						hasContentType = true;
					if (StringTools.startsWith(hl, "content-length:"))
						hasContentLength = true;
				}
			}

			var body:Bytes = null;
			var isHead:Bool = (__method == "HEAD");

			if (!isHead) {
				if (__data != null) {
					if (Std.isOfType(__data, String)) {
						if (__contentType == null) {
							__contentType = "text/plain; charset=utf-8";
						}

						body = haxe.io.Bytes.ofString((__data : String));
					} else if (Std.isOfType(__data, haxe.io.Bytes)) {
						body = (__data : haxe.io.Bytes);
					} else {
						throw "Data Type not recognized";
					}
				} else if (!isGetLike && __requestData != null && Reflect.isObject(__requestData)) {
					var form:String = __buildQuery(__requestData);
					body = haxe.io.Bytes.ofString(form);
					if (__contentType == null) {
						__contentType = "application/x-www-form-urlencoded; charset=utf-8";
					}
				}
			}

			if (body != null) {
				if (!hasContentType) {
					__socket.output.writeString('Content-Type: ${__contentType}${CRLF}');
				}
				if (!hasContentLength) {
					__socket.output.writeString('$HEADER_CONTENT_LENGTH: ${body.length}${CRLF}');
				}
			}

			__socket.output.writeString(CRLF);

			if (body != null) {
				__socket.output.writeBytes(body, 0, body.length);
			}

			__socket.output.flush();
		} catch (e:Dynamic) {
			__close();
			onError("URL Request failed");
		}
	}

	private function __close():Void {
		if (__socket != null) {
			__socket.close();
			__connected = false;
			__socket = null;
		}

		// should we reset the status?
		//__status = 0;
	}

	private function __writeHeaders():Void {
		if (__headers != null) {
			for (header in __headers) {
				__socket.output.writeString('${header}${CRLF}');
			}
		}
	}

	private inline function __encodeKV(k:String, v:String):String {
		return StringTools.urlEncode(k) + "=" + StringTools.urlEncode(v);
	}

	private function __buildQuery(obj:Dynamic):String {
		var parts:Array<String> = [];

		var fields = Reflect.fields(obj);
		for (f in fields) {
			buildQueryAdd(parts, f, Reflect.field(obj, f));
		}

		return parts.join("&");
	}

	private inline function buildQueryAdd(parts:Array<String>, k:String, v:Dynamic):Void {
		if (v == null) {
			return;
		}

		switch (Type.typeof(v)) {
			case TBool:
				parts.push(__encodeKV(k, (v : Bool) ? "true" : "false"));
			case TInt, TFloat:
				parts.push(__encodeKV(k, Std.string(v)));
			case TClass(String):
				parts.push(__encodeKV(k, (v : String)));
			case TClass(Array):
				var arr = (v : Array<Dynamic>);
				for (i in 0...arr.length) {
					buildQueryAdd(parts, k + "[]", arr[i]);
				}

			case TObject:
				var fields = Reflect.fields(v);
				for (f in fields) {
					buildQueryAdd(parts, k + "[" + f + "]", Reflect.field(v, f));
				}

			default:
				parts.push(__encodeKV(k, Std.string(v)));
		}
	}

	@:noCompletion private function __resolveLocation(base:URL, loc:String):String {
		var locRegex:EReg = ~/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//;
		if (locRegex.match(loc)) {
			return loc;
		}

		var scheme:String = base.scheme;
		var host:String = base.host;
		var port:Int = base.port;
		var portPart:String = (port != 80 && port != 443) ? (":" + port) : "";

		if (loc.charAt(0) == "/") {
			return scheme + "://" + host + portPart + loc;
		}

		var basePath:String = (base.path != null && base.path.length > 0) ? base.path : "/";
		var slash:Int = basePath.lastIndexOf("/");
		var dir:String = (slash >= 0) ? basePath.substr(0, slash + 1) : "/";
		var joined:String = dir + loc;

		return scheme + "://" + host + portPart + joined;
	}
}
