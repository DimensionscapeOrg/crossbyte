package crossbyte.url._internal;

import crossbyte.http.HTTPCancelToken;
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

	/** What a cancelled request reports, as the native client says it. */
	private static inline var CANCELLED:String = "Request cancelled";

	/**
	 * Issues `request`, reporting through the callbacks. Exactly one of
	 * `onComplete` or `onError` is called, once. `onResponse` is called once,
	 * before either, when a final response has arrived: its status, headers,
	 * the URL it came from, and whether a redirect led there.
	 *
	 * Cancelling `token` aborts the request where it stands, the hop in
	 * flight, a redirect included, and calls `onError` with "Request
	 * cancelled", at once, unless the request has ended already.
	 */
	public static function send(request:URLRequest, onStatus:Int->Void, onProgress:Int->Int->Void, onComplete:Bytes->Void, onError:String->Void,
			?onResponse:(status:Int, headers:Array<URLRequestHeader>, url:String, redirected:Bool) -> Void, ?token:HTTPCancelToken):Void {
		if (request == null || request.url == null || request.url == "") {
			onError("URLRequest has no url.");
			return;
		}

		if (onResponse == null) {
			onResponse = (_, _, _, _) -> {};
		}
		if (token != null && token.cancelled) {
			onError(CANCELLED);
			return;
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
		__sendBrowser(request, method, url, body, contentType, onStatus, onProgress, onComplete, onError, onResponse, token);
		#elseif nodejs
		__sendNode(request, method, url, body, contentType, onStatus, onProgress, onComplete, onError, onResponse, token);
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
			onResponse:(Int, Array<URLRequestHeader>, String, Bool) -> Void, token:Null<HTTPCancelToken>):Void {
		// The browser does its own TLS and tells a page nothing of the key it
		// was shown, so a pin cannot be checked here. Refused rather than sent
		// unchecked, as on the targets whose TLS cannot say either.
		if (__pins(request).length > 0) {
			onError("Public key pinning is not available in a browser: it gives a page no access to the server's certificate");
			return;
		}

		var xhr = new js.html.XMLHttpRequest();
		var settled:Bool = false;
		var idle:haxe.Timer = null;
		var onCancelled:Null<Void->Void> = null;

		function stopIdle():Void {
			if (idle != null) {
				idle.stop();
				idle = null;
			}
		}

		// Marks the request over, and answers whether it was not already.
		function settle():Bool {
			if (settled) {
				return false;
			}
			settled = true;
			stopIdle();
			if (onCancelled != null) {
				token.removeHandler(onCancelled);
			}
			return true;
		}

		// Time without progress, not a deadline on the whole exchange: this
		// was xhr.timeout, which ended a large download that was still moving
		// where every other client would have let it finish.
		function armIdle():Void {
			stopIdle();
			if (request.idleTimeout > 0 && !settled) {
				idle = haxe.Timer.delay(function():Void {
					if (!settle()) {
						return;
					}
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
			settle();
			onError("HTTP request failed: " + Std.string(e));
			return;
		}

		xhr.onreadystatechange = function() {
			if (settled) {
				return;
			}
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
			if (settled) {
				return;
			}
			armIdle();
			onProgress(Std.int(e.loaded), e.lengthComputable ? Std.int(e.total) : 0);
		};

		xhr.onload = function(_) {
			if (!settle()) {
				return;
			}

			var buffer:js.lib.ArrayBuffer = xhr.response;
			onComplete(buffer == null ? Bytes.alloc(0) : Bytes.ofData(buffer));
		};

		xhr.onerror = function(_) {
			if (!settle()) {
				return;
			}
			// The browser deliberately withholds the reason, a DNS failure,
			// a refused connection and a blocked cross-origin request are one
			// event with no detail, so there is nothing more specific to pass on.
			onError("HTTP request failed: " + url);
		};

		// The request ends where it stands. An abort fires neither load nor
		// error, so the cancel is reported here, once.
		if (token != null) {
			onCancelled = () -> {
				if (settle()) {
					xhr.abort();
					onError(CANCELLED);
				}
			};
			token.onCancel(onCancelled);
		}

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
			return __view(data);
		}

		return Std.string(data);
	}
	#end

	#if js
	/**
		The bytes `bytes` holds, as a view, without a copy.

		Its length, not its buffer's. `getData()` is the whole buffer, and a
		`ByteArray`'s runs on past `length` into the room it keeps to grow,
		and into whatever it held before it was cleared. Both clients sent the
		buffer: "hello" went out as nine bytes, and written after a secret,
		with the rest of the secret behind it.
	**/
	@:noCompletion public static inline function __view(bytes:Bytes):js.lib.Uint8Array {
		return new js.lib.Uint8Array(bytes.getData(), 0, bytes.length);
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
			onResponse:(Int, Array<URLRequestHeader>, String, Bool) -> Void, token:Null<HTTPCancelToken>):Void {
		var settled:Bool = false;
		// The hop in flight, which a cancel aborts.
		var current:Null<js.node.http.ClientRequest> = null;
		var onCancelled:Null<Void->Void> = null;

		// Marks the request over, and answers whether it was not already.
		function settle():Bool {
			if (settled) {
				return false;
			}
			settled = true;
			if (onCancelled != null) {
				token.removeHandler(onCancelled);
			}
			return true;
		}

		var fail = function(message:String):Void {
			if (settle()) {
				onError(message);
			}
		};

		// Aborted where it stands: the request's socket is destroyed, which the
		// server sees at once, and whatever Node reports of it after this is
		// the request being over already.
		if (token != null) {
			onCancelled = () -> {
				if (!settled) {
					if (current != null) {
						current.destroy();
					}
					fail(CANCELLED);
				}
			};
			token.onCancel(onCancelled);
		}

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

		// What the native client asks for unless told otherwise. With none,
		// RFC 9110 lets a server pick any coding.
		var askedForCoding:Bool = false;
		for (key in headers.keys()) {
			if (key.toLowerCase() == "accept-encoding") {
				askedForCoding = true;
			}
		}
		if (!askedForCoding) {
			headers.set("Accept-Encoding", "identity");
		}

		var origin:String = null;
		var redirects:Int = 0;
		var leftOrigin:Bool = false;

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
				// Its own bytes, not its buffer's: see __view.
				payload = (body is Bytes) ? js.node.Buffer.from((body : Bytes).getData(), 0, (body : Bytes).length) : js.node.Buffer.from(Std.string(body));
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
			if (secure) {
				__applyTls(request, options, leftOrigin);
			}

			var handler = function(response:js.node.http.IncomingMessage):Void {
				if (settled) {
					// Cancelled, or timed out, as the response came.
					response.resume();
					return;
				}
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
						// And the client certificate, meant for the origin named.
						leftOrigin = true;
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
					if (settled) {
						return;
					}
					chunks.push(chunk);
					loaded += chunk.length;
					onProgress(loaded, total);
				});

				response.on("end", function() {
					if (!settle()) {
						return;
					}

					// Decoded as the native client decodes, within the same
					// limits. The body was handed on as it came, so a gzip
					// answer reached the caller as gzip, garbage as text, and
					// the next such body ended the process in getString.
					__decodeNode(js.node.Buffer.concat(chunks), response.headers.get("content-encoding"), request.maxDecompressedSize,
						function(error:Null<String>, decoded:Null<js.node.Buffer>):Void {
							if (error != null) {
								onError(error);
								return;
							}
							// Sliced by its own region: a Buffer can be a window
							// onto a larger pooled allocation, and taking .buffer
							// whole would carry bytes belonging to something else.
							onComplete(Bytes.ofData(decoded.buffer.slice(decoded.byteOffset, decoded.byteOffset + decoded.byteLength)));
						});
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
			current = clientRequest;

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

	/**
		`request`'s TLS options onto Node's request `options`: whether the
		server is checked, the authority trusted, the client certificate,
		not once a redirect has `leftOrigin`, and the pinned keys.

		Node's agent keeps its sockets by these same options, so a request
		that checks its server is never handed a socket opened without the
		check. Pins are not among them, and are not checked in
		`checkServerIdentity` either: Node calls that only once the chain has
		verified, so with `verifyCert` off a pin was never looked at. A pinned
		request makes its own connection instead, and is given it only once
		the server's key has been checked, before a byte of the request.
	**/
	static function __applyTls(request:URLRequest, options:Dynamic, leftOrigin:Bool):Void {
		if (!request.verifyCert) {
			options.rejectUnauthorized = false;
		}
		if (request.certAuthority != null) {
			options.ca = [@:privateAccess request.certAuthority.__pem];
		}
		if (!leftOrigin && request.clientCertificate != null && request.clientKey != null) {
			options.cert = @:privateAccess request.clientCertificate.__pem;
			options.key = @:privateAccess request.clientKey.__pem;
			var passphrase:Null<String> = @:privateAccess request.clientKey.__passphrase;
			if (passphrase != null) {
				options.passphrase = passphrase;
			}
		}

		var pins:Array<String> = __pins(request);
		if (pins.length == 0) {
			return;
		}

		// An IPv6 literal as a URL writes it, bracketed, which the request
		// options take and a TLS connect does not.
		var host:String = options.hostname;
		if (StringTools.startsWith(host, "[") && StringTools.endsWith(host, "]")) {
			host = host.substring(1, host.length - 1);
		}
		var connectOptions:Dynamic = {
			host: host,
			port: options.port != null ? options.port : 443,
			rejectUnauthorized: request.verifyCert
		};
		// SNI for a name, as the agent sends it; RFC 6066 has none for an address.
		if (js.node.Net.isIP(host) == 0) {
			connectOptions.servername = host;
		}
		for (field in ["ca", "cert", "key", "passphrase"]) {
			if (Reflect.field(options, field) != null) {
				Reflect.setField(connectOptions, field, Reflect.field(options, field));
			}
		}

		var idleTimeout:Int = request.idleTimeout;
		// No agent is named, so the request takes the socket this hands it.
		options.createConnection = function(_:Dynamic, oncreate:(error:Dynamic, ?socket:Dynamic) -> Void):Dynamic {
			var socket:Dynamic = js.node.Tls.connect(connectOptions);
			var settled:Bool = false;
			function settle(error:Dynamic):Void {
				if (settled) {
					return;
				}
				settled = true;
				if (error != null) {
					socket.destroy();
					oncreate(error);
					return;
				}
				socket.setTimeout(0);
				oncreate(null, socket);
			}

			// Left attached once the socket is handed over: an error before the
			// request has added its own listener would otherwise be uncaught.
			socket.on("error", (error:Dynamic) -> settle(error));
			if (idleTimeout > 0) {
				socket.setTimeout(idleTimeout, () -> settle(new js.lib.Error("The TLS handshake timed out")));
			}
			socket.once("secureConnect", function():Void {
				var certificate:Dynamic = socket.getPeerCertificate(false);
				var raw:Null<js.node.Buffer> = certificate != null ? certificate.raw : null;
				var pin:Null<String> = raw == null ? null : crossbyte._internal.http.PublicKeyPins.pinOf(Bytes.ofData(raw.buffer.slice(raw.byteOffset,
					raw.byteOffset + raw.byteLength)));
				if (pin != null && pins.indexOf(crossbyte._internal.http.PublicKeyPins.normalize(pin)) >= 0) {
					settle(null);
					return;
				}
				settle(new js.lib.Error(pin == null ? "The server presented no certificate to check its pinned public key against" : "The server's public key, "
					+ pin + ", is not one this request pins"));
			});
			return js.Lib.undefined;
		};
	}
	#end

	/** `request`'s pins, as compared: none blank, none with a `sha256/` prefix. */
	static function __pins(request:URLRequest):Array<String> {
		var pins:Array<String> = [];
		if (request.pinnedPublicKeys != null) {
			for (pin in request.pinnedPublicKeys) {
				if (pin != null && StringTools.trim(pin).length > 0) {
					pins.push(crossbyte._internal.http.PublicKeyPins.normalize(pin));
				}
			}
		}
		return pins;
	}

	#if nodejs

	/**
		Undoes the codings `header` names on `body`, the last applied first,
		with Node's own zlib, and calls `done` with the body or with why it
		could not be decoded.

		The native client's rules: at most two stacked codings, and no more
		than `limit` bytes out (`<= 0`, none), which zlib stops at itself
		(`maxOutputLength`) rather than after allocating the lot. `deflate` is
		zlib-wrapped as RFC 9110 defines it, or raw as CrossByte's own server
		has sent it; both are read. LZ4, which Node has no codec for, goes
		through the one every other target uses.
	**/
	static function __decodeNode(body:js.node.Buffer, header:Dynamic, limit:Int, done:(error:Null<String>, decoded:Null<js.node.Buffer>) -> Void):Void {
		var codings:Array<String> = [];
		if (header != null) {
			for (raw in Std.string(header).split(",")) {
				var token:String = StringTools.trim(raw);
				var semi:Int = token.indexOf(";");
				if (semi >= 0) {
					token = StringTools.trim(token.substr(0, semi));
				}
				token = token.toLowerCase();
				if (token != "" && token != "identity") {
					codings.push(token);
				}
			}
		}

		if (codings.length == 0 || body.length == 0) {
			done(null, body);
			return;
		}
		if (codings.length > 2) {
			done("Failed to decode response body: it stacked " + codings.length + " content codings, more than the 2 allowed", null);
			return;
		}

		var zlib:Dynamic = js.Lib.require("zlib");
		var options:Dynamic = limit > 0 ? {maxOutputLength: limit} : {};

		function failed(error:Dynamic):Void {
			var reason:Dynamic = error != null && error.message != null ? error.message : error;
			done("Failed to decode response body: " + Std.string(reason), null);
		}

		function step(index:Int, current:js.node.Buffer):Void {
			if (index < 0) {
				done(null, current);
				return;
			}

			var next = function(error:Dynamic, result:js.node.Buffer):Void {
				if (error != null) {
					failed(error);
					return;
				}
				step(index - 1, result);
			};

			switch (codings[index]) {
				case "gzip", "x-gzip":
					zlib.gunzip(current, options, next);
				case "br" if (zlib.brotliDecompress != null):
					zlib.brotliDecompress(current, options, next);
				case "deflate":
					zlib.inflate(current, options, function(error:Dynamic, result:js.node.Buffer):Void {
						if (error == null) {
							step(index - 1, result);
						} else {
							zlib.inflateRaw(current, options, next);
						}
					});
				case "lz4":
					try {
						var encoded:crossbyte.io.ByteArray = Bytes.ofData(current.buffer.slice(current.byteOffset, current.byteOffset + current.byteLength));
						encoded.uncompress(crossbyte.utils.CompressionAlgorithm.LZ4, limit > 0 ? limit : 0);
						var plain:Bytes = Bytes.alloc(encoded.length);
						plain.blit(0, encoded, 0, encoded.length);
						step(index - 1, js.node.Buffer.from(plain.getData()));
					} catch (error:Dynamic) {
						failed(error);
					}
				case unknown:
					done("Unsupported content encoding: " + unknown, null);
			}
		}

		step(codings.length - 1, body);
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
