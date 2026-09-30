package crossbyte.url._internal;

import crossbyte.url.URLRequest;
import crossbyte.url.URLRequestHeader;
import crossbyte.url.URLVariables;
import haxe.io.Bytes;

/**
 * The HTTP client behind `URLLoader` on the JavaScript targets.
 *
 * Neither target can use the socket-and-TLS client the native targets run.
 * A page is not allowed a raw socket at all, and Node has one but no
 * `sys.ssl` to put over it, so `https` would be out of reach. Both do have a
 * first-class HTTP client of their own, and using it means proxies,
 * certificate verification, compression and connection reuse are the runtime's
 * problem rather than something reimplemented here.
 *
 * Both are asynchronous already, which is why there is no worker in sight:
 * `URLLoader` spawns one on the native targets so a blocking request does not
 * stall the runtime, and a blocking request is not a thing that exists here.
 *
 * The callbacks are deliberately narrow, status, the final response's
 * headers, progress, completion, failure, so the two implementations below
 * cannot drift in what they report even though almost nothing about how they
 * work is shared. Where the platform leaves a choice, they make the one the
 * native client makes: redirects are followed, dropping credentials when one
 * leaves the origin, and `idleTimeout` is time without progress rather than a
 * deadline on the whole exchange.
 */
class JsHttpClient {
	/** Redirects followed before giving up, as `Http.MAX_REDIRECTS` on native. */
	private static inline var MAX_REDIRECTS:Int = 10;

	/**
	 * Issues `request`, reporting through the callbacks. Exactly one of
	 * `onComplete` or `onError` is called, once. `onResponse` is called once,
	 * before either, when a final response has arrived: its status, headers,
	 * the URL it came from, and whether a redirect led there.
	 */
	public static function send(request:URLRequest, onStatus:Int->Void, onProgress:Int->Int->Void, onComplete:Bytes->Void, onError:String->Void,
			?onResponse:(status:Int, headers:Array<URLRequestHeader>, url:String, redirected:Bool) -> Void):Void {
		if (request == null || request.url == null || request.url == "") {
			onError("URLRequest has no url.");
			return;
		}

		if (onResponse == null) {
			onResponse = (_, _, _, _) -> {};
		}

		var method:String = (request.method != null && request.method != "") ? request.method : "GET";

		// A URLVariables goes where a form puts it: into the query of a GET or
		// HEAD, and otherwise into the body, form-encoded. Sent as it stood,
		// it was a debug dump of the map it is at run time.
		var url:String = request.url;
		var body:Dynamic = request.data;
		var contentType:String = request.contentType;
		var form:Null<String> = URLVariables.encodeData(request.data);
		if (form != null) {
			if (method == "GET" || method == "HEAD") {
				if (form.length > 0) {
					url += (url.indexOf("?") >= 0 ? "&" : "?") + form;
				}
				body = null;
			} else {
				body = form;
				if (contentType == null || contentType == "") {
					contentType = "application/x-www-form-urlencoded";
				}
			}
		}

		#if (js && !nodejs)
		__sendBrowser(request, method, url, body, contentType, onStatus, onProgress, onComplete, onError, onResponse);
		#elseif nodejs
		__sendNode(request, method, url, body, contentType, onStatus, onProgress, onComplete, onError, onResponse);
		#end
	}

	#if (js && !nodejs)
	/**
	 * XMLHttpRequest rather than fetch, because `URLLoader` reports progress
	 * and fetch only offers that by reading the body as a stream and counting
	 * chunks by hand. XHR reports it directly, and `arraybuffer` gives the body
	 * as bytes so a binary response survives.
	 *
	 * The browser follows redirects itself and applies its own rules to them,
	 * which are the rules the other clients copy.
	 */
	static function __sendBrowser(request:URLRequest, method:String, url:String, body:Dynamic, contentType:String, onStatus:Int->Void,
			onProgress:Int->Int->Void, onComplete:Bytes->Void, onError:String->Void,
			onResponse:(Int, Array<URLRequestHeader>, String, Bool) -> Void):Void {
		var xhr = new js.html.XMLHttpRequest();
		var settled:Bool = false;
		var idle:haxe.Timer = null;

		function stopIdle():Void {
			if (idle != null) {
				idle.stop();
				idle = null;
			}
		}

		// Time without progress, not a deadline on the whole exchange: this
		// was xhr.timeout, which ended a large download that was still moving
		// where every other client would have let it finish.
		function armIdle():Void {
			stopIdle();
			if (request.idleTimeout > 0 && !settled) {
				idle = haxe.Timer.delay(function():Void {
					if (settled) {
						return;
					}
					settled = true;
					xhr.abort();
					onError("HTTP request timed out: " + url);
				}, request.idleTimeout);
			}
		}

		// The browser refuses a method that is not a token, and a header name
		// or value it will not send, by throwing, out of URLLoader.load()
		// rather than as the IO_ERROR every other failure is.
		try {
			xhr.open(method, url, true);
			xhr.responseType = ARRAYBUFFER;

			if (request.requestHeaders != null) {
				for (header in request.requestHeaders) {
					if (header != null && header.name != null) {
						xhr.setRequestHeader(header.name, header.value);
					}
				}
			}

			if (contentType != null && contentType != "") {
				xhr.setRequestHeader("Content-Type", contentType);
			}
		} catch (e:Dynamic) {
			settled = true;
			onError("HTTP request failed: " + Std.string(e));
			return;
		}

		xhr.onreadystatechange = function() {
			armIdle();
			// Headers are in as of HEADERS_RECEIVED, which is where the status
			// is worth reporting, waiting for the body would hold it back
			// behind however long the transfer takes.
			if (xhr.readyState == 2) {
				onStatus(xhr.status);
				var finalUrl:String = (xhr.responseURL != null && xhr.responseURL != "") ? xhr.responseURL : url;
				onResponse(xhr.status, __parseHeaderBlock(xhr.getAllResponseHeaders()), finalUrl, finalUrl != url);
			}
		};

		xhr.onprogress = function(e) {
			armIdle();
			onProgress(Std.int(e.loaded), e.lengthComputable ? Std.int(e.total) : 0);
		};

		xhr.onload = function(_) {
			stopIdle();
			if (settled) {
				return;
			}
			settled = true;

			var buffer:js.lib.ArrayBuffer = xhr.response;
			onComplete(buffer == null ? Bytes.alloc(0) : Bytes.ofData(buffer));
		};

		xhr.onerror = function(_) {
			stopIdle();
			if (settled) {
				return;
			}
			settled = true;
			// The browser deliberately withholds the reason, a DNS failure,
			// a refused connection and a blocked cross-origin request are one
			// event with no detail, so there is nothing more specific to pass on.
			onError("HTTP request failed: " + url);
		};

		armIdle();
		xhr.send(__body(body));
	}

	/** `getAllResponseHeaders()`, one field per line, as header objects. */
	static function __parseHeaderBlock(block:String):Array<URLRequestHeader> {
		var list:Array<URLRequestHeader> = [];
		if (block == null) {
			return list;
		}
		for (line in block.split("\r\n")) {
			var colon:Int = line.indexOf(":");
			if (colon > 0) {
				list.push(new URLRequestHeader(StringTools.trim(line.substr(0, colon)).toLowerCase(), StringTools.trim(line.substr(colon + 1))));
			}
		}
		return list;
	}

	static function __body(data:Dynamic):Dynamic {
		if (data == null) {
			return null;
		}

		if ((data is String)) {
			return data;
		}

		if ((data is Bytes)) {
			return new js.lib.Uint8Array((data : Bytes).getData());
		}

		return Std.string(data);
	}
	#end

	#if nodejs
	/**
	 * Node's own http/https client. The module is chosen by scheme, since the
	 * two are separate here rather than one client that reads the URL.
	 *
	 * Node follows no redirects, so this does, by the native client's rules:
	 * at most `MAX_REDIRECTS`, a 301, 302 or 303 turning into a bodiless GET,
	 * `https` to `http` only when `followInsecureRedirects` says so, and the
	 * caller's `Authorization`, `Proxy-Authorization` and `Cookie` dropped once
	 * a hop leaves the origin the request started at. A 3xx used to complete
	 * the load here, where the native client and the browser followed it.
	 */
	static function __sendNode(request:URLRequest, method:String, target:String, body:Dynamic, contentType:String, onStatus:Int->Void,
			onProgress:Int->Int->Void, onComplete:Bytes->Void, onError:String->Void,
			onResponse:(Int, Array<URLRequestHeader>, String, Bool) -> Void):Void {
		var settled:Bool = false;

		var fail = function(message:String):Void {
			if (!settled) {
				settled = true;
				onError(message);
			}
		};

		var headers:haxe.DynamicAccess<String> = {};

		if (request.requestHeaders != null) {
			for (header in request.requestHeaders) {
				if (header != null && header.name != null) {
					headers.set(header.name, header.value);
				}
			}
		}

		if (contentType != null && contentType != "") {
			headers.set("Content-Type", contentType);
		}

		if (request.userAgent != null && request.userAgent != "") {
			headers.set("User-Agent", request.userAgent);
		}

		var origin:String = null;
		var redirects:Int = 0;

		function hop(target:String, method:String, body:Dynamic):Void {
			var url:js.node.url.URL;

			try {
				url = new js.node.url.URL(target);
			} catch (e:Dynamic) {
				fail("Malformed url: " + target);
				return;
			}

			if (origin == null) {
				origin = url.origin;
			}

			var secure:Bool = url.protocol == "https:";

			// Framed with its length, whatever the method. Node frames a body
			// only for the methods it expects one on, so a body on a GET, DELETE
			// or OPTIONS went out with no framing at all: the server read it as
			// the next request, and the next call on that pooled socket got a 400.
			var payload:js.node.Buffer = null;
			__removeHeader(headers, "content-length");
			if (body != null) {
				payload = (body is Bytes) ? js.node.Buffer.from((body : Bytes).getData()) : js.node.Buffer.from(Std.string(body));
				headers.set("Content-Length", Std.string(payload.length));
			}

			var port:Int = crossbyte.utils.IntParse.decimal(url.port, 65535);
			var options:Dynamic = {
				protocol: url.protocol,
				hostname: url.hostname,
				port: port < 0 ? null : port,
				path: url.pathname + url.search,
				method: method,
				headers: headers
			};

			var handler = function(response:js.node.http.IncomingMessage):Void {
				var code:Int = response.statusCode;
				onStatus(code);

				var location:Dynamic = response.headers.get("location");
				if (request.followRedirects && (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) && location != null) {
					// The redirect's own body is not wanted; reading it lets the
					// socket go back to the pool.
					response.resume();

					if (redirects >= MAX_REDIRECTS) {
						fail("Exceeded the number of allowed redirects");
						return;
					}

					var next:js.node.url.URL;
					try {
						next = new js.node.url.URL(Std.string(location), target);
					} catch (e:Dynamic) {
						fail("Could not complete redirect: malformed Location " + location);
						return;
					}

					if (next.protocol != "http:" && next.protocol != "https:") {
						fail("Refused a redirect to " + next.protocol + " only http and https are followed");
						return;
					}
					if (secure && next.protocol == "http:" && !request.followInsecureRedirects) {
						fail("Refused a redirect from https to http; set URLRequest.followInsecureRedirects to allow it");
						return;
					}

					if (next.origin != origin) {
						__removeHeader(headers, "authorization");
						__removeHeader(headers, "proxy-authorization");
						__removeHeader(headers, "cookie");
					}

					var nextMethod:String = method;
					var nextBody:Dynamic = body;
					if ((code == 301 || code == 302 || code == 303) && method != "HEAD") {
						nextMethod = "GET";
						nextBody = null;
						__removeHeader(headers, "content-type");
					}

					redirects++;
					hop(next.href, nextMethod, nextBody);
					return;
				}

				onResponse(code, __nodeHeaders(response.headers), target, redirects > 0);

				var lengthHeader = response.headers.get("content-length");
				var total:Int = 0;

				if (lengthHeader != null) {
					// As the native client reads it: past an Int, Std.parseInt
					// gave Node a number no Int holds.
					var parsed:Int = crossbyte.utils.IntParse.decimal(Std.string(lengthHeader));
					total = parsed < 0 ? 0 : parsed;
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

			// Node refuses a method that is not a token, or a header value
			// holding a line break, by throwing here, synchronously, out of
			// URLLoader.load() and into whoever called it, where every other
			// failure arrives as an IO_ERROR.
			var clientRequest:js.node.http.ClientRequest;
			try {
				clientRequest = secure ? js.node.Https.request(options, handler) : js.node.Http.request(options, handler);
			} catch (e:Dynamic) {
				fail("HTTP request failed: " + Std.string(e));
				return;
			}

			clientRequest.on("error", function(e) {
				fail("HTTP request failed: " + Std.string(e));
			});

			// An idle timeout, as Node's setTimeout is and the native client's
			// socket timeout is.
			if (request.idleTimeout > 0) {
				clientRequest.setTimeout(request.idleTimeout, function(_) {
					clientRequest.destroy();
					fail("HTTP request timed out: " + target);
				});
			}

			if (payload != null) {
				clientRequest.write(payload);
			}

			clientRequest.end();
		}

		hop(target, method, body);
	}

	/** Removes a header whatever case the caller wrote it in. */
	static function __removeHeader(headers:haxe.DynamicAccess<String>, name:String):Void {
		for (key in headers.keys()) {
			if (key.toLowerCase() == name) {
				headers.remove(key);
			}
		}
	}

	/** Node's parsed headers, a string each, an array for Set-Cookie, as header objects. */
	static function __nodeHeaders(raw:Dynamic):Array<URLRequestHeader> {
		var list:Array<URLRequestHeader> = [];
		for (name in Reflect.fields(raw)) {
			var value:Dynamic = Reflect.field(raw, name);
			if (Std.isOfType(value, Array)) {
				for (entry in (value : Array<Dynamic>)) {
					list.push(new URLRequestHeader(name, Std.string(entry)));
				}
			} else {
				list.push(new URLRequestHeader(name, Std.string(value)));
			}
		}
		return list;
	}
	#end
}
