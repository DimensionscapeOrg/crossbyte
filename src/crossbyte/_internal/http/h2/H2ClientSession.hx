package crossbyte._internal.http.h2;

// Needs threads, so not any JavaScript target. `HTTP2Backend` is gated the same
// way, for the socket rather than the threads.
#if !js
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

	/** Requests currently in flight. */
	public var active(get, never):Int;

	private final __socket:FlexSocket;
	private final __lock:Mutex = new Mutex();
	private final __waiters:Map<Int, Lock> = new Map();

	// Released on every processed frame. A writer blocked on a flow-control
	// window re-tests its condition each time rather than being told which
	// frame it was waiting for, because it may be waiting on either window.
	private final __progress:Lock = new Lock();

	private var __activeStreams:Int = 0;
	private var __stopped:Bool = false;
	private var __failure:String = null;

	public function new(origin:String, socket:FlexSocket, connection:H2Connection) {
		this.origin = origin;
		__socket = socket;
		this.connection = connection;

		connection.onStreamClosed = __onStreamClosed;
		connection.onWindowBlocked = __onWindowBlocked;

		connection.start();
		Thread.create(__read);
	}

	private inline function get_active():Int {
		return __activeStreams;
	}

	/**
	 * Whether another request may start now.
	 *
	 * A peer's SETTINGS_MAX_CONCURRENT_STREAMS is a limit on streams it will
	 * accept, not a suggestion: opening past it earns a REFUSED_STREAM, so a
	 * caller is better served by waiting or by a second connection.
	 */
	public function hasCapacity():Bool {
		if (dead || __stopped) {
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
	 */
	public function execute(method:String, scheme:String, authority:String, path:String, headers:Array<HpackHeader>, body:Null<Bytes>,
			timeoutSeconds:Float, ?cancelToken:HTTPCancelToken):H2Stream {
		var target:H2Stream;
		var waiter:Lock = new Lock();

		if (cancelToken != null && cancelToken.cancelled) {
			// Already abandoned. Opening a stream just to reset it would still
			// consume an id, and ids never come back.
			throw new H2ConnectionError(H2ErrorCode.CANCEL, "Request was cancelled before it started");
		}

		__lock.acquire();
		if (dead || __stopped) {
			__lock.release();
			throw new H2ConnectionError(H2ErrorCode.REFUSED_STREAM, __failure != null ? __failure : "Connection is no longer usable");
		}

		try {
			target = connection.request(method, scheme, authority, path, headers, body);
		} catch (e:Dynamic) {
			__lock.release();
			throw e;
		}

		// Registered before the lock is dropped so the reader cannot close the
		// stream in the gap -- it needs this same lock to process a frame.
		// The one hole is a body write, which releases the lock while it waits
		// on a window, so the state is re-checked below.
		__waiters.set(target.id, waiter);
		__activeStreams++;

		var alreadyDone:Bool = target.isClosed();
		__lock.release();

		if (alreadyDone) {
			__release(target.id);
			return target;
		}

		// Registered only now that the stream id exists. A token cancelled in
		// the meantime runs this immediately, which is why `onCancel` fires
		// late registrations rather than dropping them.
		var streamId:Int = target.id;
		var onCancelled:Void->Void = () -> cancel(streamId);
		if (cancelToken != null) {
			cancelToken.onCancel(onCancelled);
		}

		if (!waiter.wait(timeoutSeconds)) {
			// The peer never finished. The stream is reset rather than
			// abandoned: leaving it open holds a slot against
			// MAX_CONCURRENT_STREAMS for the life of the connection.
			__lock.acquire();
			try {
				connection.resetStream(target.id, H2ErrorCode.CANCEL);
			} catch (_:Dynamic) {}
			__lock.release();

			__release(target.id);
			throw new H2ConnectionError(H2ErrorCode.CANCEL, 'Request to $origin timed out after ${timeoutSeconds}s');
		}

		if (cancelToken != null) {
			// The request is over; the token must not keep a handler pointing
			// at a stream id that will be reused by nobody but is still dead
			// weight on a long-lived token.
			cancelToken.removeHandler(onCancelled);
		}

		__release(target.id);
		return target;
	}

	/**
	 * Abandons one stream without disturbing the connection.
	 *
	 * RST_STREAM rather than a close: the connection is shared, so tearing it
	 * down would cancel every other request on it too. Safe from any thread,
	 * and safe on a stream that has already finished -- the reset is simply
	 * not sent.
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
		__lock.release();

		// Released outside the lock, and unconditionally: a stream already
		// closed by the peer has no waiter left to wake, and one whose reset
		// failed still has a caller who must not wait out its timeout.
		if (waiter != null) {
			waiter.release();
		}
	}

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
		__lock.release();

		try {
			__socket.close();
		} catch (_:Dynamic) {}

		__wakeEveryone();
	}

	// ----------------------------------------------------------- reader

	private function __read():Void {
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
			__lock.release();

			// Any frame may have opened a window.
			__progress.release();

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
	 * Waits for the reader to make progress while a window is closed.
	 *
	 * The lock is dropped across the wait and retaken after. Holding it would
	 * deadlock outright: the WINDOW_UPDATE that would release this thread can
	 * only be processed by the reader, and the reader needs this lock.
	 */
	private function __onWindowBlocked():Bool {
		if (dead || __stopped) {
			return false;
		}

		__lock.release();
		var progressed:Bool = __progress.wait(30);
		__lock.acquire();

		return progressed && !dead && !__stopped;
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
		__lock.release();

		for (waiter in waiting) {
			waiter.release();
		}
		__progress.release();
	}

	private function __release(streamId:Int):Void {
		__lock.acquire();
		if (__waiters.remove(streamId)) {
			__activeStreams--;
		}
		__lock.release();
	}
}
#end
