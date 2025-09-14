package crossbyte.url;

import crossbyte._internal.http.Http;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.sys.Worker;
import haxe.io.Bytes;

/**
 * ...
 * @author Christopher Speciale
 */
class URLLoader extends EventDispatcher {
	public var dataFormat:URLLoaderDataFormat = URLLoaderDataFormat.TEXT;
	public var bytesTotal:Int;
	public var bytesLoaded:Int;
	public var data:Dynamic;

	@:noCompletion private var __loaderWorker:Worker;
	@:noCompletion private var __busy:Bool = false;

	public function new() {
		super();
	}

	@:noCompletion private function __createURLLoaderWorker():Void {
		__loaderWorker = new Worker();
		__loaderWorker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__loaderWorker.addEventListener(ThreadEvent.PROGRESS, __onWorkerProgress);
		__loaderWorker.addEventListener(ThreadEvent.ERROR, __onWorkerError);
		__loaderWorker.doWork = __work;
	}

	@:noCompletion private function __onWorkerComplete(e:ThreadEvent):Void {
		var dataBytes:Bytes = e.message;
		data = (dataFormat == URLLoaderDataFormat.TEXT) ? dataBytes.getString(0, dataBytes.length) : dataBytes;
		dispatchEvent(new Event(Event.COMPLETE));
		__disposeWorker();
	}

	@:noCompletion private function __disposeWorker():Void {
		if (__loaderWorker == null) {
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

		switch (obj.type) {
			case "progress":
				bytesTotal = obj.value.bytesTotal;
				bytesLoaded = obj.value.bytesLoaded;
				dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, bytesTotal, bytesLoaded));
			case "status":
				dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, obj.value));
		}
	}

	@:noCompletion private function __onWorkerError(e:ThreadEvent):Void {
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, e.message));
		__disposeWorker();
	}

	private function __work(message:Dynamic):Void {
		var request:URLRequest = message.request;
		var df:URLLoaderDataFormat = message.dataFormat;

		// Build raw header strings
		var requestHeaders:Array<String> = [];
		for (header in request.requestHeaders) {
			requestHeaders.push(header.toString());
		}

		// Decide how to map request.data into Http args
		var requestData:Dynamic = null; // becomes query/form fields
		var contentType:Null<String> = null;
		var bodyData:Dynamic = null; // becomes raw request body

		if (request.data != null) {
			if (Std.isOfType(request.data, haxe.io.Bytes) || Std.isOfType(request.data, String)) {
				// Raw body mode
				bodyData = request.data;
				contentType = (request.contentType != null) ? request.contentType : "application/octet-stream";
			} else if (Reflect.isObject(request.data)) {
				// Form/urlencoded mode (Http will build body for non-GET)
				requestData = request.data;
				// optionally honor request.contentType if user provided one
				if (request.contentType != null)
					contentType = request.contentType;
			} else {
				// Fallback: stringify
				bodyData = Std.string(request.data);
				contentType = (request.contentType != null) ? request.contentType : "text/plain; charset=utf-8";
			}
		}

		var http:Http = new Http(request.url, request.method, requestHeaders, requestData, // 4th: requestData (for query/form)
			contentType, bodyData,
			HTTP_1_1, request.idleTimeout, request.userAgent, request.followRedirects);

		function onComplete(dataBytes:Bytes):Void {
			__loaderWorker.sendComplete(dataBytes);
		}
		function onProgress(loaded:Int, total:Int):Void {
			var obj = {type: "progress", value: {bytesLoaded: loaded, bytesTotal: total}};
			__loaderWorker.sendProgress(obj);
		}
		function onError(msg:String):Void {
			__loaderWorker.sendError(msg);
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
	}

	public function load(request:URLRequest):Void {
		if (__busy) {
			dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "URLLoader is already loading"));
			return;
		}
		__busy = true;
		__createURLLoaderWorker();
		__loaderWorker.run({
			"request": request,
			"dataFormat": dataFormat
		});
	}

	public function close():Void {
		if (__loaderWorker != null) {
			__loaderWorker.cancel(true);
			__disposeWorker();
		}
	}
}
