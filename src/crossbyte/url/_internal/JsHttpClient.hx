package crossbyte.url._internal;

import crossbyte.url.URLRequest;
import haxe.io.Bytes;

/**
 * The HTTP client behind `URLLoader` on the JavaScript targets.
 *
 * Neither target can use the socket-and-TLS client the native targets run.
 * A page is not allowed a raw socket at all, and Node has one but no
 * `sys.ssl` to put over it, so `https` would be out of reach. Both do have a
 * first-class HTTP client of their own, and using it means redirects, proxies,
 * certificate verification, compression and connection reuse are the runtime's
 * problem rather than something reimplemented here.
 *
 * Both are asynchronous already, which is why there is no worker in sight:
 * `URLLoader` spawns one on the native targets so a blocking request does not
 * stall the runtime, and a blocking request is not a thing that exists here.
 *
 * The callbacks are deliberately narrow -- status, progress, completion,
 * failure -- so the two implementations below cannot drift in what they report
 * even though almost nothing about how they work is shared.
 */
class JsHttpClient {
	/**
	 * Issues `request`, reporting through the callbacks. Exactly one of
	 * `onComplete` or `onError` is called, once.
	 */
	public static function send(request:URLRequest, onStatus:Int->Void, onProgress:Int->Int->Void, onComplete:Bytes->Void, onError:String->Void):Void {
		if (request == null || request.url == null || request.url == "") {
			onError("URLRequest has no url.");
			return;
		}

		var method:String = (request.method != null && request.method != "") ? request.method : "GET";

		#if (js && !nodejs)
		__sendBrowser(request, method, onStatus, onProgress, onComplete, onError);
		#elseif nodejs
		__sendNode(request, method, onStatus, onProgress, onComplete, onError);
		#end
	}

	#if (js && !nodejs)
	/**
	 * XMLHttpRequest rather than fetch, because `URLLoader` reports progress
	 * and fetch only offers that by reading the body as a stream and counting
	 * chunks by hand. XHR reports it directly, and `arraybuffer` gives the body
	 * as bytes so a binary response survives.
	 */
	static function __sendBrowser(request:URLRequest, method:String, onStatus:Int->Void, onProgress:Int->Int->Void, onComplete:Bytes->Void,
			onError:String->Void):Void {
		var xhr = new js.html.XMLHttpRequest();
		var settled:Bool = false;

		xhr.open(method, request.url, true);
		xhr.responseType = ARRAYBUFFER;

		if (request.requestHeaders != null) {
			for (header in request.requestHeaders) {
				if (header != null && header.name != null) {
					xhr.setRequestHeader(header.name, header.value);
				}
			}
		}

		if (request.contentType != null && request.contentType != "") {
			xhr.setRequestHeader("Content-Type", request.contentType);
		}

		if (request.idleTimeout > 0) {
			xhr.timeout = request.idleTimeout;
		}

		xhr.onreadystatechange = function() {
			// Headers are in as of HEADERS_RECEIVED, which is where the status
			// is worth reporting -- waiting for the body would hold it back
			// behind however long the transfer takes.
			if (xhr.readyState == 2) {
				onStatus(xhr.status);
			}
		};

		xhr.onprogress = function(e) {
			onProgress(Std.int(e.loaded), e.lengthComputable ? Std.int(e.total) : 0);
		};

		xhr.onload = function(_) {
			if (settled) {
				return;
			}
			settled = true;

			var buffer:js.lib.ArrayBuffer = xhr.response;
			onComplete(buffer == null ? Bytes.alloc(0) : Bytes.ofData(buffer));
		};

		xhr.onerror = function(_) {
			if (settled) {
				return;
			}
			settled = true;
			// The browser deliberately withholds the reason -- a DNS failure,
			// a refused connection and a blocked cross-origin request are one
			// event with no detail, so there is nothing more specific to pass on.
			onError("HTTP request failed: " + request.url);
		};

		xhr.ontimeout = function(_) {
			if (settled) {
				return;
			}
			settled = true;
			onError("HTTP request timed out: " + request.url);
		};

		xhr.send(__body(request));
	}

	static function __body(request:URLRequest):Dynamic {
		if (request.data == null) {
			return null;
		}

		if ((request.data is String)) {
			return request.data;
		}

		if ((request.data is Bytes)) {
			return new js.lib.Uint8Array((request.data : Bytes).getData());
		}

		return Std.string(request.data);
	}
	#end

	#if nodejs
	/**
	 * Node's own http/https client. The module is chosen by scheme, since the
	 * two are separate here rather than one client that reads the URL.
	 */
	static function __sendNode(request:URLRequest, method:String, onStatus:Int->Void, onProgress:Int->Int->Void, onComplete:Bytes->Void,
			onError:String->Void):Void {
		var settled:Bool = false;

		var fail = function(message:String):Void {
			if (!settled) {
				settled = true;
				onError(message);
			}
		};

		var url:js.node.url.URL;

		try {
			url = new js.node.url.URL(request.url);
		} catch (e:Dynamic) {
			fail("Malformed url: " + request.url);
			return;
		}

		var secure:Bool = url.protocol == "https:";
		var headers:haxe.DynamicAccess<String> = {};

		if (request.requestHeaders != null) {
			for (header in request.requestHeaders) {
				if (header != null && header.name != null) {
					headers.set(header.name, header.value);
				}
			}
		}

		if (request.contentType != null && request.contentType != "") {
			headers.set("Content-Type", request.contentType);
		}

		if (request.userAgent != null && request.userAgent != "") {
			headers.set("User-Agent", request.userAgent);
		}

		var options:Dynamic = {
			protocol: url.protocol,
			hostname: url.hostname,
			port: url.port == "" ? null : Std.parseInt(url.port),
			path: url.pathname + url.search,
			method: method,
			headers: headers
		};

		var handler = function(response:js.node.http.IncomingMessage):Void {
			onStatus(response.statusCode);

			var lengthHeader = response.headers.get("content-length");
			var total:Int = 0;

			if (lengthHeader != null) {
				var parsed = Std.parseInt(Std.string(lengthHeader));
				total = parsed == null ? 0 : parsed;
			}

			var chunks:Array<js.node.Buffer> = [];
			var loaded:Int = 0;

			response.on("data", function(chunk:js.node.Buffer) {
				chunks.push(chunk);
				loaded += chunk.length;
				onProgress(loaded, total);
			});

			response.on("end", function() {
				if (settled) {
					return;
				}
				settled = true;

				var joined = js.node.Buffer.concat(chunks);
				// Sliced by its own region: a Buffer can be a window onto a
				// larger pooled allocation, and taking .buffer whole would
				// carry bytes belonging to something else.
				onComplete(Bytes.ofData(joined.buffer.slice(joined.byteOffset, joined.byteOffset + joined.byteLength)));
			});

			response.on("error", function(e) {
				fail("HTTP response failed: " + Std.string(e));
			});
		};

		var clientRequest = secure ? js.node.Https.request(options, handler) : js.node.Http.request(options, handler);

		clientRequest.on("error", function(e) {
			fail("HTTP request failed: " + Std.string(e));
		});

		if (request.idleTimeout > 0) {
			clientRequest.setTimeout(request.idleTimeout, function(_) {
				clientRequest.destroy();
				fail("HTTP request timed out: " + request.url);
			});
		}

		if (request.data != null) {
			if ((request.data is Bytes)) {
				clientRequest.write(js.node.Buffer.from((request.data : Bytes).getData()));
			} else {
				clientRequest.write(Std.string(request.data));
			}
		}

		clientRequest.end();
	}
	#end
}
