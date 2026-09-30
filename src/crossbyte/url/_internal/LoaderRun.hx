package crossbyte.url._internal;

// Not built for JavaScript, where a load is asynchronous and runs on no
// thread of its own: see JsHttpClient.
#if !js
import crossbyte._internal.http.Http;
import crossbyte.core.CrossByte;
import crossbyte.http.HTTPCancelToken;
import crossbyte.url.URLLoader;
import crossbyte.url.URLRequest;
import haxe.io.Bytes;
#if target.threaded
import sys.thread.Mutex;
#end

/** What a load's thread reports to its loader, in the order it happened. */
@:noCompletion
enum LoaderMessage {
	Progress(loaded:Int, total:Int);
	Status(code:Int);
	Response(status:Int, headers:Map<String, String>, url:String, redirected:Bool);
	Complete(bytes:Bytes);
	Failure(text:String, bytes:Null<Bytes>);
}

/**
 * One `load()`: the request, run on a pool thread, and what it reports on
 * its way back to the loader's runtime.
 *
 * Messages are queued here and delivered in batches through the runtime's
 * post queue -- one post per batch, when its first message arrives -- so a
 * download reporting progress per read costs a lock per read and a post per
 * runtime turn, not a post per read.
 */
@:noCompletion
@:access(crossbyte.url.URLLoader)
class LoaderRun {
	/** Messages delivered per runtime turn at most; the rest wait for the next. */
	private static inline var BATCH:Int = 256;

	private final __loader:URLLoader;
	private final __runtime:CrossByte;
	private final __request:URLRequest;
	private final __token:HTTPCancelToken;

	#if target.threaded
	private final __lock:Mutex = new Mutex();
	#end
	private var __outbox:Array<LoaderMessage> = [];
	private var __drainPosted:Bool = false;
	private var __abandoned:Bool = false;

	public function new(loader:URLLoader, runtime:CrossByte, request:URLRequest, token:HTTPCancelToken) {
		__loader = loader;
		__runtime = runtime;
		__request = request;
		__token = token;
	}

	/** Drops whatever this load still has to say. On the loader's runtime. */
	public function abandon():Void {
		__acquire();
		__abandoned = true;
		__outbox = [];
		__release();
	}

	/** The request itself, on a pool thread. */
	public function execute():Void {
		if (__token.cancelled) {
			// Closed before a thread took it.
			return;
		}

		try {
			var request:URLRequest = __request;

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

			var http:Http = new Http(request.url, request.method, requestHeaders, requestData, contentType, bodyData, request.httpVersion,
				request.idleTimeout, request.userAgent, request.followRedirects, request.manageCookies, request.followInsecureRedirects);

			// Created on the loader's thread before the load was queued, so
			// close() can reach a request that has already started.
			http.cancelToken = __token;
			http.maxDecompressedSize = request.maxDecompressedSize;

			// The last response's status and headers, reported once, ahead of
			// the outcome: a redirect's own block is not the answer.
			var finalStatus:Int = 0;
			var finalHeaders:Map<String, String> = null;
			function reportResponse():Void {
				if (finalHeaders != null) {
					__send(Response(finalStatus, finalHeaders, http.url, http.redirected));
				}
			}

			http.onComplete = dataBytes -> {
				reportResponse();
				__send(Complete(dataBytes));
			};
			http.onProgress = (loaded, total) -> __send(Progress(loaded, total));
			http.onError = (message, ?dataBytes) -> {
				reportResponse();
				__send(Failure(message, dataBytes));
			};
			http.onStatus = code -> {
				finalStatus = code;
				__send(Status(code));
			};
			http.onHeaders = headers -> finalHeaders = headers;

			http.load();
		} catch (e:Dynamic) {
			__send(Failure(Std.string(e), null));
		}
	}

	/** Queues `message` for the loader, posting a drain when it starts a batch. */
	private function __send(message:LoaderMessage):Void {
		__acquire();
		if (__abandoned) {
			__release();
			return;
		}
		__outbox.push(message);
		var post:Bool = !__drainPosted;
		__drainPosted = true;
		__release();

		if (post) {
			__runtime.post(__drain);
		}
	}

	/** On the loader's runtime: delivers what has arrived, in order. */
	private function __drain():Void {
		__acquire();
		var batch:Array<LoaderMessage>;
		var more:Bool = __outbox.length > BATCH;
		if (more) {
			batch = __outbox.splice(0, BATCH);
		} else {
			batch = __outbox;
			__outbox = [];
			// Emptied, so the next message posts the next drain.
			__drainPosted = false;
		}
		__release();

		for (message in batch) {
			// Checked per message: a listener may close the loader, or start
			// its next load, part way through a batch.
			if (!__loader.__deliver(this, message)) {
				abandon();
				return;
			}
		}

		if (more) {
			__runtime.post(__drain);
		}
	}

	private inline function __acquire():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	private inline function __release():Void {
		#if target.threaded
		__lock.release();
		#end
	}
}
#end
