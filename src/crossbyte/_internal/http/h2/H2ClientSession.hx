package crossbyte._internal.http.h2;

// Needs threads, so not any JavaScript target. `HTTP2Backend` is gated the same
// way, for the socket rather than the threads.
#if !js
import crossbyte._internal.http.Http;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte.http.HTTPCancelToken;
import crossbyte._internal.socket.FlexSocket;
import haxe.io.Bytes;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * One HTTP/2 connection shared by concurrent requests.
 *
 * This is what multiplexing costs. A single blocking client can own its
 * connection outright and read on the calling thread, but then only one
 * request uses it at a time, which is HTTP/1.1 with extra framing. To carry
 * several at once, the reads have to belong to somebody, so a reader thread
 * owns them and every caller waits on its own stream.
 *
 * Three rules hold it together:
 *
 * - A mutex guards every mutation of the connection, including HPACK. The
 *   encoder's dynamic table evolves in the order blocks are queued, so
 *   encoding and queueing a header block must be one atomic step; two threads
 *   interleaving there desynchronizes the table from the peer's decoder and
 *   corrupts every later request on the connection, not just theirs.
 * - Nothing holds that mutex across the socket. The reader thread reads
 *   outside it, and what the connection queues (`H2Connection.deferWrites`)
 *   is written outside it, in the order it was queued, by whichever thread
 *   holds the write: the session's writer thread, the reader writing its
 *   own answers, or a request with no body writing its own head while the
 *   writer watches it. Every write was made where its frame was made, under
 *   the mutex: a server that stopped reading held that thread in the write
 *   for good, and the mutex with it, so no request on the connection reached
 *   its timeout, a cancel waited with them, on whatever thread made it,
 *   and so did a close.
 * - No caller waits on the socket past its own deadline: a request waits on
 *   its stream, a body on a window or on its queued frames going out, a
 *   request's own head is watched, and every one of those waits has the
 *   request's deadline or none, as the request asked. A request whose
 *   deadline passes while a write has been held up that long gives the
 *   connection up, a cancel gives its own held head `CLOSE_GRACE`, and a
 *   closed connection whose last write does not go out is given up
 *   `CLOSE_GRACE` after it closed.
 *
 * Waiting is on `H2Wake`, a `Lock`, or on eval a `Semaphore`, never
 * `Condition`: parking a thread on a condition variable stalls the hxcpp
 * collector, and a GC pause that only reproduces under concurrent requests
 * is not a thing anyone wants to debug twice.
 */
class H2ClientSession {
	/**
		Seconds a closed session's writer has to send what was queued before
		it, its GOAWAY last, before the connection is ended under it.
	**/
	public static inline var CLOSE_GRACE:Float = 1.0;

	/**
		Bytes of answers the peer obliged, PING and SETTINGS acknowledgements,
		WINDOW_UPDATEs, that may wait unwritten before the reader stops
		reading until they have gone (`H2Connection.queuedReplyBytes`). A peer
		that sends those and reads nothing is then stopped by its own socket,
		and holds no more of this side than this.
	**/
	public static inline var MAX_QUEUED_REPLIES:Int = 64 * 1024;

	/** Frames smaller than this are gathered into one write. */
	private static inline var GATHER_LIMIT:Int = 16 * 1024;

	// Whether a request with no body writes its own head. Not on eval, where
	// the writer's watch would be a timed wait, which there looks for a
	// release once a millisecond (H2Wake), and where the hand-off it saves is
	// the least of what a request costs.
	private static inline var DIRECT_HEADS:Bool = #if eval false #else true #end;

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
	private final __waiters:Map<Int, H2Wake> = new Map();

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
	// Set by retire() while streams are still in flight: the last of them to
	// end closes the session.
	private var __closeWhenIdle:Bool = false;
	private var __failure:String = null;

	// The reader and the writer each own one direction of the socket. The
	// socket is closed by whichever of them leaves last, under the lock,
	// never while the other may still be in a call on it, which for TLS frees
	// the mbedTLS context under that call.
	private var __threadsRunning:Int = 2;
	private var __socketClosed:Bool = false;
	// Set once the socket has been shut down to end the reader's read and any
	// write the peer is not taking.
	private var __interrupted:Bool = false;

	// Released for every batch queued; the writer waits on it.
	private final __writerWake:H2Wake = new H2Wake();
	// Held, under the lock, by whichever thread is writing the socket, the
	// writer, the reader writing its own answers, or a request writing its
	// own head, so one writes at a time, in the order frames were queued.
	private var __writing:Bool = false;
	// The stream whose request is writing its own head, or -1, and the
	// longest that write may go without progress before the writer, which
	// watches it, gives the connection up: the request's timeout, cut to
	// CLOSE_GRACE by a cancel, and 0 for none.
	private var __directStream:Int = -1;
	private var __directLimit:Float = 0;
	// The limit the connection was given up for, when it was given up for
	// taking nothing: what a request held up by it reports.
	private var __stalledLimit:Float = -1;
	// When the write under way began, or -1 between writes. Written by the
	// thread holding the write, read by anyone: one field, so a reader
	// without the lock sees one value or the other.
	private var __writingSince:Float = -1;
	// Released by the writer as it takes a batch, for a reader waiting on its
	// answers to go (MAX_QUEUED_REPLIES).
	private final __drained:H2Wake = new H2Wake();
	private var __readerWaiting:Bool = false;
	private var __closedAt:Float = -1;

	public function new(origin:String, socket:FlexSocket, connection:H2Connection, ?tls:crossbyte.http.HTTPTLSOptions) {
		this.origin = origin;
		this.tls = tls;
		__socket = socket;
		this.connection = connection;

		connection.onStreamClosed = __onStreamClosed;
		connection.onWindowBlocked = __onWindowBlocked;
		connection.deferWrites = true;

		__idleSince = haxe.Timer.stamp();

		__noteThreads(2);
		connection.start();
		Thread.create(__read);
		Thread.create(__write);
		__writerWake.release();
	}

	private inline function get_active():Int {
		return __activeStreams;
	}

	/**
	 * Seconds since this session last had a request in flight, or `-1` while
	 * one still is.
	 *
	 * A pooled connection is meant to outlive the request that opened it,
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
	 * used right now, and the pool, which holds its own lock here, has no
	 * reason to wait for it.
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
		if (dead || __stopped || __retired || goingAway) {
			return false;
		}

		var limit:Int = connection.remoteSettings.maxConcurrentStreams;
		return limit < 0 || __activeStreams < limit;
	}

	/**
		Whether the peer has sent GOAWAY: it takes no new stream here, and
		answers the ones it has (RFC 9113 6.8). The pool takes such a session
		out of service with `retire`, so a new request goes to another
		connection rather than being refused by this one.
	**/
	public var goingAway(get, never):Bool;

	private inline function get_goingAway():Bool {
		return connection.goAwayCode != null;
	}

	/**
		Takes this session out of service without cutting short what it
		carries: it refuses new streams from now on, and closes once the last
		stream in flight has ended, at once if none is, or if it is dead.

		What a session the peer has sent GOAWAY needs. Closed as soon as a new
		request was refused on it, it took every request still in flight on it
		down too, each failing as "connection closed before the response
		headers arrived" though the peer was answering it: 42 of 12,001 from
		eight concurrent clients when CrossByte's own server ended a
		connection after every thousandth request.
	**/
	public function retire():Void {
		__lock.acquire();
		__retired = true;
		var now:Bool = dead || __stopped || __activeStreams <= 0;
		if (!now) {
			__closeWhenIdle = true;
		}
		__lock.release();
		if (now) {
			close();
		}
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
		var waiter:H2Wake = new H2Wake();
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
		if (__stalledFor(timeoutSeconds)) {
			// The peer has taken nothing for longer than this request would
			// wait, so it would only time out behind what is queued. Given up
			// here, and refused, so it goes again on another connection.
			__lock.release();
			__giveUp(timeoutSeconds);
			throw new H2ConnectionError(H2ErrorCode.REFUSED_STREAM, 'Connection to $origin stopped taking writes');
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
		// stream in the gap, it needs this same lock to process a frame,
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
		// lock, which is why `onCancel` fires late registrations rather than
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
				__writerWake.release();
				__finish(streamId, cancelToken, onCancelled);
				throw e;
			}
			__uploads.remove(streamId);
		}

		var alreadyDone:Bool = target.isClosed();
		// A request with no body writes its head itself when no one else is
		// writing: handed to the writer thread, the hand-off was most of
		// what a request cost on a fast link. The writer watches the write
		// instead, so a peer that does not take it holds this thread no
		// longer than the request's timeout, or a cancel's grace.
		var direct:Null<Array<Bytes>> = null;
		if (DIRECT_HEADS && !hasBody && !__writing && !dead) {
			direct = connection.takeOutbox();
			if (direct != null) {
				__writing = true;
				__directStream = streamId;
				__directLimit = timeoutSeconds > 0 ? timeoutSeconds : 0;
			}
		}
		__lock.release();
		// The head, and whatever of the body is left, to the writer, or,
		// written here, for the writer to watch.
		__writerWake.release();
		if (direct != null) {
			var failure:Null<String> = __writeDirect(direct);
			if (failure != null) {
				// Given up by the writer, for this request's own timeout or a
				// cancel's grace, or the connection failed under the write.
				__finish(streamId, cancelToken, onCancelled);
				if (cancelToken != null && cancelToken.cancelled) {
					throw new H2ConnectionError(H2ErrorCode.CANCEL, "Request was cancelled");
				}
				if (timeoutSeconds > 0 && __stalledLimit >= timeoutSeconds) {
					throw __timedOut(streamId, timeoutSeconds);
				}
				throw new H2ConnectionError(H2ErrorCode.INTERNAL_ERROR, __failure != null ? __failure : failure);
			}
		}

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
			__writerWake.release();
			if (__stalledFor(timeoutSeconds)) {
				// And it has taken nothing all that while either: the
				// connection goes too, rather than wait on for the next
				// request to find it so.
				__giveUp(timeoutSeconds);
			}

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
	private function __awaitEnd(target:H2Stream, waiter:H2Wake, timeoutSeconds:Float):Bool {
		if (timeoutSeconds <= 0) {
			// No limit. Each thing that wakes the waiter, the stream ending,
			// a cancel, the connection going, ends this wait. A limit of
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
	 * and safe on a stream that has already finished, the reset is simply
	 * not sent.
	 *
	 * Decided under the lock the reader takes to process a frame. Once this
	 * has run, the stream is closed and whatever the peer sends for it is
	 * discarded, so a response arriving after a cancel cannot complete the
	 * request it was for.
	 *
	 * Never waits on the peer: the RST_STREAM is queued for the writer, and
	 * the request's own thread is woken to report the cancel.
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

		var waiter:Null<H2Wake> = __waiters.get(streamId);
		var upload:Null<H2Upload> = __uploads.get(streamId);
		if (__writing && __directStream == streamId) {
			// Its own thread is writing its head, which a peer not reading
			// can hold: the writer gives that write CLOSE_GRACE from now, if
			// it had longer.
			var since:Float = __writingSince;
			var limit:Float = CLOSE_GRACE + (since >= 0 ? haxe.Timer.stamp() - since : 0);
			if (__directLimit <= 0 || __directLimit > limit) {
				__directLimit = limit;
			}
		}
		__lock.release();
		__writerWake.release();

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
		Ends the session, without waiting on the peer: a GOAWAY is queued
		behind whatever was, and once it is written the writer shuts the
		socket down, which ends the reader's read; whichever of the two
		leaves last closes the socket. A write the peer keeps from going out
		has `CLOSE_GRACE`, and is then ended by the shutdown.

		The socket was closed here, from whichever thread closed the session,
		the pool's sweep, a request discarding it, `closeAll`, while the
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
		__closedAt = haxe.Timer.stamp();

		try {
			connection.goAway(H2ErrorCode.NO_ERROR);
		} catch (_:Dynamic) {}
		var running:Bool = __threadsRunning > 0;
		__lock.release();

		__writerWake.release();
		if (running) {
			__watchClosing(this);
		}
		__wakeEveryone();
	}

	/**
		Shuts the socket down, once, unless both threads have left already:
		what ends the reader's read, and, with `endWrite`, for a write the
		peer is not taking, the writer's.

		On the jvm and eval a write still under way is ended by closing the
		socket. A shutdown does not end one already waiting on Windows there,
		the JDK signals the writing thread only on POSIX, and eval shuts
		only a socket's writing side there, and closing under a call is
		safe on both: the call fails, and nothing native is freed under it,
		as closing a TLS socket natively would be. On neko and HashLink a
		plain socket is closed so too, as `Http.__interrupt` closes one
		natively on Windows. Only then: a reader is left its read, as
		everywhere.

		Natively, and on neko and HashLink, on Windows a TLS write the peer
		is not taking is not ended by a shutdown, as a read is not: the
		thread waits until the peer reads or goes. The requests on the
		connection do not wait with it.
	**/
	private function __interrupt(endWrite:Bool):Void {
		__lock.acquire();
		var shut:Bool = !__interrupted && !__socketClosed;
		__interrupted = true;
		var close:Bool = false;
		#if (java || jvm || eval)
		close = endWrite && __writing && !__socketClosed;
		#elseif (neko || hl)
		close = endWrite && __writing && !__socketClosed && !__socket.isSecure;
		#end
		if (close) {
			__socketClosed = true;
		}
		__lock.release();
		if (shut) {
			Http.__interrupt(__socket);
		}
		if (close) {
			try {
				__socket.close();
			} catch (_:Dynamic) {}
		}
	}

	/** Called by the reader and the writer as each leaves; the last closes the socket. */
	private function __leave():Void {
		__lock.acquire();
		__threadsRunning--;
		var last:Bool = __threadsRunning == 0 && !__socketClosed;
		if (last) {
			__socketClosed = true;
			try {
				__socket.close();
			} catch (_:Dynamic) {}
		}
		__lock.release();
		__noteThreads(-1);
	}

	// ----------------------------------------------------------- reader

	private function __read():Void {
		__readFrames();
		// The writer may be waiting for something to write: it has nothing
		// more coming, and leaves.
		__writerWake.release();
		__leave();
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
			var queued:Int = connection.queuedBytes;
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
			var answered:Bool = connection.queuedBytes > queued;

			// A peer that sends what must be answered, a PING, a SETTINGS,
			// DATA earning a WINDOW_UPDATE, and reads none of the answers
			// would grow them here without end. Past MAX_QUEUED_REPLIES this
			// stops reading until they have gone, so its own socket stops it,
			// as a write held up under the lock once did, but holding nothing
			// anyone else needs. The wait ends when the writer takes them, or
			// the session ends.
			while (failure == null && connection.queuedReplyBytes > MAX_QUEUED_REPLIES && !dead && !__stopped) {
				__readerWaiting = true;
				__lock.release();
				__writerWake.release();
				__drained.wait();
				__lock.acquire();
				__readerWaiting = false;
			}
			__lock.release();
			if (answered && failure == null) {
				// Its own answers, a WINDOW_UPDATE the server is waiting on
				// to send more, written here when no one else is writing,
				// rather than handed to the writer thread: the hand-off held
				// each one up, and downloads with it. This thread may wait in
				// the write, which only stops it reading, as a peer not reading
				// should; the requests do not wait with it.
				__drainQueue(1);
			}

			if (failure != null) {
				__fail(failure);
				return;
			}

			if (__stopped || dead) {
				return;
			}
		}
	}

	private function __onStreamClosed(target:H2Stream):Void {
		var waiter:Null<H2Wake> = __waiters.get(target.id);
		if (waiter != null) {
			waiter.release();
		}
	}

	/**
	 * Waits for the reader to make progress while a window is closed, or for
	 * the writer to while the body's queued frames wait to go out, for no
	 * longer than what is left of the request's timeout.
	 *
	 * The lock is dropped across the wait and retaken after. Holding it would
	 * deadlock outright: the WINDOW_UPDATE that would release this thread can
	 * only be processed by the reader, and the reader needs this lock.
	 *
	 * The timeout is the longest the window may stay shut, so an upload that
	 * is slow but moving is not cut off. Once it has passed, only this stream
	 * is reset; the body's write sees it closed and stops, and if what kept
	 * it waiting is a writer the peer has not taken a byte from all that
	 * while, the connection is given up too. This used to wait for any frame
	 * at all, thirty seconds at a time: on a busy connection a body the peer
	 * had stopped taking waited forever, and on a quiet one the thirty
	 * seconds failed the connection and every request on it.
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
		var writerBound:Bool = connection.windowOpen(target);
		if (writerBound) {
			// The windows are open, and it is the frames already queued that
			// keep the body waiting: the clock is the writer's, one frame at a
			// time, so a peer taking it slowly is not cut off.
			var since:Float = __writingSince;
			remaining = upload.timeout - (since >= 0 ? haxe.Timer.stamp() - since : 0);
		}
		if (limited && remaining <= 0) {
			upload.timedOut = true;
			try {
				connection.resetStream(target.id, H2ErrorCode.CANCEL);
			} catch (_:Dynamic) {}
			if (writerBound) {
				// Nothing it was sent was taken all that while: the
				// connection goes too.
				__giveUp(upload.timeout);
			}
			return true;
		}

		upload.blocked = true;
		__lock.release();
		// What the body has queued so far has to go out for it to queue more.
		__writerWake.release();
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
		Whether the writer has been in one write for `seconds` or more: the
		peer has taken nothing for that long. `0` or less is never.
	**/
	private inline function __stalledFor(seconds:Float):Bool {
		var since:Float = __writingSince;
		return seconds > 0 && since >= 0 && haxe.Timer.stamp() - since >= seconds;
	}

	/**
		Gives the connection up because its peer has stopped taking what it
		is sent: every request on it fails, and the socket is shut down,
		which ends the write the peer is holding up. With the lock held or
		not.
	**/
	private function __giveUp(seconds:Float):Void {
		__lock.acquire();
		if (__failure == null) {
			__failure = 'Connection to $origin took nothing it was sent for ${seconds}s';
			__stalledLimit = seconds;
		}
		dead = true;
		__lock.release();
		__interrupt(true);
		__wakeEveryone();
	}

	/**
	 * Wakes every waiter, so a dead connection surfaces as a failed request
	 * rather than as one that waits out its whole timeout, and the writer
	 * and the reader, so they notice it too.
	 */
	private function __wakeEveryone():Void {
		__lock.acquire();
		var waiting:Array<H2Wake> = [];
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
		__drained.release();
		__writerWake.release();
	}

	// ----------------------------------------------------------- writer

	/**
		Writes what the connection queues, in the order it was queued, until
		the session is over; then shuts the socket down, which ends the
		reader's read. The reader writes its own answers when this is idle,
		and whichever holds the write (`__writing`) writes all that is queued.
	**/
	private function __write():Void {
		while (true) {
			// A request writing its own head is watched: given up on once it
			// has gone its limit without progress.
			var watch:Float = -1;
			var overdue:Float = -1;
			__lock.acquire();
			if (__writing && __directStream >= 0 && __directLimit > 0) {
				var since:Float = __writingSince;
				watch = __directLimit - (since >= 0 ? haxe.Timer.stamp() - since : 0);
				if (watch <= 0) {
					overdue = __directLimit;
				}
			}
			__lock.release();
			if (overdue > 0) {
				__giveUp(overdue);
				watch = -1;
			}

			if (watch > 0) {
				// Whole milliseconds: a fraction spins on Windows natively.
				__writerWake.wait(Math.max(0.001, Math.ffloor(watch * 1000) / 1000));
			} else {
				__writerWake.wait();
			}
			__drainQueue(-1);

			__lock.acquire();
			// Decided in the same hold as the last take: a GOAWAY close()
			// queued is written first, by this thread or the reader.
			var over:Bool = !__writing && (dead || (__stopped && connection.queuedBytes == 0));
			__lock.release();
			if (over) {
				break;
			}
		}
		// Its GOAWAY sent, or nothing more can be: the reader is ended by the
		// shutdown, or was already.
		__interrupt(false);
		__leave();
	}

	/**
		Writes a request's own head, `batch`, taken with the write by
		`execute`: the writer watches it meanwhile. What was queued behind it
		is handed to the writer. Answers why the write failed, or null.
	**/
	private function __writeDirect(batch:Array<Bytes>):Null<String> {
		var failure:Null<String> = null;
		try {
			__writeBatch(batch);
		} catch (e:Dynamic) {
			failure = "Connection failed while writing: " + Std.string(e);
		}
		__writingSince = -1;

		__lock.acquire();
		__writing = false;
		__directStream = -1;
		if (failure != null) {
			// What is queued can no longer go: dropped, so nothing waits on it.
			connection.takeOutbox();
		}
		var more:Bool = connection.queuedBytes > 0;
		__lock.release();

		if (failure != null) {
			__fail(failure);
		} else if (more) {
			__writerWake.release();
		}
		return failure;
	}

	/**
		Writes what is queued, batch by batch, unless another thread is
		writing, false then, and that thread takes what was queued, or
		the connection is dead. At most `batches` of them, `-1` for all; what
		is left after is handed to the writer thread.
	**/
	private function __drainQueue(batches:Int):Bool {
		__lock.acquire();
		if (__writing) {
			__lock.release();
			return false;
		}
		__writing = true;
		var written:Int = 0;
		while (true) {
			var batch:Null<Array<Bytes>> = (dead || written == batches) ? null : connection.takeOutbox();
			// Room again, for a body or a reader waiting on what was queued
			// to go: they queue the next batch while this one is written.
			for (upload in __uploads) {
				if (upload.blocked) {
					upload.wake.release();
				}
			}
			var readerWaiting:Bool = __readerWaiting;
			if (batch == null) {
				__writing = false;
				var more:Bool = !dead && connection.queuedBytes > 0;
				__lock.release();
				if (readerWaiting) {
					__drained.release();
				}
				if (more || dead || __stopped) {
					// The rest to the writer, which also leaves once the
					// session is over and nothing is being written.
					__writerWake.release();
				}
				return true;
			}
			__lock.release();
			if (readerWaiting) {
				__drained.release();
			}

			var failure:Null<String> = null;
			try {
				__writeBatch(batch);
			} catch (e:Dynamic) {
				failure = "Connection failed while writing: " + Std.string(e);
			}
			__writingSince = -1;
			written++;
			if (failure != null) {
				// What is queued can no longer go: dropped, so nothing waits on
				// it, and the connection fails.
				__lock.acquire();
				connection.takeOutbox();
				__writing = false;
				__lock.release();
				__fail(failure);
				return true;
			}
			__lock.acquire();
		}
	}

	/** Writes `frames` out, the small ones gathered into a write of up to `GATHER_LIMIT`. */
	private function __writeBatch(frames:Array<Bytes>):Void {
		var output:haxe.io.Output = __socket.output;
		if (frames.length == 1) {
			__send(output, frames[0]);
		} else {
			var gathered:Null<haxe.io.BytesBuffer> = null;
			for (frame in frames) {
				if (frame.length >= GATHER_LIMIT) {
					if (gathered != null) {
						__send(output, gathered.getBytes());
						gathered = null;
					}
					__send(output, frame);
					continue;
				}
				if (gathered == null) {
					gathered = new haxe.io.BytesBuffer();
				}
				gathered.addBytes(frame, 0, frame.length);
				if (gathered.length >= GATHER_LIMIT) {
					__send(output, gathered.getBytes());
					gathered = null;
				}
			}
			if (gathered != null) {
				__send(output, gathered.getBytes());
			}
		}
		output.flush();
	}

	/**
		One write, timed: `__writingSince` says how long the peer has been
		keeping it, for a request deciding whether to give the connection up.
	**/
	private inline function __send(output:haxe.io.Output, bytes:Bytes):Void {
		__writingSince = haxe.Timer.stamp();
		// Full, not writeBytes, which may write only part and says how much:
		// over TLS a call takes at most one 16 KB record.
		output.writeFullBytes(bytes, 0, bytes.length);
	}

	// --------------------------------------------------------- watchdog

	// Closed sessions whose threads have not left yet, and whether a thread
	// is watching them. The watcher runs only while there are some.
	private static final __closingLock:Mutex = new Mutex();
	private static var __closing:Array<H2ClientSession> = [];
	private static var __watching:Bool = false;

	/**
		Holds a closed session to `CLOSE_GRACE`: if its threads have not left
		by then, its writer held in a write the peer is not taking, or its
		reader in a read nothing ends, the socket is shut down under them.
		Nothing else would end them: everyone who could has gone.
	**/
	private static function __watchClosing(session:H2ClientSession):Void {
		__closingLock.acquire();
		__closing.push(session);
		var start:Bool = !__watching;
		__watching = true;
		__closingLock.release();
		if (start) {
			Thread.create(__watchLoop);
		}
	}

	private static function __watchLoop():Void {
		while (true) {
			crossbyte._internal.system.Sleep.sleep(0.25);
			var now:Float = haxe.Timer.stamp();
			var expired:Array<H2ClientSession> = [];
			__closingLock.acquire();
			var index:Int = __closing.length - 1;
			while (index >= 0) {
				var session:H2ClientSession = __closing[index];
				if (session.__threadsRunning <= 0) {
					__closing.splice(index, 1);
				} else if (now - session.__closedAt >= CLOSE_GRACE) {
					__closing.splice(index, 1);
					expired.push(session);
				}
				index--;
			}
			var idle:Bool = __closing.length == 0;
			if (idle) {
				__watching = false;
			}
			__closingLock.release();

			for (session in expired) {
				session.__interrupt(true);
			}
			if (idle) {
				return;
			}
		}
	}

	// Reader and writer threads running, across every session.
	private static final __countLock:Mutex = new Mutex();
	private static var __liveThreads:Int = 0;

	private static function __noteThreads(change:Int):Void {
		__countLock.acquire();
		__liveThreads += change;
		__countLock.release();
	}

	/**
		Reader and writer threads still running, across every session: two a
		session until it is over. Diagnostics and tests.
	**/
	public static function liveThreads():Int {
		__countLock.acquire();
		var count:Int = __liveThreads;
		__countLock.release();
		return count;
	}

	private function __release(streamId:Int):Void {
		__lock.acquire();
		if (__waiters.remove(streamId)) {
			__activeStreams--;
		}
		var closeNow:Bool = false;
		if (__activeStreams <= 0) {
			// Stamped as the last stream leaves, so the idle clock measures
			// time with nothing in flight rather than time since the
			// connection opened.
			__idleSince = haxe.Timer.stamp();
			// Retired with streams in flight (retire): this was the last.
			closeNow = __closeWhenIdle;
			__closeWhenIdle = false;
		}
		__lock.release();
		if (closeNow) {
			close();
		}
	}
}

/** A request body being written, and what it needs to wait on a window. */
private class H2Upload {
	/** Released for every frame processed while `blocked`, and by a cancel. */
	public final wake:H2Wake = new H2Wake();

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
