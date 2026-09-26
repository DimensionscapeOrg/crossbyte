package crossbyte.url;

// Not built for the browser. It loads over CrossByte's own raw-socket HTTP; a page issues requests through fetch or XMLHttpRequest, which is a separate implementation rather than a gate.

import crossbyte._internal.http.Http;
import crossbyte.http.HTTPCancelToken;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ThreadEvent;
#if !js
import crossbyte.sys.Worker;
#end
import haxe.io.Bytes;

/** Background-loading request helper with progress and status events. */
class URLLoader extends EventDispatcher {
	public var dataFormat:URLLoaderDataFormat = URLLoaderDataFormat.TEXT;
	public var bytesTotal:Int;
	public var bytesLoaded:Int;
	public var data:Dynamic;

	#if !js
	@:noCompletion private var __loaderWorker:Worker;
	#end
	@:noCompletion private var __busy:Bool = false;

	/**
	 * Cancels the load in progress.
	 *
	 * Created per `load()` and handed to the worker, because the request runs
	 * on a thread this one does not: by the time `load()` could return a
	 * handle the request would be over. `close()` is the ordinary way to reach
	 * it; this is here for code that wants to cancel from somewhere else.
	 */
	public var cancelToken(default, null):HTTPCancelToken;

	public function new() {
		super();
	}

	#if !js
	@:noCompletion private function __createURLLoaderWorker():Void {
		var worker:Worker = new Worker();
		worker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		worker.addEventListener(ThreadEvent.PROGRESS, __onWorkerProgress);
		worker.addEventListener(ThreadEvent.ERROR, __onWorkerError);
		// The thread reports through its own worker, never through
		// `__loaderWorker`: close() clears that field while the thread is
		// still running, and a report through it was a call on null, an
		// access violation on native. A cancelled worker drops what it is sent.
		worker.doWork = message -> __work(worker, message);
		__loaderWorker = worker;
	}

	@:noCompletion private function __onWorkerComplete(e:ThreadEvent):Void {
		var dataBytes:Bytes = e.message;
		__parseData(e.message);		

		dispatchEvent(new Event(Event.COMPLETE));
		__disposeWorker();
	}
	#end

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

	@:noCompletion private inline function __parseData(dataBytes:Bytes):Void {
		switch (dataFormat) {
			case URLLoaderDataFormat.TEXT:
				data = dataBytes.getString(0, dataBytes.length);
			case URLLoaderDataFormat.BINARY:
				data = dataBytes;
			case URLLoaderDataFormat.VARIABLES:
				var s:String = dataBytes.getString(0, dataBytes.length);
				data = new URLVariables(s);
		}
	}

	#if !js
	@:noCompletion private function __disposeWorker():Void {
		if (__loaderWorker == null) {
			__busy = false;
			return;
		}
		__loaderWorker.removeEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__loaderWorker.removeEventListener(ThreadEvent.PROGRESS, __onWorkerProgress);
		__loaderWorker.removeEventListener(ThreadEvent.ERROR, __onWorkerError);
		__loaderWorker.cancel();
		__loaderWorker = null;
		__busy = false;
	}

	@:noCompletion private function __onWorkerProgress(e:ThreadEvent):Void {
		var obj:Dynamic = e.message;
		if (obj == null || !Reflect.hasField(obj, "type")) {
			return;
		}

		switch (obj.type) {
			case "progress":
				bytesTotal = obj.value.bytesTotal;
				bytesLoaded = obj.value.bytesLoaded;
				dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, bytesLoaded, bytesTotal));
			case "status":
				dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, obj.value));
			case "response":
				__dispatchResponse(obj.value.status, __headerList(obj.value.headers), obj.value.url, obj.value.redirected);
		}
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

	@:noCompletion private function __onWorkerError(e:ThreadEvent):Void {
		var errorMessage:Dynamic = e.message;
		var dataBytes:Bytes = null;
		var message:String = Std.string(errorMessage);

		if (errorMessage != null && Reflect.isObject(errorMessage)) {
			if (Reflect.hasField(errorMessage, "dataBytes")) {
				dataBytes = Reflect.field(errorMessage, "dataBytes");
			}
			if (Reflect.hasField(errorMessage, "msg")) {
				message = Std.string(Reflect.field(errorMessage, "msg"));
			}
		}

		if (dataBytes != null) {
			__parseData(dataBytes);
		}

		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
		__disposeWorker();
	}

	private function __work(worker:Worker, message:Dynamic):Void {
		if (message == null) {
			// Cancelled before the thread started: the worker let go of it.
			return;
		}

		try {
			var request:URLRequest = message.request;

			var requestHeaders:Array<String> = [];
			for (header in request.requestHeaders) {
				requestHeaders.push(header.toString());
			}

			var requestData:Dynamic = null;
			var contentType:Null<String> = null;
			var bodyData:Dynamic = null;

			if (request.data != null) {
				if (Std.isOfType(request.data, haxe.io.Bytes) || Std.isOfType(request.data, String)) {
					bodyData = request.data;
					contentType = (request.contentType != null) ? request.contentType : "application/octet-stream";
				} else if (Reflect.isObject(request.data)) {
					requestData = request.data;
					if (request.contentType != null) {
						contentType = request.contentType;
					}
				} else {
					bodyData = Std.string(request.data);
					contentType = (request.contentType != null) ? request.contentType : "text/plain; charset=utf-8";
				}
			}

			var http:Http = new Http(request.url, request.method, requestHeaders, requestData, contentType, bodyData, request.httpVersion, request.idleTimeout,
				request.userAgent, request.followRedirects, request.manageCookies, request.followInsecureRedirects);

			// The token was created on the calling thread and travels with the
			// message, so close() can reach a request that has already started.
			if (message.cancelToken != null) {
				http.cancelToken = message.cancelToken;
			}

			// The last response's status and headers, reported once, ahead of
			// the outcome: a redirect's own block is not the answer.
			var finalStatus:Int = 0;
			var finalHeaders:Map<String, String> = null;
			function reportResponse():Void {
				if (finalHeaders != null) {
					worker.sendProgress({
						type: "response",
						value: {
							status: finalStatus,
							headers: finalHeaders,
							url: http.url,
							redirected: http.redirected
						}
					});
				}
			}

			function onComplete(dataBytes:Bytes):Void {
				reportResponse();
				worker.sendComplete(dataBytes);
			}
			function onProgress(loaded:Int, total:Int):Void {
				var obj = {type: "progress", value: {bytesLoaded: loaded, bytesTotal: total}};
				worker.sendProgress(obj);
			}
			function onError(msg:String, ?dataBytes:Bytes):Void {
				reportResponse();
				var errorMessage = {
					"msg":msg,
					"dataBytes":dataBytes
				};
				worker.sendError(errorMessage);
			}
			function onStatus(code:Int):Void {
				finalStatus = code;
				var obj = {type: "status", value: code};
				worker.sendProgress(obj);
			}

			http.onComplete = onComplete;
			http.onProgress = onProgress;
			http.onError = onError;
			http.onStatus = onStatus;
			http.onHeaders = headers -> finalHeaders = headers;

			http.load();
		} catch (e:Dynamic) {
			worker.sendError(e);
		}
	}
	#end

	public function load(request:URLRequest):Void {
		#if js
		if (__busy) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "URLLoader is already loading"));
			return;
		}

		__busy = true;

		// No worker: the runtime's own client is asynchronous, so there is no
		// blocking call here for one to keep off the loop.
		var finalStatus:Int = 0;
		crossbyte.url._internal.JsHttpClient.send(request, function(status:Int):Void {
			dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, status));
		}, function(loaded:Int, total:Int):Void {
			bytesLoaded = loaded;
			bytesTotal = total;
			dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, loaded, total));
		}, function(dataBytes:Bytes):Void {
			__busy = false;
			__parseData(dataBytes);
			// The native client's contract, and AS3's: a 4xx or 5xx is an
			// IO_ERROR, with its body in `data`. This completed, so one status
			// meant two outcomes depending on the target.
			if (finalStatus >= 400) {
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "HTTP error " + finalStatus));
				return;
			}
			dispatchEvent(new Event(Event.COMPLETE));
		}, function(message:String):Void {
			__busy = false;
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
		}, function(status:Int, headers:Array<URLRequestHeader>, url:String, redirected:Bool):Void {
			finalStatus = status;
			__dispatchResponse(status, headers, url, redirected);
		});
		#else
		if (__busy) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "URLLoader is already loading"));
			return;
		}
		__busy = true;
		// A fresh token per load: cancelling one request must not poison the
		// next one this loader makes.
		cancelToken = new HTTPCancelToken();
		__createURLLoaderWorker();
		__loaderWorker.run({
			"request": request,
			"dataFormat": dataFormat,
			"cancelToken": cancelToken
		});
		#end
	}

	public function close():Void {
		#if js
		// The request is the runtime's to cancel and it does not offer a handle
		// back, so this only stops a further load() being refused as busy. A
		// response still in flight is discarded when it arrives.
		__busy = false;
		#else
		// Cancelled before the worker is torn down. The token reaches the
		// request itself, an HTTP/2 stream is reset, freeing the slot it held
		// on a shared connection, and an HTTP/1.1 socket is closed out from
		// under its blocking read. Killing the worker alone left the peer
		// holding a request nobody was coming back for.
		if (cancelToken != null) {
			cancelToken.cancel();
		}

		if (__loaderWorker != null) {
			__loaderWorker.cancel(true);
			__disposeWorker();
		}
		#end
	}
}
