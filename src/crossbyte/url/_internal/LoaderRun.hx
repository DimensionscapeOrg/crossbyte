package crossbyte.url._internal;

// Not built for JavaScript, where a load is asynchronous and runs on no
// thread of its own: see JsHttpClient.
#if !js
import crossbyte._internal.http.Http;
import crossbyte._internal.http.LoadPool;
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
 * post queue, one post per batch, when its first message arrives, so a
 * download reporting progress per read costs a lock per read and a post per
 * runtime turn, not a post per read.
 *
 * The load's deadlines that its thread cannot keep are kept here, on the
 * loader's runtime: `URLRequest.totalTimeout`, and the wait for a thread,
 * which `URLRequest.idleTimeout` bounds, a load still queued has no
 * thread to notice it has waited too long. Each is a runtime timer, armed
 * only when the load has one, and checked against `haxe.Timer.stamp()` when
 * it fires, so a runtime whose clock runs ahead of the wall's does not end a
 * load early.
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
	// Set, under the lock, once a thread has taken the load.
	private var __running:Bool = false;

	// The runtime timers keeping the deadlines, or -1, which no timer is,
	// and the deadlines they keep, by haxe.Timer.stamp(). On the runtime.
	private var __queueTimer:Int = -1;
	private var __totalTimer:Int = -1;
	private var __queueDeadline:Float = 0;
	private var __totalDeadline:Float = 0;

	public function new(loader:URLLoader, runtime:CrossByte, request:URLRequest, token:HTTPCancelToken) {
		__loader = loader;
		__runtime = runtime;
		__request = request;
		__token = token;
	}

	/**
		Queues the load for a thread, and arms the deadlines it has. On the
		loader's runtime.

		The wait for a thread is armed whether or not one is free: which
		thread takes a load is decided on the pool's threads, and a timer
		that finds its load running when it fires does nothing.
	**/
	public function start():Void {
		var now:Float = haxe.Timer.stamp();
		var total:Int = __request.totalTimeout;
		var idle:Int = __request.idleTimeout;
		if (idle > 0 && (total <= 0 || idle < total)) {
			__queueDeadline = now + idle / 1000.0;
			__armQueue();
		}
		if (total > 0) {
			__totalDeadline = now + total / 1000.0;
			__armTotal();
		}
		LoadPool.run(execute);
	}

	/** Drops whatever this load still has to say, and its deadlines. On the loader's runtime. */
	public function abandon():Void {
		__acquire();
		__abandoned = true;
		__outbox = [];
		__release();
		__disarm();
	}

	private function __armQueue():Void {
		__queueTimer = crossbyte.Timer.setTimeout(__queueDeadline - haxe.Timer.stamp(), __onQueueTimer);
	}

	private function __armTotal():Void {
		__totalTimer = crossbyte.Timer.setTimeout(__totalDeadline - haxe.Timer.stamp(), __onTotalTimer);
	}

	private function __onQueueTimer():Void {
		__queueTimer = -1;
		__acquire();
		var running:Bool = __running || __abandoned;
		__release();
		if (running || __loader.__load != this) {
			return;
		}
		if (haxe.Timer.stamp() < __queueDeadline) {
			// The runtime's clock is ahead of the wall's: not yet.
			__armQueue();
			return;
		}
		__expire("The load did not start within " + __request.idleTimeout + " ms: all " + LoadPool.maxThreads
			+ " of URLLoader.maxConcurrentLoads were busy with loads ahead of it");
	}

	private function __onTotalTimer():Void {
		__totalTimer = -1;
		if (__loader.__load != this) {
			return;
		}
		if (haxe.Timer.stamp() < __totalDeadline) {
			__armTotal();
			return;
		}
		__expire("The load did not complete within " + __request.totalTimeout + " ms");
	}

	/**
		Ends the load at a deadline: what its thread says from now on is
		dropped, its request is cancelled where it stands, the thread
		unwinds as it does for `close()`, and the loader is told.
	**/
	private function __expire(message:String):Void {
		abandon();
		__token.cancel();
		__loader.__deliver(this, Failure(message, null));
	}

	/** Clears the deadlines' timers that have not run. On the loader's runtime. */
	private function __disarm():Void {
		if (__queueTimer >= 0) {
			crossbyte.Timer.clear(__queueTimer);
			__queueTimer = -1;
		}
		if (__totalTimer >= 0) {
			crossbyte.Timer.clear(__totalTimer);
			__totalTimer = -1;
		}
	}

	/** The request itself, on a pool thread. */
	public function execute():Void {
		__acquire();
		__running = true;
		__release();
		if (__token.cancelled) {
			// Closed before a thread took it, or past a deadline.
			return;
		}

		try {
			var request:URLRequest = __request;

			// "Name: value", as HTTPRequestContext.headers promises a backend.
			// They went as URLRequestHeader.toString() writes them, with no
			// space, so a backend splitting at ": " as told found no value.
			var requestHeaders:Array<String> = [];
			for (header in request.requestHeaders) {
				requestHeaders.push(header.name + ": " + header.value);
			}

			var requestData:Dynamic = null;
			var contentType:Null<String> = null;
			// `URLRequest.data` is AIR's Object, told apart here once: a body
			// of text or bytes, typed from here on, or a form's fields.
			var bodyData:Null<crossbyte.http.HTTPRequestBody> = null;

			if (request.data != null) {
				if (Std.isOfType(request.data, haxe.io.Bytes) || Std.isOfType(request.data, String)) {
					bodyData = Std.isOfType(request.data, String) ? crossbyte.http.HTTPRequestBody.fromString(cast request.data) : crossbyte.http.HTTPRequestBody.fromBytes(cast request.data);
					contentType = (request.contentType != null) ? request.contentType : "application/octet-stream";
				} else if (Reflect.isObject(request.data)) {
					requestData = request.data;
					if (request.contentType != null) {
						contentType = request.contentType;
					}
				} else {
					bodyData = crossbyte.http.HTTPRequestBody.fromString(Std.string(request.data));
					contentType = (request.contentType != null) ? request.contentType : "text/plain; charset=utf-8";
				}
			}

			var http:Http = new Http(request.url, request.method, requestHeaders, requestData, contentType, bodyData, request.httpVersion,
				request.idleTimeout, request.userAgent, request.followRedirects, request.manageCookies, request.followInsecureRedirects);

			// Created on the loader's thread before the load was queued, so
			// close() can reach a request that has already started.
			http.cancelToken = __token;
			// The request's own limits, which were the client's statics, the
			// same for every request in the process.
			http.maxDecompressedSize = request.maxDecompressedSize;
			http.maxBodySize = request.maxBodySize;
			http.maxRedirects = request.maxRedirects;
			http.maxResponseHeaderSize = request.maxResponseHeaderSize;
			http.headTimeout = request.headTimeout;
			// Only when the request asks for something other than the defaults,
			// so the pool shares connections between requests that do not.
			var tls:crossbyte.http.HTTPTLSOptions = new crossbyte.http.HTTPTLSOptions(request.verifyCert, request.certAuthority,
				request.clientCertificate, request.clientKey, request.pinnedPublicKeys);
			http.tls = tls.isDefault() ? null : tls;

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

	/**
		Queues `message` for the loader, posting a drain when it starts a
		batch.

		Progress takes the place of progress not yet told: only the latest
		is worth telling, and the client reports it per read and per chunk,
		so a body arriving faster than the runtime drains, or while it is
		busy, queued a message for each, without bound: about 300,000 in
		two seconds for one load, measured. Nothing else is folded, nor the
		first report of a body, at nothing loaded, which is where a listener
		learns its total before any of it.
	**/
	private function __send(message:LoaderMessage):Void {
		__acquire();
		if (__abandoned) {
			__release();
			return;
		}
		var last:Int = __outbox.length - 1;
		if (last >= 0 && __isProgress(message) && __isLaterProgress(__outbox[last])) {
			// Not yet told, and a drain is posted for it already.
			__outbox[last] = message;
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
			switch (message) {
				case Complete(_) | Failure(_, _):
					// Over: its deadlines go before its outcome is told, so a
					// listener starting the next load cannot meet them.
					__disarm();
				default:
			}
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

	private static inline function __isProgress(message:LoaderMessage):Bool {
		return switch (message) {
			case Progress(_, _): true;
			default: false;
		}
	}

	/** Progress past the first report, which says nothing has loaded yet. **/
	private static inline function __isLaterProgress(message:LoaderMessage):Bool {
		return switch (message) {
			case Progress(loaded, _): loaded > 0;
			default: false;
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
