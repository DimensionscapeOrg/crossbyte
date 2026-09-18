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
		__loaderWorker = new Worker();
		__loaderWorker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__loaderWorker.addEventListener(ThreadEvent.PROGRESS, __onWorkerProgress);
		__loaderWorker.addEventListener(ThreadEvent.ERROR, __onWorkerError);
		__loaderWorker.doWork = __work;
	}

	@:noCompletion private function __onWorkerComplete(e:ThreadEvent):Void {
		var dataBytes:Bytes = e.message;
		__parseData(e.message);		

		dispatchEvent(new Event(Event.COMPLETE));
		__disposeWorker();
	}
	#end

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
		}
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

	private function __work(message:Dynamic):Void {
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
				request.userAgent, request.followRedirects, request.manageCookies);

			// The token was created on the calling thread and travels with the
			// message, so close() can reach a request that has already started.
			if (message.cancelToken != null) {
				http.cancelToken = message.cancelToken;
			}

			function onComplete(dataBytes:Bytes):Void {
				__loaderWorker.sendComplete(dataBytes);
			}
			function onProgress(loaded:Int, total:Int):Void {
				var obj = {type: "progress", value: {bytesLoaded: loaded, bytesTotal: total}};
				__loaderWorker.sendProgress(obj);
			}
			function onError(msg:String, ?dataBytes:Bytes):Void {
				var errorMessage = {
					"msg":msg,
					"dataBytes":dataBytes
				};
				__loaderWorker.sendError(errorMessage);
			}
			function onStatus(code:Int):Void {
				var obj = {type: "status", value: code};
				__loaderWorker.sendProgress(obj);
			}

			http.onComplete = onComplete;
			http.onProgress = onProgress;
			http.onError = onError;
			http.onStatus = onStatus;

			http.load();
		} catch (e:Dynamic) {
			__loaderWorker.sendError(e);
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
		crossbyte.url._internal.JsHttpClient.send(request, function(status:Int):Void {
			dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, status));
		}, function(loaded:Int, total:Int):Void {
			bytesLoaded = loaded;
			bytesTotal = total;
			dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, loaded, total));
		}, function(dataBytes:Bytes):Void {
			__busy = false;
			__parseData(dataBytes);
			dispatchEvent(new Event(Event.COMPLETE));
		}, function(message:String):Void {
			__busy = false;
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, message));
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
		// request itself -- an HTTP/2 stream is reset, freeing the slot it held
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
