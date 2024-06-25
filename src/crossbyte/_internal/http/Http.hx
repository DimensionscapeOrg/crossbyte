package crossbyte._internal.http;

import crossbyte.Function;
import crossbyte._internal.http.headers.Connection;
import crossbyte._internal.socket.FlexSocket;
import crossbyte.url.URL;
import haxe.Timer;
import haxe.display.Protocol.HaxeNotificationMethod;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * ...
 * @author Christopher Speciale
 */
class Http {
	public static var MAX_REDIRECTS:Int = 10;
	private static inline var CRLF:String = "\r\n";
	private static inline var CRLFCRLF:String = "\r\n\r\n";

	public var onProgress:Function = () -> {};
	public var onError:Function = () -> {};
	public var onComplete:Function = () -> {};
	public var onStatus:Function = () -> {};

	private var __socket:FlexSocket;
	private var __url:URL;
	private var __headers:Array<String>;
	private var __urlVariables:Array<String>;
	private var __status:Int = 0;
	private var __data:Dynamic;
	private var __requestData:Dynamic;
	private var __timeout:Int;
	private var __port:UInt;
	private var __connected:Bool = false;
	private var __version:String;
	private var __method:String;
	private var __contentType:String;
	private var __userAgent:String;
	private var __responseHeaders:StringMap<String>;
	private var __buffer:Bytes;
	private var __followRedirects:Bool;
	private var __redirect:Bool = false;

	public function new(url:String, method:String = "GET", headers:Array<String> = null, requestData = null, contentType:Null<String> = null,
			data:Dynamic = null, version:HttpVersion = HttpVersion.HTTP_1_1, timeout:Int = 10000, userAgent:String = "XCrossByteHX",
			followRedirects:Bool = true) {
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
				__version = "1";
			case HTTP_1_1:
				__version = "1.1";
			case HTTP_2:
				__version = "2";
			case HTTP_3:
				__version = "3";
		}

		__buffer = Bytes.alloc(65536);
	}

	public function advance():Void {}

	public function loadAsync():Void {}

	public function load():Void {
		var redirects:Array<String> = [__url];
		__tryRequest();
		if (__followRedirects) {
			while (__connected
				&& (__status == 301 || __status == 302 || __status == 303 || __status == 307 && redirects.length < MAX_REDIRECTS)) {
				if (__responseHeaders.exists("location")) {
					var location:String = __responseHeaders.get("location");

					if (location.length > 0) {
						__redirect = true;

						var url:URL = new URL(location);

						if (redirects.indexOf(url) > -1) {
							__close();
							onError("Redirect loop detected");
							return;
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

			if (redirects.length == MAX_REDIRECTS) {
				__close();
				onError("Exceeded the number of allowed redirects");
			}
		}

		__parseResponse();
	}

	private function __parseResponse():Void {
		// trace("parse response");
		if (__connected) {
			var bytesTotal:Int = Std.parseInt(__responseHeaders.get('content-length'));

			var mode:Null<String> = "undefined";

			if (__status == 400) {
				mode = "bad";
			} else if (bytesTotal > 0) {
				mode = "fixed";
			}

			if (__responseHeaders.get("transfer-encoding") == "chunked") {
				mode = "chunked";
			}

			var bytesLoaded:UInt = 0;
			var data:Bytes = null;

			onProgress(bytesLoaded, bytesTotal);

			switch (mode) {
				case "bad":
					try {
						data = __socket.input.readAll();
					} catch (e) {
						__close();
						onError("Bad request");
					}

					bytesLoaded = data.length;
					onProgress(bytesLoaded, bytesTotal);
				case "fixed":
					data = Bytes.alloc(bytesTotal);

					var currentBytes:Int = 0;

					/*	while (__connected){
						try{
							var nBytes:Int =  __socket.input.readBytes(__buffer, currentBytes, 4096);
						}

					}*/
					try {
						data = __socket.input.readAll(bytesTotal);
						bytesLoaded = bytesTotal;
						onProgress(bytesLoaded, bytesTotal);
					} catch (e) {
						__close();
						onError("Download failed");
					}
				case "chunked":
					var bytes:Bytes;
					var bytesBuffer:BytesBuffer = new BytesBuffer();
					var chunkSize:Int;

					try {
						while (__connected) {
							var value:String = __socket.input.readLine();
							chunkSize = Std.parseInt('0x${value}');

							if (chunkSize == 0) {
								break;
							}

							bytes = __socket.input.read(chunkSize);
							bytesLoaded += chunkSize;
							bytesBuffer.add(bytes);
							__socket.input.read(2);

							onProgress(bytesLoaded, bytesTotal);
						}
					} catch (e) {
						__close();
						onError("Download Failed");
						bytesBuffer = null;
					}

					data = bytesBuffer.getBytes();
					onComplete(data);

					bytes = null;
					bytesBuffer = null;

				case "undefined":
					__close();
					onError("Download Failed, no content");
			}
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
		if (__connected) {
			var line:String = '';
			while (true) {
				try {
					line = StringTools.trim(__socket.input.readLine());
					#if http_debug
					trace(line);
					#end
				} catch (e:Dynamic) {
					__close();
				}

				if (line == '')
					break; // end of response headers

				if (__status == 0) {
					var regex = ~/^HTTP\/\d+\.\d+ (\d+)/;
					regex.match(line);
					__status = Std.parseInt(regex.matched(1));
					onStatus(__status);
				} else {
					var keyValue:Array<String> = line.split(":");
					__responseHeaders.set(keyValue.shift().toLowerCase(), StringTools.trim(keyValue.join(":")));
				}
			}
		}
	}

	private function urlVariablesToQueryString(vars:Dynamic):String {
		var fields:Array<String> = Reflect.fields(vars);

		var params:StringMap<String> = new StringMap();

		for (field in fields) {
			params.set(field, Reflect.field(vars, field));
		}
		var output:String = "";

		for (key in params.keys()) {
			var value = params.get(key);
			if (output.length > 0)
				output += "&";
			output += key + "=" + StringTools.urlEncode(value);
		}

		return output;
	}

	private function __handleRequest():Void {
		try {
			// TODO: Write URLVariables to query if GET method
			var hasURLVariables:Bool = false;
			if (__method == "GET" && __requestData != null) {
				if (Reflect.isObject(__requestData)) {
					hasURLVariables = true;
				}
			}
			var queryString:String = __url.query;

			if (!__redirect && hasURLVariables) {
				queryString += urlVariablesToQueryString(__requestData);
			}

			if (queryString.length > 0 && queryString.charAt(0) != "?") {
				queryString = '?${queryString}';
			}

			__socket.output.writeString('${__method} ${__url.path}${queryString} HTTP/${__version}${CRLF}');
			#if http_debug
			trace('${__method} ${__url.path}${queryString} HTTP/${__version}${CRLF}');
			#end
			__socket.output.writeString('User-Agent:${__userAgent}${CRLF}');
			#if http_debug
			trace('User-Agent:${__userAgent}${CRLF}');
			#end
			__socket.output.writeString('Host:${__url.host}${CRLF}');
			#if http_debug
			trace('Host:${__url.host}${CRLF}');
			#end
			if (__version == HttpVersion.HTTP_1_1) {
				__socket.output.writeString('Connection: ${Connection.CLOSE}${CRLF}');
			}

			__writeHeaders();
			__writeContent();

			__socket.output.writeString(CRLF);
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

		__status = 0;
	}

	private function __writeHeaders():Void {
		if (__headers != null) {
			for (header in __headers) {
				__socket.output.writeString('${header}${CRLF}');
			}
		}
	}

	private function __writeContent():Void {
		if (__contentType != null) {
			__socket.output.writeString('Content-Type:${__contentType}${CRLF}');
			var dataType:String = __getDataType();
			__socket.output.writeString('Content-Length:${__data.length}${CRLFCRLF}');

			switch (__getDataType()) {
				case "text":
					__socket.output.writeString(__data);
				case "binary":
					__socket.output.writeBytes(__data, 0, __data.length);
			}
		}
	}

	private function __getDataType():String {
		if (Std.isOfType(__data, String)) {
			return "text";
		} else if (Std.isOfType(__data, Bytes)) {
			return "binary";
		} else {
			throw "Data Type not recognized";
		}

		return "";
	}
}
