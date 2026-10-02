package crossbyte._internal.http.h2;

// Needs threads, so not any JavaScript target. `HTTP2Backend` is gated the same
// way, for the socket rather than the threads.
#if !js
import crossbyte._internal.http.Http;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.http.HTTPCancelToken;
import crossbyte._internal.socket.FlexSocket;
import haxe.io.Bytes;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * One HTTP/2 connection shared by concurrent requests.
 *
 * This is what multiplexing costs. A single blocking client can own its
 * connection outright and read on the calling thread, but then only one
 * request uses it at a time -- which is HTTP/1.1 with extra framing. To carry
 * several at once, the reads have to belong to somebody, so a reader thread
 * owns them and every caller waits on its own stream.
 *
 * Two rules hold it together:
 *
 * - A mutex guards every mutation of the connection, including HPACK. The
 *   encoder's dynamic table evolves in the order blocks are written, so
 *   encoding and writing a header block must be one atomic step; two threads
 *   interleaving there desynchronizes the table from the peer's decoder and
 *   corrupts every later request on the connection, not just theirs.
 * - The reader thread never holds that mutex across a read. Blocking on the
 *   socket with the connection locked would stall every other stream for as
 *   long as the peer stayed quiet.
 *
 * Waiting is on `Lock`, never `Condition`: parking a thread on a condition
 * variable stalls the hxcpp collector, and a GC pause that only reproduces
 * under concurrent requests is not a thing anyone wants to debug twice.
 */
class H2ClientSession {
	/** Origin this session serves, as `scheme://host:port`. */
	public final origin:String;

	public final connection:H2Connection;

	/** Set once the connection is unusable and the pool should drop it. */
	public var dead(default, null):Bool = false;

	/**
		The TLS options the connection was opened under, null being the
		defaults; the pool shares it only with requests asking for the same.
	**/
	public final tls:Null<crossbyte.http.HTTPTLSOptions>;

	/** Requests currently in flight. */
	public var active(get, never):Int;

	private final __socket:FlexSocket;
	private final __lock:Mutex = new Mutex();
	private final __waiters:Map<Int, Lock> = new Map();

	// Request bodies being written, by stream. Each has its own wake-up, so a
	// cancel can wake the one it is for, and a processed frame wakes every
	// body waiting on a window rather than whichever one a single shared
	// release happened to reach.
	private final __uploads:Map<Int, H2Upload> = new Map();

	private var __activeStreams:Int = 0;
	// When the last stream in flight ended, or -1 while one is in flight. One
	// field rather than a count and a time, so a reader without the lock sees
	// one or the other and never half of each.
	private var __idleSince:Float = 0;
	private var __stopped:Bool = false;
	// Taken out of service by the pool as idle. Refuses new streams from then
	// on, which is what lets the pool close it without racing a request.
	private var __retired:Bool = false;
	private var __failure:String = null;
	// Set, under the lock, once the reader thread has left its loop. Until
	// then only the reader may close the socket: see close().
	private var __readerDone:Bool = false;

	public function new(origin:String, socket:FlexSocket, connection:H2Connection, ?tls:crossbyte.http.HTTPTLSOptions) {
		this.origin = origin;
		this.tls = tls;
		__socket = socket;
		this.connection = connection;

		connection.onStreamClosed = __onStreamClosed;
		connection.onWindowBlocked = __onWindowBlocked;

		__idleSince = haxe.Timer.stamp();

		connection.start();
		Thread.create(__read);
	}

	private inline function get_active():Int {
		return __activeStreams;
	}

	/**
	 * Seconds since this session last had a request in flight, or `-1` while
	 * one still is.
	 *
	 * A pooled connection is meant to outlive the request that opened it --
	 * that is the whole saving. What it must not do is outlive the program's
	 * interest in the host, holding a socket and a parked reader thread for a
	 * server nobody is talking to any more.
	 *
	 * Busy reports `-1` rather than `0` so the two cannot be confused: with a
	 * timeout of zero, "idle for no time at all" and "not idle" would
	 * otherwise both satisfy the same comparison, and a connection carrying a
	 * request would be closed under it.
	 */
	public function idleSeconds():Float {
		var since:Float = __idleSince;
		return since < 0 ? -1 : haxe.Timer.stamp() - since;
	}

	/**
	 * Takes this session out of service if it has had nothing in flight for
	 * at least `timeoutSeconds`, and says whether it did. The caller then
	 * closes it.
	 *
	 * Decided under the session's lock, which is the lock a request holds
	 * while it opens its stream. So a request starting at the same moment
	 * either opens its stream first, and the session is left alone, or finds
	 * the session retired and is refused before anything is sent.
	 *
	 * The pool asked `idleSeconds` instead, from outside the lock, and a
	 * request starting in between could be read half before and half after:
	 * nothing in flight, and idle since the clock began. That closed
	 * connections with a stream just opened on them.
	 *
	 * The lock is only tried. One that is held means the session is being
	 * used right now, and the pool must not wait on it: a request writing to
	 * a peer that has stopped reading holds it for as long as the peer likes,
	 * and the pool's own lock would be held all that while too.
	 */
	public function retireIfIdle(timeoutSeconds:Float):Bool {
		if (!__lock.tryAcquire()) {
			return false;
		}

		if (dead || __stopped || __retired || __activeStreams > 0 || haxe.Timer.stamp() - __idleSince < timeoutSeconds) {
			__lock.release();
			return false;
		}

		__retired = true;
		__lock.release();
		return true;
	}

	/**
	 * Whether another request may start now.
	 *
	 * A peer's SETTINGS_MAX_CONCURRENT_STREAMS is a limit on streams it will
	 * accept, not a suggestion: opening past it earns a REFUSED_STREAM, so a
	 * caller is better served by waiting or by a second connection.
	 */
	public function hasCapacity():Bool {
		if (dead || __stopped || __retired) {
			return false;
		}

		var limit:Int = connection.remoteSettings.maxConcurrentStreams;
		return limit < 0 || __activeStreams < limit;
	}

	/**
	 * Sends a request and waits for its response.
	 *
	 * Blocks the calling thread only on its own stream. Other requests on this
	 * connection continue while it waits, which is the point.
	 *
	 * `timeoutSeconds` is an idle limit: the longest the response may go with
	 * nothing arriving for it, and the longest a window may keep its body
	 * from going out. A response that keeps coming is waited for however
	 * long it takes. `0` or less is no limit: the request waits until its
	 * stream ends, it is cancelled, or the connection goes.
	 *
	 * `maxBodyLength` is the most response body the stream holds, `0` or
	 * less for none; absent, the connection's `maxResponseBodySize`.
	 */
	public function execute(method:String, scheme:String, authority:String, path:String, headers:Array<HpackHeader>, body:Null<Bytes>,
			timeoutSeconds:Float, ?cancelToken:HTTPCancelToken, ?maxBodyLength:Int):H2Stream {
		var target:H2Stream;
		var waiter:Lock = new Lock();
		var hasBody:Bool = body != null && body.length > 0;

		if (cancelToken != null && cancelToken.cancelled) {
			// Already abandoned. Opening a stream just to reset it would still
			// consume an id, and ids never come back.
			throw new H2ConnectionError(H2ErrorCode.CANCEL, "Request was cancelled before it started");
		}

		__lock.acquire();
		if (dead || __stopped || __retired) {
			// Refused before anything is sent, which is what REFUSED_STREAM
			// promises a caller (RFC 9113, 8.7): the request can go again.
			__lock.release();
			throw new H2ConnectionError(H2ErrorCode.REFUSED_STREAM, __failure != null ? __failure : "Connection is no longer usable");
		}

		try {
			target = connection.openStream(method, scheme, authority, path, headers, hasBody);
		} catch (e:Dynamic) {
			__lock.release();
			throw e;
		}
		// Before the lock is let go, so before any of the response is read.
		if (maxBodyLength != null) {
			target.maxBodyLength = maxBodyLength;
		}

		// Registered before the lock is dropped so the reader cannot close the
		// stream in the gap -- it needs this same lock to process a frame --
		// and before the body, whose write drops the lock while it waits on a
		// window.
		__waiters.set(target.id, waiter);
		__activeStreams++;
		__idleSince = -1;

		// Registered only now that the stream id exists, and before the lock
		// is dropped, for the waiter's reason: until then the reader cannot
		// process a frame for this stream, so a cancel from here on resets it
		// before any of its response can land. Registered after the lock, a
		// cancel in the gap found no handler to run, and the response could
		// complete the stream before the late registration reset it. Before
		// the body too: registered after it, a cancel during an upload
		// waiting on a window did nothing until the upload was over. A token
		// cancelled in the meantime runs this immediately, re-entering the
		// lock -- which is why `onCancel` fires late registrations rather than
		// dropping them.
		var streamId:Int = target.id;
		var onCancelled:Void->Void = () -> cancel(streamId);
		if (cancelToken != null) {
			cancelToken.onCancel(onCancelled);
		}

		var upload:Null<H2Upload> = null;
		if (hasBody) {
			// The timeout applies to the body too, as the longest a window may
			// stay shut: sending the body with no deadline at all let a peer
			// that stopped granting window hold the request forever on a
			// connection busy enough never to look stalled.
			upload = new H2Upload(timeoutSeconds);
			__uploads.set(streamId, upload);
			try {
				connection.sendBody(target, body);
			} catch (e:Dynamic) {
				__uploads.remove(streamId);
				__lock.release();
				__finish(streamId, cancelToken, onCancelled);
				throw e;
			}
			__uploads.remove(streamId);
		}

		var alreadyDone:Bool = target.isClosed();
		__lock.release();

		if (upload != null && upload.timedOut) {
			__finish(streamId, cancelToken, onCancelled);
			throw __timedOut(streamId, timeoutSeconds);
		}

		if (alreadyDone) {
			__finish(streamId, cancelToken, onCancelled);
			return target;
		}

		if (!__awaitEnd(target, waiter, timeoutSeconds)) {
			// The peer went quiet on it. The stream is reset rather than
			// abandoned: leaving it open holds a slot against
			// MAX_CONCURRENT_STREAMS for the life of the connection.
			__lock.acquire();
			try {
				connection.resetStream(target.id, H2ErrorCode.CANCEL);
			} catch (_:Dynamic) {}
			__lock.release();

			__finish(streamId, cancelToken, onCancelled);
			throw __timedOut(streamId, timeoutSeconds);
		}

		__finish(streamId, cancelToken, onCancelled);
		return target;
	}

	/**
	 * Waits for `target` to end for as long as its peer keeps sending it
	 * something, and gives up once it has sent nothing for `timeoutSeconds`.
	 * False when it gave up.
	 *
	 * An idle limit, as the HTTP/1.1 client's socket timeout is and Node's
	 * request timeout is. This waited `timeoutSeconds` once, from the start,
	 * so the same `idleTimeout` that let a large download over HTTP/1.1 run
	 * for as long as it kept moving cut it off over HTTP/2 however fast it
	 * was arriving.
	 *
	 * The reader counts the stream's frames rather than timing them, since a
	 * clock read per frame cost the frame path about 8% on small frames.
	 * This looks at the count four times per timeout, and a look that finds it
	 * moved starts the quiet period over from then. So the limit is never
	 * reached early, and at most a quarter of it late.
	 */
	private function __awaitEnd(target:H2Stream, waiter:Lock, timeoutSeconds:Float):Bool {
		if (timeoutSeconds <= 0) {
			// No limit. Each thing that wakes the waiter -- the stream ending,
			// a cancel, the connection going -- ends this wait. A limit of
			// zero was a wait of none, and failed every such request at once.
			waiter.wait();
			return true;
		}

		var slice:Float = timeoutSeconds / 4;
		__lock.acquire();
		var seen:Int = target.framesIn;
		__lock.release();
		var quietSince:Float = haxe.Timer.stamp();

		while (!waiter.wait(slice)) {
			__lock.acquire();
			var frames:Int = target.framesIn;
			var ended:Bool = target.isClosed();
			__lock.release();

			if (ended) {
				// Closed as the wait ran out, its wake-up not yet taken.
				return true;
			}

			var now:Float = haxe.Timer.stamp();
			if (frames != seen) {
				seen = frames;
				quietSince = now;
			} else if (now - quietSince >= timeoutSeconds) {
				return false;
			}
		}
		return true;
	}

	/**
	 * A stream error, not a connection error: the stream has been reset and
	 * the connection carries on. As a connection error it took the whole
	 * pooled connection down, and every other request on it, for one request
	 * that took too long.
	 */
	private function __timedOut(streamId:Int, timeoutSeconds:Float):H2StreamError {
		return new H2StreamError(streamId, H2ErrorCode.CANCEL, 'Request to $origin timed out after ${timeoutSeconds}s');
	}

	private function __finish(streamId:Int, cancelToken:Null<HTTPCancelToken>, onCancelled:Void->Void):Void {
		if (cancelToken != null) {
			// The request is over; the token must not keep a handler pointing
			// at a stream id that will be reused by nobody but is still dead
			// weight on a long-lived token.
			cancelToken.removeHandler(onCancelled);
		}
		__release(streamId);
	}

	/**
	 * Abandons one stream without disturbing the connection.
	 *
	 * RST_STREAM rather than a close: the connection is shared, so tearing it
	 * down would cancel every other request on it too. Safe from any thread,
	 * and safe on a stream that has already finished -- the reset is simply
	 * not sent.
	 *
	 * Decided under the lock the reader takes to process a frame. Once this
	 * has run, the stream is closed and whatever the peer sends for it is
	 * discarded, so a response arriving after a cancel cannot complete the
	 * request it was for.
	 */
	public function cancel(streamId:Int):Void {
		__lock.acquire();
		if (!dead && !__stopped) {
			try {
				// Fires onStreamClosed on the way through, which is what wakes
				// the caller blocked in execute().
				connection.resetStream(streamId, H2ErrorCode.CANCEL);
			} catch (_:Dynamic) {}
		}

		var waiter:Null<Lock> = __waiters.get(streamId);
		var upload:Null<H2Upload> = __uploads.get(streamId);
		__lock.release();

		// Released outside the lock, and unconditionally: a stream already
		// closed by the peer has no waiter left to wake, and one whose reset
		// failed still has a caller who must not wait out its timeout.
		if (waiter != null) {
			waiter.release();
		}
		// A body still going out may be waiting on a window, which nothing
		// else would open: it finds its stream closed when this wakes it.
		if (upload != null) {
			upload.wake.release();
		}
	}

	/**
		Ends the session: a GOAWAY, then the socket shut down, which ends the
		reader's read; the reader closes the socket on its way out, or this
		does when the reader has gone already.

		The socket was closed here, from whichever thread closed the session
		-- the pool's sweep, a request discarding it, `closeAll` -- while the
		reader sat in a read on it. For TLS that freed the socket's mbedTLS
		context under the read, and when the read returned, with the peer
		answering the GOAWAY, mbedTLS carried on with the freed context: a
		SIGSEGV in `mbedtls_ssl_read`, on Linux, reached from any pool close
		with a session open. `Http.__interrupt` is what the HTTP/1.1 client
		does for the same reason. On Windows a TLS socket's read is ended by
		the peer answering the shutdown, as it is there for a cancelled load.
	**/
	public function close():Void {
		__lock.acquire();
		if (__stopped) {
			__lock.release();
			return;
		}
		__stopped = true;

		try {
			connection.goAway(H2ErrorCode.NO_ERROR);
		} catch (_:Dynamic) {}

		// Decided under the lock the reader takes on its way out, so exactly
		// one of the two closes the socket; and closed under it, which a
		// writer holds while it writes.
		var readerGone:Bool = __readerDone;
		if (readerGone) {
			__closeSocket();
		}
		__lock.release();

		if (!readerGone) {
			Http.__interrupt(__socket);
		}

		__wakeEveryone();
	}

	private function __closeSocket():Void {
		try {
			__socket.close();
		} catch (_:Dynamic) {}
	}

	// ----------------------------------------------------------- reader

	private function __read():Void {
		__readFrames();

		__lock.acquire();
		__readerDone = true;
		if (__stopped) {
			// close() left the socket to this thread, which was in a read on it.
			__closeSocket();
		}
		__lock.release();
	}

	private function __readFrames():Void {
		while (true) {
			var frame:Null<H2Frame>;

			// Deliberately outside the lock. This is the blocking call, and
			// holding the connection across it is exactly the stall this class
			// exists to avoid.
			try {
				frame = connection.readFrame();
			} catch (e:Dynamic) {
				__fail("Connection failed: " + Std.string(e));
				return;
			}

			if (frame == null) {
				__fail("Connection closed by peer");
				return;
			}

			__lock.acquire();
			var failure:String = null;
			try {
				connection.processFrame(frame);
			} catch (e:H2ConnectionError) {
				failure = e.message;
			} catch (e:Dynamic) {
				failure = Std.string(e);
			}
			// Any frame may have opened a window, or ended a stream whose body
			// is still waiting on one.
			for (upload in __uploads) {
				if (upload.blocked) {
					upload.wake.release();
				}
			}
			__lock.release();

			if (failure != null) {
				__fail(failure);
				return;
			}

			if (__stopped) {
				return;
			}
		}
	}

	private function __onStreamClosed(target:H2Stream):Void {
		var waiter:Null<Lock> = __waiters.get(target.id);
		if (waiter != null) {
			waiter.release();
		}
	}

	/**
	 * Waits for the reader to make progress while a window is closed, for no
	 * longer than what is left of the request's timeout.
	 *
	 * The lock is dropped across the wait and retaken after. Holding it would
	 * deadlock outright: the WINDOW_UPDATE that would release this thread can
	 * only be processed by the reader, and the reader needs this lock.
	 *
	 * The timeout is the longest the window may stay shut, so an upload that
	 * is slow but moving is not cut off. Once it has passed, only this stream
	 * is reset; the body's write sees it closed and stops. This used to wait
	 * for any frame at all, thirty seconds at a time: on a busy connection a
	 * body the peer had stopped taking waited forever, and on a quiet one the
	 * thirty seconds failed the connection and every request on it.
	 */
	private function __onWindowBlocked(target:H2Stream, stalledSeconds:Float):Bool {
		if (dead || __stopped) {
			return false;
		}

		var upload:Null<H2Upload> = __uploads.get(target.id);
		if (upload == null) {
			return false;
		}

		// A timeout of 0 or less is none: the window may stay shut for as long
		// as the connection lasts, and the wait ends only on a frame, a
		// cancel or the connection going.
		var limited:Bool = upload.timeout > 0;
		var remaining:Float = upload.timeout - stalledSeconds;
		if (limited && remaining <= 0) {
			upload.timedOut = true;
			try {
				connection.resetStream(target.id, H2ErrorCode.CANCEL);
			} catch (_:Dynamic) {}
			return true;
		}

		upload.blocked = true;
		__lock.release();
		if (limited) {
			upload.wake.wait(remaining);
		} else {
			upload.wake.wait();
		}
		__lock.acquire();
		upload.blocked = false;

		return !dead && !__stopped;
	}

	private function __fail(reason:String):Void {
		__lock.acquire();
		if (__failure == null) {
			__failure = reason;
		}
		dead = true;
		__lock.release();

		__wakeEveryone();
	}

	/**
	 * Wakes every waiter, so a dead connection surfaces as a failed request
	 * rather than as one that waits out its whole timeout.
	 */
	private function __wakeEveryone():Void {
		__lock.acquire();
		var waiting:Array<Lock> = [];
		for (waiter in __waiters) {
			waiting.push(waiter);
		}
		for (upload in __uploads) {
			waiting.push(upload.wake);
		}
		__lock.release();

		for (waiter in waiting) {
			waiter.release();
		}
	}

	private function __release(streamId:Int):Void {
		__lock.acquire();
		if (__waiters.remove(streamId)) {
			__activeStreams--;
		}
		if (__activeStreams <= 0) {
			// Stamped as the last stream leaves, so the idle clock measures
			// time with nothing in flight rather than time since the
			// connection opened.
			__idleSince = haxe.Timer.stamp();
		}
		__lock.release();
	}
}

/** A request body being written, and what it needs to wait on a window. */
private class H2Upload {
	/** Released for every frame processed while `blocked`, and by a cancel. */
	public final wake:Lock = new Lock();

	/** The longest the window may stay shut, in seconds. */
	public final timeout:Float;

	/** Set, under the session's lock, while the write waits on `wake`. */
	public var blocked:Bool = false;

	/** Set when the window stayed shut for the whole timeout. */
	public var timedOut:Bool = false;

	public function new(timeout:Float) {
		this.timeout = timeout;
	}
}
#end
