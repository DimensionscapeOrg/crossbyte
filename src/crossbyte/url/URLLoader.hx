package crossbyte.url;

// Built for every target. Off JavaScript a load runs CrossByte's own client on a pool thread (LoaderRun); on Node and in a browser it runs the platform's (JsHttpClient).

import crossbyte.http.HTTPCancelToken;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.HTTPStatusEvent;
#if !js
import crossbyte._internal.http.LoadPool;
import crossbyte.core.CrossByte;
import crossbyte.url._internal.LoaderRun;
#end
import haxe.io.Bytes;

/** Background-loading request helper with progress and status events. */
class URLLoader extends EventDispatcher {
	#if !js
	/**
	 * How many loads run at once, at most, across every `URLLoader` in the
	 * process. More wait their turn, in the order they were made. Defaults to
	 * 16.
	 *
	 * A load blocks a thread for as long as its server takes to answer, and
	 * the threads are shared and kept between loads rather than started for
	 * each. A program that holds many slow requests open at once -- long
	 * polls, say -- should raise this to at least that many, or later loads
	 * wait behind them.
	 */
	public static var maxConcurrentLoads(get, set):Int;

	private static inline function get_maxConcurrentLoads():Int {
		return LoadPool.maxThreads;
	}

	private static function set_maxConcurrentLoads(value:Int):Int {
		return LoadPool.maxThreads = value < 1 ? 1 : value;
	}
	#end

	public var dataFormat:URLLoaderDataFormat = URLLoaderDataFormat.TEXT;
	public var bytesTotal:Int;
	public var bytesLoaded:Int;
	public var data:Dynamic;

	#if !js
	// The load in progress, which what arrives from its thread is checked
	// against: one that close() or a later load() has replaced is over, and
	// what it still sends is dropped.
	@:noCompletion private var __load:Null<LoaderRun> = null;
	#end
	@:noCompletion private var __busy:Bool = false;

	/**
	 * Cancels the load in progress.
	 *
	 * A new one for each `load()`, on every target, so cancelling one load
	 * cannot touch the next. Cancelling it ends the request and the load
	 * fails with an `IO_ERROR` saying "Request cancelled"; `close()` cancels it
	 * too, and dispatches nothing. Natively it is handed to the thread the
	 * request runs on, which is why it is a token and not a handle `load()`
	 * returns: whoever cancels is on another thread. `close()` is the
	 * ordinary way to reach it; this is here for code that wants to cancel
	 * from somewhere else.
	 */
	public var cancelToken(default, null):HTTPCancelToken;

	public function new() {
		super();
	}

	/**
	 * `HTTP_RESPONSE_STATUS`, with what the response said: its headers, the URL
	 * it came from, and whether a redirect led there. It was never dispatched,
	 * so `Retry-After`, `ETag` and `Location` could not be read on any target.
	 */
	@:noCompletion private function __dispatchResponse(status:Int, headers:Array<URLRequestHeader>, url:String, redirected:Bool):Void {
		var event:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, status, redirected);
		event.responseHeaders = headers;
		event.responseURL = url;
		dispatchEvent(event);
	}

	/**
		Reads `dataBytes` into `data` as `dataFormat` says, and answers why it
		could not, or null when it could.

		A body that is not UTF-8 read as text threw -- on JavaScript a
		RangeError out of `getString` -- inside the loader's completion, which
		on Node ended the process. It is an `IO_ERROR` now, and `data` holds
		the bytes as they came. On JavaScript the text is read by the
		platform's decoder, which refuses any malformed sequence; Haxe's
		refused only some, and read the rest as other characters.
	**/
	@:noCompletion private function __parseData(dataBytes:Bytes):Null<String> {
		try {
			switch (dataFormat) {
				case URLLoaderDataFormat.TEXT:
					data = crossbyte._internal.Utf8.stringOf(dataBytes, 0, dataBytes.length, true);
				case URLLoaderDataFormat.BINARY:
					data = dataBytes;
				case URLLoaderDataFormat.VARIABLES:
					var s:String = crossbyte._internal.Utf8.stringOf(dataBytes, 0, dataBytes.length, true);
					data = new URLVariables(s);
			}
		} catch (error:Dynamic) {
			data = dataBytes;
			return "The response body could not be read as " + dataFormat + ": " + Std.string(error);
		}
		return null;
	}

	#if !js
	/**
	 * Delivers one message from `run`'s thread, on this loader's runtime.
	 * Answers whether `run` is still the load in progress.
	 */
	@:noCompletion private function __deliver(run:LoaderRun, message:LoaderMessage):Bool {
		if (run != __load) {
			return false;
		}

		switch (message) {
			case Progress(loaded, total):
				bytesTotal = total;
				bytesLoaded = loaded;
				dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, bytesLoaded, bytesTotal));
			case Status(code):
				dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, code));
			case Response(status, headers, url, redirected):
				__dispatchResponse(status, __headerList(headers), url, redirected);
			case Complete(bytes):
				// Free before the event, not after: a COMPLETE listener that
				// starts the next load on this loader was refused as busy.
				__finish();
				var unreadable:Null<String> = __parseData(bytes);
				if (unreadable != null) {
					dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, unreadable));
				} else {
					dispatchEvent(new Event(Event.COMPLETE));
				}
			case Failure(text, bytes):
				__finish();
				if (bytes != null) {
					__parseData(bytes);
				}
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, text));
		}
		return true;
	}

	@:noCompletion private function __finish():Void {
		__load = null;
		__busy = false;
	}

	/** Header fields as the client joined them, one field per value again. */
	@:noCompletion private static function __headerList(fields:Map<String, String>):Array<URLRequestHeader> {
		var list:Array<URLRequestHeader> = [];
		if (fields == null) {
			return list;
		}
		for (name => value in fields) {
			// Set-Cookie is joined with a newline, since a cookie's own
			// Expires holds commas; every other repeat with a comma, which
			// RFC 9110 5.3 makes equivalent.
			if (name == "set-cookie") {
				for (cookie in value.split("\n")) {
					list.push(new URLRequestHeader(name, cookie));
				}
			} else {
				list.push(new URLRequestHeader(name, value));
			}
		}
		return list;
	}
	#end

	public function load(request:URLRequest):Void {
		#if js
		if (__busy) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "URLLoader is already loading"));
			return;
		}

		__busy = true;
		// A fresh token per load, as natively. It is how a load is told apart
		// from the next: what one close() or a later load() has replaced
		// still reports as it winds down, and is dropped.
		var token:HTTPCancelToken = new HTTPCancelToken();
		cancelToken = token;

		// No worker: the runtime's own client is asynchronous, so there is no
		// blocking call here for one to keep off the loop.
		var finalStatus:Int = 0;
		crossbyte.url._internal.JsHttpClient.send(request, function(status:Int):Void {
			if (__isCurrent(token)) {
				dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, status));
			}
		}, function(loaded:Int, total:Int):Void {
			if (!__isCurrent(token)) {
				return;
			}
			bytesLoaded = loaded;
			bytesTotal = total;
			dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, loaded, total));
		}, function(dataBytes:Bytes):Void {
			if (!__isCurrent(token)) {
				return;
			}
			__busy = false;
			var unreadable:Null<String> = __parseData(dataBytes);
			// The native client's contract, and AS3's: a 4xx or 5xx is an
			// IO_ERROR, with its body in `data`. This completed, so one status
			// meant two outcomes depending on the target.
			if (finalStatus >= 400) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "HTTP error " + finalStatus));
				return;
			}
			if (unreadable != null) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, unreadable));
				return;
			}
			dispatchEvent(new Event(Event.COMPLETE));
		}, function(message:String):Void {
			if (!__isCurrent(token)) {
				return;
			}
			__busy = false;
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
		}, function(status:Int, headers:Array<URLRequestHeader>, url:String, redirected:Bool):Void {
			if (!__isCurrent(token)) {
				return;
			}
			finalStatus = status;
			__dispatchResponse(status, headers, url, redirected);
		}, token);
		#else
		if (__busy) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "URLLoader is already loading"));
			return;
		}
		// Taken here, on the thread whose runtime the events belong to, before
		// anything else can go wrong.
		var runtime:CrossByte = CrossByte.current();
		__busy = true;
		// A fresh token per load: cancelling one request must not poison the
		// next one this loader makes.
		cancelToken = new HTTPCancelToken();
		var run:LoaderRun = new LoaderRun(this, runtime, request, cancelToken);
		__load = run;
		LoadPool.run(run.execute);
		#end
	}

	#if js
	/** Whether the load `token` was made for is still the one in progress. */
	@:noCompletion private inline function __isCurrent(token:HTTPCancelToken):Bool {
		return __busy && cancelToken == token;
	}
	#end

	/**
	 * Ends the load in progress, on every target: its request is abandoned
	 * where it stands, which the server sees at once -- an HTTP/1.1
	 * connection is shut, an HTTP/2 stream reset -- and nothing more is
	 * dispatched for it. The loader is free for its next `load()` as soon as
	 * this returns.
	 */
	public function close():Void {
		#if js
		// Let go of before it is cancelled. The client reports a cancel at
		// once, from inside cancel(), and that report belongs to the load
		// being closed, so it is dropped with the rest of what it says. The
		// request itself is aborted: close() only stopped the next load being
		// refused as busy, and the closed one went on and delivered its
		// answer after the next one's.
		__busy = false;
		if (cancelToken != null) {
			cancelToken.cancel();
		}
		#else
		// Cancelled before it is let go of. The token reaches the request
		// itself -- an HTTP/2 stream is reset, freeing the slot it held on a
		// shared connection, and an HTTP/1.1 socket is shut down under its
		// blocking read. Abandoning the thread alone left the peer holding a
		// request nobody was coming back for.
		if (cancelToken != null) {
			cancelToken.cancel();
		}
		var run:Null<LoaderRun> = __load;
		__finish();
		if (run != null) {
			run.abandon();
		}
		#end
	}
}
