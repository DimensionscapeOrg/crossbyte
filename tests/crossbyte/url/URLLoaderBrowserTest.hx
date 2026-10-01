package crossbyte.url;

// A page only: the client under test is the browser's XMLHttpRequest.
#if (js && !nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.net.NetPump;
import crossbyte.url._internal.JsHttpClient;
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
		`close()` aborts the load in flight, and the next load is the only one
		heard from. It only stopped the next load being refused as busy: both
		requests went on, and the closed one's COMPLETE arrived beside the
		next one's.
	**/
	public function testClosingALoadAbortsItAndDropsItsAnswer(async:Async):Void {
		var aborted:Int = 0;
		var restore:Void->Void = wrap("abort", (_, _) -> aborted++);
		var loader:URLLoader = new URLLoader();
		var events:Array<String> = [];
		listen(loader, events);
		// The suite's own bundle, which is large, and then the page.
		loader.load(new URLRequest("/tests.js"));
		loader.close();
		loader.load(new URLRequest("/index.html"));

		// Pumped, not timed: the suite's runtime is the host's to drive, so
		// its timers run only as it is pumped.
		NetPump.until(() -> events.length > 0, 5.0, _ -> {
			// A second past the first answer, for any other to arrive.
			NetPump.wait(1.0, () -> {
				restore();
				Assert.equals(1, events.length, "a closed load was heard from: " + events.map(e -> e.substr(0, 40)));
				Assert.isTrue(events.length > 0 && events[0].indexOf("CrossByte portable suite") >= 0, "the answer was not the page's");
				Assert.equals(1, aborted, "the closed load's request was not aborted");
				async.done();
			});
		});
	}

	/**
		A load's `cancelToken` aborts it, and the load fails saying it was
		cancelled, as it does natively. There was no token in a page.
	**/
	public function testCancellingALoadsTokenAbortsIt(async:Async):Void {
		var aborted:Int = 0;
		var restore:Void->Void = wrap("abort", (_, _) -> aborted++);
		var loader:URLLoader = new URLLoader();
		var events:Array<String> = [];
		listen(loader, events);
		loader.load(new URLRequest("/tests.js"));
		if (loader.cancelToken == null) {
			restore();
			loader.close();
			Assert.fail("a load in a page has no cancelToken");
			async.done();
			return;
		}
		loader.cancelToken.cancel();
		NetPump.wait(0.5, () -> {
			restore();
			Assert.same(["IO_ERROR Request cancelled"], events);
			Assert.equals(1, aborted, "the cancelled load's request was not aborted");
			async.done();
		});
	}

	/**
		A request asking not to follow redirects is refused in a page, and
		nothing is sent: the browser follows every redirect itself and shows a
		page none of them. It went out, and came back as wherever a redirect
		led, where every other target hands the 3xx back.
	**/
	public function testARequestNotToFollowRedirectsIsRefused(async:Async):Void {
		var sent:Int = 0;
		var restore:Void->Void = wrap("send", (_, _) -> sent++);
		var request:URLRequest = new URLRequest("/index.html");
		request.followRedirects = false;
		loadThen(request, outcome -> {
			restore();
			Assert.isTrue(StringTools.startsWith(outcome, "error URLRequest.followRedirects = false is not available in a browser"), outcome);
			Assert.equals(0, sent, "a request the page could not honour was sent");
			async.done();
		});
	}

	/**
		A `userAgent` set is handed to the browser, which has the last word on
		it; it was not passed on at all. Unset, nothing is, and the browser's
		own goes.
	**/
	public function testAUserAgentSetIsHandedToTheBrowser(async:Async):Void {
		var named:Array<String> = [];
		// Kept from the browser's own: Chrome refuses the name and says so in
		// the console, which this suite takes for a failure.
		var restore:Void->Void = replace("setRequestHeader", (xhr, args, original) -> {
			if (Std.string(args[0]).toLowerCase() == "user-agent") {
				named.push(args[1]);
				return null;
			}
			return original.apply(xhr, args);
		});
		var request:URLRequest = new URLRequest("/index.html");
		request.userAgent = "Tester/1";
		loadThen(request, set -> {
			loadThen(new URLRequest("/index.html"), unset -> {
				restore();
				Assert.equals("complete", set);
				Assert.equals("complete", unset);
				Assert.same(["Tester/1"], named, "the userAgent set was not handed to the browser, once");
				async.done();
			});
		});
	}

	/**
		A coded body that the browser decoded past `maxDecompressedSize`
		fails the load, as it does natively and on Node, once the browser has
		shown it whole. The limit was not consulted in a page. The suite's
		server codes nothing, so the response is made to say it did.
	**/
	public function testABodyDecodedPastTheLimitFails(async:Async):Void {
		var restore:Void->Void = replace("getResponseHeader", (xhr, args, original) -> {
			return Std.string(args[0]).toLowerCase() == "content-encoding" ? "gzip" : original.apply(xhr, args);
		});
		var limited:URLRequest = new URLRequest("/index.html");
		limited.maxDecompressedSize = 16;
		loadThen(limited, refused -> {
			loadThen(new URLRequest("/index.html"), taken -> {
				restore();
				Assert.isTrue(StringTools.startsWith(refused, "error Failed to decode response body"), refused);
				Assert.equals("complete", taken, "the default limit refused a page");
				async.done();
			});
		});
	}

	/**
		A response the browser reached by a redirect from `https` to plain
		`http` is refused unless `followInsecureRedirects` allows it, as every
		other client refuses that hop. A page learns of the hop only once it
		has been made, from where the response says it came from.
	**/
	public function testARedirectToPlainHttpIsRefusedOnceSeen():Void {
		Assert.notNull(JsHttpClient.__followedRefusal("https://a.example/x", "http://a.example/y", false));
		Assert.isNull(JsHttpClient.__followedRefusal("https://a.example/x", "http://a.example/y", true));
		Assert.isNull(JsHttpClient.__followedRefusal("https://a.example/x", "https://b.example/y", false));
		Assert.isNull(JsHttpClient.__followedRefusal("http://a.example/x", "http://b.example/y", false));
		Assert.isNull(JsHttpClient.__followedRefusal("/relative", "/relative", false));
	}

	/** Records what `loader` dispatches into `events`, as "COMPLETE <data>" or "IO_ERROR <text>". */
	private static function listen(loader:URLLoader, events:Array<String>):Void {
		loader.addEventListener(Event.COMPLETE, _ -> events.push("COMPLETE " + Std.string(loader.data)));
		loader.addEventListener(IOErrorEvent.IO_ERROR, (event:IOErrorEvent) -> events.push("IO_ERROR " + event.text));
	}

	/**
		Wraps `XMLHttpRequest.prototype[name]` so `seen` is told of each call,
		with the request and its arguments, before the browser's own runs.
		Answers the function that puts the browser's back.
	**/
	private static function wrap(name:String, seen:(xhr:Dynamic, args:Array<Dynamic>) -> Void):Void->Void {
		return replace(name, (xhr, args, original) -> {
			seen(xhr, args);
			return original.apply(xhr, args);
		});
	}

	/**
		Puts `with` in place of `XMLHttpRequest.prototype[name]`. It is handed
		the request, the call's arguments and the browser's own method, to
		call or not, and what it answers is the call's. Answers the function
		that puts the browser's back.
	**/
	private static function replace(name:String, with:(xhr:Dynamic, args:Array<Dynamic>, original:Dynamic) -> Dynamic):Void->Void {
		var prototype:Dynamic = js.Syntax.code("XMLHttpRequest.prototype");
		var original:Dynamic = Reflect.field(prototype, name);
		Reflect.setField(prototype, name, js.Syntax.code("function() { return {0}(this, Array.prototype.slice.call(arguments), {1}); }", with, original));
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
