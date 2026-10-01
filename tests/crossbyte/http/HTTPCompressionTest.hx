package crossbyte.http;

import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.test.Require;
import crossbyte.url.URLRequestHeader;
import crossbyte.utils.CompressionAlgorithm;
import utest.Assert;
import utest.Async;

/**
 * What the server compresses, and what a response says about it.
 *
 * Every non-empty body was compressed: errors and 429s too, so a flood of
 * refused requests cost a Brotli encoder each; a two-byte answer came out as
 * 22 bytes; PNGs grew; a static file was compressed again on every request.
 * No response said `Vary: Accept-Encoding`, a route's strong ETag went out on
 * every coding of its body, and a HEAD reported the identity length beside a
 * GET that went out as br. `HTTPServerConfig.compression` is the policy now.
 */
@:timeout(20000)
class HTTPCompressionTest extends utest.Test {
	private var __roots:Array<File> = [];

	public function teardown():Void {
		for (root in __roots) {
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}
		}
		__roots = [];
	}

	public function testAnErrorIsSentAsItIs(async:Async):Void {
		// A 429 or a 404 cost a full Brotli setup whenever the client listed
		// br, which every browser does: the rate limiter then did not bound
		// what a flood of refused requests cost.
		var server:HTTPServer = __serve(config -> {
			config.middleware.push((handler, next) -> handler.respond(handler.requestPath == "/limited" ? 429 : 404, "text/plain", __text(4096)));
		});

		HTTPTestSupport.exchangeEach(server, [
			"GET /limited HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br, gzip\r\n\r\n",
			"GET /missing HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br, gzip\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(429, responses[0].status);
			Assert.isNull(responses[0].headers.get("content-encoding"), "a 429 was compressed");
			Assert.equals(404, responses[1].status);
			Assert.isNull(responses[1].headers.get("content-encoding"), "a 404 was compressed");
			Assert.equals(4096, responses[1].bodyBytes.length);
			async.done();
		});
	}

	public function testASmallBodyOrAnUnlistedTypeIsSentAsItIs(async:Async):Void {
		// A two-byte body came out as 22 bytes of gzip, and a PNG, compressed
		// already, grew.
		var server:HTTPServer = __serve(config -> {
			config.middleware.push((handler, next) -> {
				if (handler.requestPath == "/tiny") {
					handler.respond(200, "text/plain", "ok");
				} else {
					var png:ByteArray = new ByteArray();
					for (i in 0...4096) {
						png.writeByte(i % 251);
					}
					handler.respondBytes(200, "image/png", png);
				}
			});
		});

		HTTPTestSupport.exchangeEach(server, [
			"GET /tiny HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n",
			"GET /image HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, br\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			// Compared rather than printed: a compressed body in a failure
			// message can hold a NUL, which hides later failures on hxcpp.
			Assert.isNull(responses[0].headers.get("content-encoding"), "a two-byte body was compressed");
			Assert.isTrue(responses[0].body == "ok", "a two-byte body did not go out as it was");
			Assert.isNull(responses[1].headers.get("content-encoding"), "a PNG was compressed");
			Assert.equals(4096, responses[1].bodyBytes.length);
			async.done();
		});
	}

	public function testANegotiatedResponseVariesOnAcceptEncoding(async:Async):Void {
		// No response said Vary, so a cache keyed on the URL replayed a br
		// body to clients that had not asked for br. Said on every answer that
		// could have been encoded, including one that went out as it is.
		var text:String = __text(4096);
		var server:HTTPServer = __serve(config -> config.middleware.push((handler, next) -> handler.respond(200, "text/plain", text)));

		HTTPTestSupport.exchangeEach(server, [
			"GET /page HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n",
			"GET /page HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals("br", responses[0].headers.get("content-encoding"));
			Assert.equals("Accept-Encoding", responses[0].headers.get("vary"));
			Assert.equals(text, __decode(responses[0].bodyBytes, CompressionAlgorithm.BROTLI));

			Assert.isNull(responses[1].headers.get("content-encoding"));
			Assert.equals("Accept-Encoding", responses[1].headers.get("vary"), "an identity variant did not say it varies");
			Assert.isTrue(responses[1].body == text, "the identity variant's body was not the text");
			async.done();
		});
	}

	public function testAnEncodedVariantsETagIsWeak(async:Async):Void {
		// One strong tag went out on the identity, gzip, br and deflate bodies
		// of a route, and a strong tag names one exact sequence of bytes.
		var server:HTTPServer = __serve(config -> {
			config.middleware.push((handler, next) -> handler.respond(200, "text/plain", __text(4096), [new URLRequestHeader("ETag", "\"v1\"")]));
		});

		HTTPTestSupport.exchangeEach(server, [
			"GET /tagged HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n",
			"GET /tagged HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals("gzip", responses[0].headers.get("content-encoding"));
			Assert.equals("W/\"v1\"", responses[0].headers.get("etag"));
			Assert.equals("\"v1\"", responses[1].headers.get("etag"), "the identity body's own tag was changed");
			async.done();
		});
	}

	public function testAHeadIsNegotiatedAsItsGetIs(async:Async):Void {
		// A HEAD skipped negotiation, so it said identity and its own length
		// beside a GET that went out as br, and a route's HEAD said
		// Content-Length: 0 whatever its GET carried.
		var text:String = __text(4096);
		var server:HTTPServer = __serve(config -> config.middleware.push((handler, next) -> handler.respond(200, "text/plain", text)));

		HTTPTestSupport.exchangeEach(server, [
			"HEAD /page HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n",
			"HEAD /page HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(200, responses[0].status);
			Assert.equals("br", responses[0].headers.get("content-encoding"), "a HEAD named no coding its GET would use");
			Assert.equals("Accept-Encoding", responses[0].headers.get("vary"));
			// The encoded length is not known without encoding; left out.
			Assert.isNull(responses[0].headers.get("content-length"));

			Assert.isNull(responses[1].headers.get("content-encoding"));
			Assert.equals("4096", responses[1].headers.get("content-length"), "a HEAD did not give its GET's length");
			async.done();
		});
	}

	public function testThePolicyIsConfigurable(async:Async):Void {
		var off:HTTPServer = __serve(config -> {
			config.compression.enabled = false;
			config.middleware.push((handler, next) -> handler.respond(200, "text/plain", __text(4096)));
		});

		HTTPTestSupport.exchangeEach(off, ["GET /page HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n"], function(first):Void {
			try off.close() catch (_:Dynamic) {}
			Assert.isNull(first[0].headers.get("content-encoding"), "compression that was turned off still ran");
			Assert.isNull(first[0].headers.get("vary"));

			var tuned:HTTPServer = __serve(config -> {
				config.compression.minimumSize = 10;
				config.compression.types = ["application/octet-stream"];
				config.middleware.push((handler, next) -> {
					var body:ByteArray = new ByteArray();
					body.writeUTFBytes(__text(64));
					handler.respondBytes(200, handler.requestPath == "/bytes" ? "application/octet-stream" : "text/plain", body);
				});
			});
			HTTPTestSupport.exchangeEach(tuned, [
				"GET /bytes HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n",
				"GET /text HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n"
			], function(second:Array<HTTPTestResponse>):Void {
				try tuned.close() catch (_:Dynamic) {}
				Assert.equals("gzip", second[0].headers.get("content-encoding"), "a listed type past the minimum was not compressed");
				Assert.isNull(second[1].headers.get("content-encoding"), "an unlisted type was compressed");
				async.done();
			});
		});
	}

	/**
		A browser's list, gzip, deflate, br, zstd, all equal, gets gzip for
		a body encoded for one response, unless Brotli is native: Brotli in
		Haxe took 1.3 ms for 64 KB of JSON where gzip from native zlib takes
		0.2, and a server answering browsers was held to about 800 compressed
		responses a second. A static file is encoded once and kept, so it
		still goes as br, the smallest; and a client whose q-values prefer br
		gets br.
	**/
	public function testABrowserGetsGzipPerResponseAndBrForAKeptFile(async:Async):Void {
		var text:String = __text(8192);
		var server:HTTPServer = __serve(config -> config.middleware.push((handler, next) -> {
			if (handler.requestPath == "/dynamic") {
				handler.respond(200, "text/plain", text);
			} else {
				next();
			}
		}), root -> __write(root, "app.js", text));

		HTTPTestSupport.exchangeEach(server, [
			"GET /dynamic HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, deflate, br, zstd\r\n\r\n",
			"GET /app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, deflate, br, zstd\r\n\r\n",
			"GET /dynamic HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=0.5, br\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			#if crossbyte_brotli_native
			Assert.equals("br", responses[0].headers.get("content-encoding"), "native Brotli was passed over");
			#else
			Assert.equals("gzip", responses[0].headers.get("content-encoding"), "a browser's per-response body did not go as gzip");
			Assert.isTrue(__decode(responses[0].bodyBytes, CompressionAlgorithm.GZIP) == text, "the gzip body was not the text");
			#end
			Assert.equals("br", responses[1].headers.get("content-encoding"), "a kept file did not go as br");
			Assert.isTrue(__decode(responses[1].bodyBytes, CompressionAlgorithm.BROTLI) == text, "the br file was not the text");
			Assert.equals("br", responses[2].headers.get("content-encoding"), "a client preferring br did not get it");
			async.done();
		});
	}

	public function testAStaticFileIsCompressedOnceAndKept(async:Async):Void {
		// Compressed again for every request: a 150 KB script served 863
		// requests a second as it was, and 64 as Brotli, natively.
		var text:String = __text(8192);
		var compression:Null<HTTPCompression> = null;
		var server:HTTPServer = __serve(config -> compression = config.compression, root -> __write(root, "app.js", text));

		HTTPTestSupport.exchangeEach(server, [
			"GET /app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n",
			"GET /app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			for (response in responses) {
				Assert.equals("br", response.headers.get("content-encoding"));
				Assert.equals("Accept-Encoding", response.headers.get("vary"));
				Assert.equals(text, __decode(response.bodyBytes, CompressionAlgorithm.BROTLI));
			}
			Require.notNull(compression);
			Assert.equals(responses[0].bodyBytes.length, compression.cachedBytes, "the encoded file was not kept");
			async.done();
		});
	}

	public function testAPrecompressedSiblingIsServedInsteadOfTheFile(async:Async):Void {
		// A .br or .gz made at build time costs nothing to serve, and is the
		// only way a file too large to hold goes out compressed at all.
		var text:String = __text(8192);
		// Built from the same text marked, so a sibling sent can be told from
		// the file compressed on the spot.
		var brotli:ByteArray = __encode(text + "/* prebuilt br */", CompressionAlgorithm.BROTLI);
		var gzip:ByteArray = __encode(text + "/* prebuilt gz */", CompressionAlgorithm.GZIP);
		var server:HTTPServer = __serve(null, root -> {
			// The file, then its siblings, as a build writes them: a sibling
			// older than its file is stale and is not used.
			__write(root, "app.js", text);
			__writeBytes(root, "app.js.br", brotli);
			__writeBytes(root, "app.js.gz", gzip);
		});

		HTTPTestSupport.exchangeEach(server, [
			"GET /app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n",
			"GET /app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n",
			"HEAD /app.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n",
			"GET /app.js HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals("br", responses[0].headers.get("content-encoding"));
			Assert.isTrue(__decode(responses[0].bodyBytes, CompressionAlgorithm.BROTLI) == text + "/* prebuilt br */", "the .br sibling was not what went out");
			Assert.equals("application/javascript; charset=utf-8", responses[0].headers.get("content-type"));
			Assert.equals("gzip", responses[1].headers.get("content-encoding"));
			Assert.isTrue(__decode(responses[1].bodyBytes, CompressionAlgorithm.GZIP) == text + "/* prebuilt gz */", "the .gz sibling was not what went out");
			Assert.equals("br", responses[2].headers.get("content-encoding"));
			Assert.equals(Std.string(brotli.length), responses[2].headers.get("content-length"), "a HEAD did not give the sibling's length");
			Assert.isNull(responses[3].headers.get("content-encoding"));
			Assert.isTrue(responses[3].body == text, "the file itself did not go out to a client asking for no coding");
			async.done();
		});
	}

	// ---------------------------------------------------------------- utils

	private function __serve(configure:Null<HTTPServerConfig->Void>, ?populate:File->Void):HTTPServer {
		var root:File = File.createTempDirectory();
		__roots.push(root);
		if (populate != null) {
			populate(root);
		}
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0, root);
		if (configure != null) {
			configure(config);
		}
		return new HTTPServer(config);
	}

	/** `length` characters of text that compresses, and is not all one byte. */
	private static function __text(length:Int):String {
		var words:Array<String> = ["alpha ", "bravo ", "charlie ", "delta ", "echo ", "foxtrot ", "golf ", "hotel "];
		var out:StringBuf = new StringBuf();
		var written:Int = 0;
		var i:Int = 0;
		while (written < length) {
			var word:String = words[i++ % words.length];
			if (written + word.length > length) {
				word = word.substr(0, length - written);
			}
			out.add(word);
			written += word.length;
		}
		return out.toString();
	}

	private static function __encode(text:String, algorithm:CompressionAlgorithm):ByteArray {
		var bytes:ByteArray = new ByteArray();
		bytes.writeUTFBytes(text);
		bytes.compress(algorithm);
		return bytes;
	}

	private static function __decode(body:ByteArray, algorithm:CompressionAlgorithm):String {
		var copy:ByteArray = new ByteArray();
		copy.writeBytes(body, 0, body.length);
		copy.uncompress(algorithm);
		return copy.toString();
	}

	private static function __write(root:File, name:String, text:String):Void {
		var bytes:ByteArray = new ByteArray();
		bytes.writeUTFBytes(text);
		root.resolvePath(name).save(bytes);
	}

	private static function __writeBytes(root:File, name:String, bytes:ByteArray):Void {
		root.resolvePath(name).save(bytes);
	}
}
