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
}
#end
