package crossbyte.url;

// A page only: the client under test is the browser's XMLHttpRequest.
#if (js && !nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import utest.Assert;
import utest.Async;

/**
	`URLLoader` in a page, where the browser does the TLS.

	A page is told nothing of the certificate a server presented, so a pinned
	request cannot be checked there. It is refused, as on the targets whose
	TLS cannot say either, rather than sent with the pin ignored.

	The page `ci/browser/run.js` serves answers any method with the file
	named, so what a request sends is read off `XMLHttpRequest` itself, by
	wrapping its methods for the length of a case.
**/
@:timeout(10000)
class URLLoaderBrowserTest extends utest.Test {
	public function testAPinnedRequestIsRefusedNotSentUnchecked(async:Async):Void {
		var loader:URLLoader = new URLLoader();
		// Nothing needs to answer here: with the pin honoured, nothing is sent.
		var request:URLRequest = new URLRequest("https://127.0.0.1:9/");
		request.pinnedPublicKeys = ["sha256/" + haxe.crypto.Base64.encode(haxe.io.Bytes.alloc(32))];
		var settled:Bool = false;
		loader.addEventListener(Event.COMPLETE, _ -> {
			if (!settled) {
				settled = true;
				Assert.fail("a pinned request completed in a browser");
				async.done();
			}
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> {
			if (!settled) {
				settled = true;
				Assert.isTrue(event.text.indexOf("not available in a browser") >= 0, "a pinned request was sent: " + event.text);
				async.done();
			}
		});
		loader.load(request);
	}

	/**
		A `ByteArray` body goes to the browser as the bytes it holds. It was
		handed the buffer under it, which runs on past `length` into the room
		it keeps to grow -- and into whatever it held before it was cleared.
	**/
	public function testAByteArrayBodyGoesOutAsItsLength(async:Async):Void {
		var body:crossbyte.io.ByteArray = new crossbyte.io.ByteArray();
		body.writeUTFBytes("a secret, written first and then cleared away");
		body.clear();
		body.writeUTFBytes("hello");

		var sent:Array<Dynamic> = [];
		var restore:Void->Void = wrap("send", (xhr, args) -> sent.push(args[0]));
		var request:URLRequest = new URLRequest("/index.html");
		request.method = URLRequestMethod.POST;
		request.data = body;
		loadThen(request, outcome -> {
			restore();
			Assert.equals("complete", outcome);
			Assert.equals(1, sent.length, "the request was not sent once");
			if (sent.length == 1) {
				var view:js.lib.Uint8Array = sent[0];
				Assert.equals(5, view.byteLength, "the body went out past its length");
				Assert.equals("hello", haxe.io.Bytes.ofData(view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength)).toString());
			}
			async.done();
		});
	}

	/**
		Wraps `XMLHttpRequest.prototype[name]` so `seen` is told of each call,
		with the request and its arguments, before the browser's own runs.
		Answers the function that puts the browser's back.
	**/
	private static function wrap(name:String, seen:(xhr:Dynamic, args:Array<Dynamic>) -> Void):Void->Void {
		var prototype:Dynamic = js.Syntax.code("XMLHttpRequest.prototype");
		var original:Dynamic = Reflect.field(prototype, name);
		Reflect.setField(prototype, name, js.Syntax.code("function() { {0}(this, Array.prototype.slice.call(arguments)); return {1}.apply(this, arguments); }",
			seen, original));
		return () -> Reflect.setField(prototype, name, original);
	}

	/** Loads `request` and calls `done` with "complete" or "error <text>", once. */
	private static function loadThen(request:URLRequest, done:String->Void):Void {
		var loader:URLLoader = new URLLoader();
		var settled:Bool = false;
		loader.addEventListener(Event.COMPLETE, _ -> {
			if (!settled) {
				settled = true;
				done("complete");
			}
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> {
			if (!settled) {
				settled = true;
				done("error " + event.text);
			}
		});
		loader.load(request);
	}
}
#end
