package crossbyte.url;

// Node only: the client under test is Node's own, behind JsHttpClient.
#if nodejs
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.http.HTTPTestSupport;
import utest.Assert;
import utest.Async;

/**
 * `URLLoader` on Node, where it runs over Node's http client rather than
 * CrossByte's own.
 *
 * That client never decoded a content coding: a gzip answer reached the
 * caller as gzip, garbage as text, and the next such body threw a RangeError
 * out of `getString` inside the loader's completion, which ended the process.
 * jvm and eval decoded the same responses. It decodes them now, with Node's
 * zlib and within `URLRequest.maxDecompressedSize`, and a body that cannot be
 * read as text is an `IO_ERROR`.
 */
@:timeout(20000)
class URLLoaderNodeTest extends utest.Test {
	static inline final JSON:String = '{"name":"crossbyte","items":[1,2,3,4,5,6,7,8,9,10],"text":"the same words over and over and over again"}';

	public function testCompressedAnswersAreDecoded(async:Async):Void {
		serve(function(port:Int, close:Void->Void):Void {
			var paths:Array<String> = ["gzip", "br", "deflate", "raw", "stacked"];
			var results:Array<String> = [];

			function next(index:Int):Void {
				if (index >= paths.length) {
					close();
					for (i in 0...paths.length) {
						Assert.equals("ok " + JSON, results[i], paths[i]);
					}
					async.done();
					return;
				}
				load('http://127.0.0.1:$port/${paths[index]}', null, outcome -> {
					results.push(outcome);
					next(index + 1);
				});
			}
			next(0);
		});
	}

	public function testABodyThatIsNotTextIsAnErrorNotACrash(async:Async):Void {
		// F8 88 80 80 80 is a five-byte UTF-8 lead nothing decodes to a code
		// point: getString threw a RangeError here, out of the completion.
		serve(function(port:Int, close:Void->Void):Void {
			load('http://127.0.0.1:$port/binary', null, outcome -> {
				close();
				Assert.isTrue(StringTools.startsWith(outcome, "error "), outcome);
				Assert.isTrue(outcome.indexOf("could not be read as text") >= 0, outcome);
				async.done();
			});
		});
	}

	public function testTheDecodeLimitHolds(async:Async):Void {
		// A megabyte of zeros is about a kilobyte of gzip.
		serve(function(port:Int, close:Void->Void):Void {
			load('http://127.0.0.1:$port/bomb', 64 * 1024, outcome -> {
				close();
				Assert.isTrue(StringTools.startsWith(outcome, "error "), "a body past the decode limit was taken: " + outcome.substr(0, 60));
				Assert.isTrue(outcome.indexOf("decode") >= 0, outcome);
				async.done();
			});
		});
	}

	/** Loads `url` as text, and calls `done` with "ok <data>" or "error <text>". */
	private static function load(url:String, limit:Null<Int>, done:String->Void):Void {
		var loader:URLLoader = new URLLoader();
		var outcome:Null<String> = null;
		loader.addEventListener(Event.COMPLETE, _ -> outcome = "ok " + Std.string(loader.data));
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> outcome = "error " + event.text);
		var request:URLRequest = new URLRequest(url);
		request.requestHeaders.push(new URLRequestHeader("Accept-Encoding", "gzip, br, deflate"));
		if (limit != null) {
			request.maxDecompressedSize = limit;
		}
		loader.load(request);
		HTTPTestSupport.pumpUntilAsync(() -> outcome != null, 10.0, _ -> done(outcome == null ? "error timed out" : outcome));
	}

	/** Starts Node's http server with the answers this suite asks for. */
	private static function serve(then:(port:Int, close:Void->Void) -> Void):Void {
		var zlib:Dynamic = js.Lib.require("zlib");
		var json:js.node.Buffer = js.node.Buffer.from(JSON);
		var server:js.node.http.Server = js.node.Http.createServer(function(request, response):Void {
			var url:String = Std.string(request.url);
			var headers:Dynamic = {"Content-Type": "application/json"};
			var body:js.node.Buffer = json;
			switch (url) {
				case "/gzip":
					body = zlib.gzipSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "gzip"};
				case "/br":
					body = zlib.brotliCompressSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "br"};
				case "/deflate":
					body = zlib.deflateSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "deflate"};
				case "/raw":
					// Raw deflate, which CrossByte's own server has sent as deflate.
					body = zlib.deflateRawSync(json);
					headers = {"Content-Type": "application/json", "Content-Encoding": "deflate"};
				case "/stacked":
					body = zlib.brotliCompressSync(zlib.gzipSync(json));
					headers = {"Content-Type": "application/json", "Content-Encoding": "gzip, br"};
				case "/binary":
					body = js.node.Buffer.from([0xF8, 0x88, 0x80, 0x80, 0x80]);
					headers = {"Content-Type": "text/plain"};
				case "/bomb":
					body = zlib.gzipSync(js.node.Buffer.alloc(1024 * 1024));
					headers = {"Content-Type": "application/octet-stream", "Content-Encoding": "gzip"};
				case _:
			}
			response.writeHead(200, headers);
			response.end(body);
		});
		server.listen(0, "127.0.0.1", function():Void {
			var port:Int = (server.address() : Dynamic).port;
			then(port, () -> server.close());
		});
	}
}
#end
