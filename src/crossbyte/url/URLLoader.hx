package crossbyte.url;

import crossbyte.Object;
import crossbyte._internal.http.Http;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.sys.Worker;
import crossbyte.url.URLRequestHeader;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;
import haxe.io.Bytes;

/**
 * ...
 * @author Christopher Speciale
 */
class URLLoader extends EventDispatcher {
	public var dataFormat:String = URLLoaderDataFormat.TEXT;
	public var bytesTotal(get, null):Int;
	public var bytesLoaded(get, null):Int;
	public var data(get, null):Dynamic;

	private var __data:Bytes = null;
	private var __bytesTotal:Int;
	private var __bytesLoaded:Int;

	private var __loaderWorker:Worker;

	public function new() {
		super();
	}

	private function __createURLLoaderWorker():Void {
		__loaderWorker = new Worker();
		__loaderWorker.addEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__loaderWorker.addEventListener(ThreadEvent.PROGRESS, __onWorkerProgress);
		__loaderWorker.addEventListener(ThreadEvent.ERROR, __onWorkerError);
		__loaderWorker.doWork = __work;
	}

	private function __onWorkerComplete(e:ThreadEvent):Void {
		__data = e.message;
		dispatchEvent(new Event(Event.COMPLETE));
		__disposeWorker();
	}

	private function __disposeWorker():Void {
		__loaderWorker.removeEventListener(ThreadEvent.COMPLETE, __onWorkerComplete);
		__loaderWorker.removeEventListener(ThreadEvent.PROGRESS, __onWorkerProgress);
		__loaderWorker.removeEventListener(ThreadEvent.ERROR, __onWorkerError);
		__loaderWorker.cancel();
		__loaderWorker = null;
	}

	private function __onWorkerProgress(e:ThreadEvent):Void {
		var obj:Dynamic = e.message;

		switch (obj.type) {
			case "progress":
				__bytesTotal = obj.value.bytesTotal;
				__bytesLoaded = obj.value.bytesLoaded;
				dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, __bytesTotal, __bytesLoaded));
			case "status":
				dispatchEvent(new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, obj.value));
		}
	}

	private function __onWorkerError(e:ThreadEvent):Void {
		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, e.message));
		__disposeWorker();
	}

	private function __work(message:Dynamic):Void {
		var request:URLRequest = message.request;
		var dataFormat:URLLoaderDataFormat = message.dataFormat;
		var requestHeaders:Array<String> = [];

		for (header in request.requestHeaders) {
			requestHeaders.push(header.toString());
		}

		var http:Http = new Http(request.url, request.method, requestHeaders, request.data, null, null, HTTP_1_1, 15000, request.userAgent,
			request.followRedirects);

		function onComplete(data:Bytes):Void {
			__loaderWorker.sendComplete(data);
		}

		function onProgress(bytesLoaded, bytesTotal):Void {
			var valueObj:Dynamic = {};
			valueObj.bytesLoaded = bytesLoaded;
			valueObj.bytesTotal = bytesTotal;

			var obj:Dynamic = {};
			obj.type = "progress";
			obj.value = valueObj;

			__loaderWorker.sendProgress(obj);
		}

		function onError(errorMessage:String):Void {
			__loaderWorker.sendError(errorMessage);
		}

		function onStatus(statusCode:Int):Void {
			var obj:Dynamic = {};
			obj.type = "status";
			obj.value = statusCode;
			__loaderWorker.sendProgress(obj);
		}

		http.onComplete = onComplete;
		http.onProgress = onProgress;
		http.onError = onError;
		http.onStatus = onStatus;

		http.load();
	}

	public function load(request:URLRequest):Void {
		__createURLLoaderWorker();

		__loaderWorker.run({
			"request": request,
			"dataFormat": dataFormat
		});
	}

	public function close():Void {}

	private function get_bytesTotal():Int {
		return __bytesTotal;
	}

	private function get_bytesLoaded():Int {
		return __bytesLoaded;
	}

	private function get_data():Dynamic {
		if (dataFormat == URLLoaderDataFormat.BINARY) {
			// Return a ByteArray
			return __data; // _dataBytes;
		} else if (dataFormat == URLLoaderDataFormat.TEXT) {
			// Return a String
			return __data.getString(0, __data.length); // _data;
		}

		return null;
	}
}
