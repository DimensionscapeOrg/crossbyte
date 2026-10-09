package crossbyte.ipc;

// Not built for the browser. Local IPC means an OS channel between processes on one machine, and a page has neither the channel nor the processes.
#if !js

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.IOError;
#if !cpp
import crossbyte.crypto._internal.NativeOnly;
#end

import crossbyte.events.UncaughtErrorEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net._internal.CloseObservable;
import crossbyte.net.Reason;
import crossbyte.net.Transport;
import crossbyte.utils.Logger;
import haxe.io.Bytes;
import haxe.io.BytesData;
#if cpp
import cpp.Pointer;
import crossbyte.ipc._internal.NativeLocalConnection;
#if windows
import crossbyte.ipc._internal.win.HANDLE;
#end
import crossbyte.ipc._internal.VoidPointer;
#end
#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

#if cpp
#if windows
private typedef LocalConnectionHandle = HANDLE;
#else
private typedef LocalConnectionHandle = VoidPointer;
#end
#else
private typedef LocalConnectionHandle = Dynamic;
#end

private enum LocalConnectionMode {
	NONE;
	CLIENT;
	SERVER;
}

private enum LocalConnectionDispatch {
	Ready;
	Close(reason:Reason);
	Error(reason:Reason);
	Data(payload:ByteArray);
}

/**
 * `LocalConnection` is CrossByte's low-level local IPC transport.
 *
 * The transport exposes a byte-oriented, duplex connection surface compatible
 * with `INetConnection`, making it suitable for `NetConnection` and
 * `RPCSession`. Use `listen(name)` on the server side and `connect(name)` on
 * the client side.
 *
 * `SharedChannel` builds on top of this transport when you want the older
 * method-name plus serialized-arguments message model.
 *
 * A name is its user's own: processes of one user meet over it, and those of
 * two users never do, nor can another user listen on it, or put anything in
 * its place, to take its clients. On Linux and macOS the name's socket lives
 * in `/tmp/crossbyte-<uid>`, which is made 0700 and must be a directory the
 * user owns that nobody else can enter (not a link, and not one another
 * user made first); a client also refuses anything at the socket's path that
 * is not a socket of the user's, a link included. On Windows the name's pipe
 * carries the user's SID, admits the user and SYSTEM alone, and refuses
 * clients on other machines; a client refuses a pipe under the name that
 * another user made. What is found not to be the user's own is refused with
 * an `IOError` saying so, by `listen` and `connect` alike.
 *
 * A callback that throws is reported as a socket handler's failure is:
 * logged with `Logger.error`, and dispatched as
 * `UncaughtErrorEvent.UNCAUGHT_ERROR` (source `SOCKET`, origin this
 * connection) on the runtime the connection was made on, or only logged
 * where it has none. One the runtime delivers (`onData`, `onReady`, or
 * `onClose` and `onError` for a connection that ended) also ends the
 * connection, as a socket's would, and `onError` is told why; one that
 * `close()` calls is reported and nothing more.
 */
@:access(haxe.io.Bytes)
#if cpp
@:access(crossbyte.ipc._internal.NativeLocalConnection)
#end
class LocalConnection implements INetConnection implements CloseObservable implements crossbyte.core._internal.PassFlush {
	/**
	 * Whether this target has local IPC: natively (cpp) on Windows, over a
	 * named pipe, and on Linux and macOS, over a Unix domain socket. Elsewhere
	 * `listen` and `connect` throw an `IllegalOperationError` naming the target.
	 */
	public static inline var isSupported:Bool = #if cpp true #else false #end;

	/** Maximum payload size accepted by the framing layer, in bytes. */
	public static inline var MAX_FRAME_SIZE:Int = 8 * 1024 * 1024;

	/** The default `maxQueuedBytes`: two frames of the largest size. */
	public static inline var DEFAULT_MAX_QUEUED:Int = 2 * (MAX_FRAME_SIZE + 4);

	// How long one delivery on the runtime's thread may run before it lets
	// the rest wait for the next, in seconds. It delivered 32 messages a tick,
	// whatever they cost: 384 a second at the default rate, with anything
	// faster piling up.
	@:noCompletion private static inline var DRAIN_BUDGET:Float = 0.002;

	// How long the reader waits between looks at an idle connection, from
	// the first after something happened to the longest, in seconds. It
	// looked every millisecond, busy or not: a thousand wakes a second for
	// each connection doing nothing. On Linux and macOS the wait ends early
	// when the socket has something to read or room to write, and on Windows
	// when the peer rings the pipe's doorbell.
	@:noCompletion private static inline var POLL_MIN:Float = 0.001;
	@:noCompletion private static inline var POLL_MAX:Float = 0.010;

	/**
		The most bytes held for this connection in each direction: what
		`send` has queued that the peer has not taken yet, and what has
		arrived that the application has not been given.

		`send` does not wait for the peer. It writes what the channel takes
		and queues the rest, which the reader thread writes as the peer reads
		it, so two processes that fill each other's channels never wait on
		each other for good. A
		peer that has left more than this unread is taken to be stuck: the
		connection is closed, with an error saying so, and what was queued is
		dropped. A sender with more than this to send at once paces itself on
		`bytesPending`.

		What arrives is read only while less than this waits to be delivered,
		so a sender faster than the application pushes back on the sender
		rather than on this process's memory. `0` removes both limits.
	**/
	public var maxQueuedBytes:Int = DEFAULT_MAX_QUEUED;

	/**
		The bytes `send` has queued that the peer has not taken yet, framing
		included. A sender with a lot to send waits for this to fall before
		sending more, rather than passing `maxQueuedBytes`.
	**/
	public var bytesPending(get, never):Int;

	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var protocol:Protocol = LOCAL;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;
	/**
	 * How long, in milliseconds, `connect()` waits on the calling thread for
	 * something to listen on the name; past it, `connect()` throws an
	 * `ArgumentError`. The default is 5,000 (five seconds).
	 *
	 * 0 (or less) means no deadline: `connect()` waits until something
	 * listens, however long that is, as a connect with `timeout = 0` does
	 * everywhere in CrossByte. One try is what
	 * any timeout of 50 or less makes, 50 ms being the pause between tries.
	 */
	public var timeout:Int = 5000;
	public var inTimestamp(default, null):Float = 0;
	public var outTimestamp(default, null):Float = 0;

	@:noCompletion private static inline var BUFFER_SIZE:Int = 4096;
	// The most the reader takes from the channel in one pass.
	@:noCompletion private static inline var READ_PER_PASS:Int = 1024 * 1024;

	@:noCompletion private var __mode:LocalConnectionMode = NONE;
	@:noCompletion private var __connectionName:String = null;
	@:noCompletion private var __runtime:CrossByte = null;
	@:noCompletion private var __activePipe:LocalConnectionHandle = null;
	@:noCompletion private var __listeningPipe:LocalConnectionHandle = null;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __readEnabled:Bool = false;
	@:noCompletion private var __running:Bool = false;
	@:noCompletion private var __onData:ByteArrayInput->Void = __noopData;
	@:noCompletion private var __onClose:Reason->Void = __noopClose;
	@:noCompletion private var __onError:Reason->Void = __noopError;
	@:noCompletion private var __onReady:Void->Void = __noopReady;
	#if (cpp || neko || hl)
	@:noCompletion private var __dispatchQueue:Deque<LocalConnectionDispatch>;
	@:noCompletion private var __dispatchLock:Mutex;
	@:noCompletion private var __pendingLock:Mutex;
	// Serializes native handle access (__activePipe/__listeningPipe) so a write
	// in send() cannot race the reader thread closing the same handle in
	// close()/__disconnectActive(); and, with __dispatchLock, what ends a
	// session, so a reader thread acts for its own session only.
	@:noCompletion private var __handleLock:Mutex;
	#end
	// Delivers what the reader thread queued, on the runtime's thread; posted
	// to the runtime when the queue has something in it and no delivery is
	// on its way. See __queueDispatch.
	@:noCompletion private var __drain:Void->Void;
	// Raised under __dispatchLock by whichever thread queues a dispatch, when
	// it posts a delivery; lowered by the delivery.
	@:noCompletion private var __dispatchPending:Bool = false;
	// Bytes of payload queued for delivery, or held until reads are enabled,
	// and not yet delivered. See __countInbound.
	@:noCompletion private var __inQueued:Int = 0;
	// What send() has framed that the peer has not taken: one buffer, each
	// frame written into it where it ends, and the channel written from
	// __outSent. Under __handleLock. One buffer for every send, rather than
	// a buffer made, grown and copied into for each.
	@:noCompletion private var __outBuffer:ByteArray = null;
	@:noCompletion private var __outSent:Int = 0;
	@:noCompletion private var __outQueued:Int = 0;
	// Whether this pass's sends are to be written when it ends; see send().
	@:noCompletion private var __outPassQueued:Bool = false;
	// Whether the runtime will try again, at its next frame, to write what
	// the channel did not take; see __flushPass.
	@:noCompletion private var __outRetryArmed:Bool = false;
	@:noCompletion private var __outRetry:Void->Void = null;
	// Advanced by close(), which listen() and connect() begin with, so a
	// reader thread can say which session it belonged to.
	@:noCompletion private var __session:Int = 0;
	@:noCompletion private var __pendingPayloads:Array<ByteArray> = [];
	@:noCompletion private var __dispatchFailed:Bool = false;
	// Told as the connection ends, before onClose, and as it becomes ready,
	// before onReady; see CloseObservable.
	@:noCompletion private var __closeObserver:Null<Reason->Void> = null;
	@:noCompletion private var __readyObserver:Null<Void->Void> = null;

	public function new() {
		__captureRuntime();
		#if (cpp || neko || hl)
		__dispatchQueue = new Deque();
		__dispatchLock = new Mutex();
		__pendingLock = new Mutex();
		__handleLock = new Mutex();
		#end
		__drain = __drainDispatchQueue;
	}

	/**
	 * Starts listening for a local peer on the given pipe name.
	 *
	 * The connection becomes `connected == true` only after a client attaches.
	 *
	 * @param connectionName Named local IPC endpoint to listen on.
	 * @throws ArgumentError When another listener of this user's has the name,
	 *         or it cannot be used.
	 * @throws IOError When what is under the name is not this user's own: on
	 *         Linux and macOS, the directory the user's names live in (see the
	 *         class).
	 */
	public function listen(connectionName:String):Void {
		__requireSupported();
		__requireConnectionName(connectionName);
		close();
		__captureRuntime();
		__dispatchFailed = false;
		__mode = SERVER;
		__connectionName = connectionName;
		__running = true;

		#if cpp
		var session = __session;
		var handleQueue:Deque<LocalConnectionHandle> = new Deque();
		// Why the pipe was not made, read on the thread that tried; seen here
		// once the queue hands back its answer.
		var notOwned = false;
		Thread.create(() -> {
			var handle:LocalConnectionHandle = null;
			try {
				handle = __createInboundPipe(connectionName);
				if (handle == null) {
					notOwned = __notOwned();
				}
				__listeningPipe = handle;
				handleQueue.add(handle);
			} catch (_:Dynamic) {
				handleQueue.add(null);
			}

			if (handle != null) {
				__runLoop(session);
			}
		});

		if (handleQueue.pop(true) == null) {
			__running = false;
			__mode = NONE;
			__discardQueued();
			if (notOwned) {
				throw __notOwnedError(connectionName);
			}
			// Another listener has the name (on either platform), or it
			// cannot be used.
			throw new ArgumentError("Connection name is already in use or invalid");
		}
		#end
	}

	/**
	 * Connects to a listening local endpoint, waiting on the calling thread
	 * for something to listen on the name for up to `timeout`, or without a
	 * deadline when that is 0.
	 *
	 * @param connectionName Named local IPC endpoint to connect to.
	 * @throws ArgumentError When nothing listened on the name within
	 *         `timeout`, or the name cannot be used.
	 * @throws IOError When what is under the name is not this user's own:
	 *         another user's pipe on Windows; on Linux and macOS the user's
	 *         directory, or anything at the name's socket path that is not
	 *         a socket of the user's, a link included (see the class).
	 */
	public function connect(connectionName:String):Void {
		__requireSupported();
		__requireConnectionName(connectionName);
		close();
		__captureRuntime();
		__dispatchFailed = false;
		__mode = CLIENT;
		__connectionName = connectionName;

		var handle = __connect(connectionName, timeout);
		if (handle == null) {
			// Read at once, on the thread that tried.
			var notOwned = __notOwned();
			__mode = NONE;
			var reason = Reason.Error(notOwned ? "What is under the local name is not this user's own." : "Failed to connect to local endpoint.");
			__dispatchLifecycle(Error(reason));
			if (notOwned) {
				throw __notOwnedError(connectionName);
			}
			throw new ArgumentError("Connection name is unavailable or invalid");
		}

		__activePipe = handle;
		__connected = true;
		__running = true;
		// Told at the next tick, not from inside connect(), so a callback set
		// once connect() has returned (as `new NetConnection("local://...")`
		// leaves one to be) does not miss a Ready already sent.
		#if (cpp || neko || hl)
		if (__runtime != null) {
			__queueDispatch(Ready, __session);
		} else {
			__dispatchLifecycle(Ready);
		}
		#else
		__dispatchLifecycle(Ready);
		#end

		var session = __session;
		#if (cpp || neko || hl)
		Thread.create(() -> __runLoop(session));
		#else
		__runLoop(session);
		#end
	}

	public function expose():Transport {
		return LOCAL(this);
	}

	/**
	 * Sends a framed payload over the active local transport.
	 *
	 * @param data Payload bytes to transmit.
	 */
	public function send(data:ByteArray):Void {
		// Preserve the original guard ordering: closed first, then payload size.
		// The authoritative closed-check + write happens again under __handleLock
		// below so a concurrent close() cannot tear the handle down mid-write;
		// the handle is not probed here, outside it, for the same reason.
		if (!__connected || __activePipe == null) {
			__dispatchLifecycle(Error(Reason.Closed));
			return;
		}

		if (data == null || data.length > MAX_FRAME_SIZE) {
			__dispatchLifecycle(Error(Reason.Error("Invalid local payload size.")));
			return;
		}

		var length:Int = data.length;

		// Queued and written without waiting, under __handleLock so the reader
		// thread's close/disconnect cannot tear the handle down (and the OS
		// reuse it) between the check and the write. What the channel does
		// not take now, the reader thread writes as the peer reads. Lifecycle
		// errors are dispatched after releasing the lock to avoid re-entering
		// callbacks while holding it.
		#if (cpp || neko || hl)
		__handleLock.acquire();
		#end
		var failure:LocalConnectionDispatch = null;
		var stuck:Null<Reason> = null;
		var pipe = __activePipe;
		// Not asked first whether the channel is still open, a system call a
		// send: the write says so, and a failed one is asked why.
		if (!__connected || pipe == null) {
			failure = Error(Reason.Closed);
		} else if (maxQueuedBytes > 0 && __outQueued > 0 && __outQueued + length + 4 > maxQueuedBytes) {
			// Only with something already waiting: a frame larger than the
			// limit still goes to a peer that has kept up.
			stuck = Reason.Error("Local transport peer is not reading: " + __outQueued + " bytes wait for it, and "
				+ (length + 4) + " more would pass the " + maxQueuedBytes + "-byte limit.");
		} else {
			__frameOutput(data, length);
			// On the runtime's own thread the pass's sends go together when
			// it ends, in a write or a few; from any other, now.
			if (!__holdForPass() && !__flushOutput(pipe)) {
				failure = __writeFailure(pipe);
			}
		}
		#if (cpp || neko || hl)
		__handleLock.release();
		#end

		if (stuck != null) {
			__dispatchLifecycle(Error(stuck));
			__closeWith(stuck);
			return;
		}

		if (failure != null) {
			__dispatchLifecycle(failure);
			return;
		}

		outTimestamp = __timestamp();
	}

	/**
		Writes as much of what is queued as the channel takes now, without
		waiting; `false` when the connection is gone. Under __handleLock.

		A frame is written whole or left queued from where it stopped, so the
		peer's next read never begins in the middle of one.
	**/
	@:noCompletion private function __flushOutput(pipe:LocalConnectionHandle):Bool {
		while (__outQueued > 0) {
			final written:Int = __writeSome(pipe, (cast __outBuffer : Bytes).getData(), __outSent, __outQueued);
			if (written < 0) {
				return false;
			}
			if (written == 0) {
				break;
			}
			__outSent += written;
			__outQueued -= written;
		}
		if (__outQueued == 0) {
			if (__outBuffer != null) {
				__outBuffer.clear();
			}
			__outSent = 0;
		} else if (__outSent >= __outQueued) {
			// What is left moved down over what went, once what went is as
			// long: no byte is moved more often than bytes are written.
			final raw:Bytes = cast __outBuffer;
			raw.blit(0, raw, __outSent, __outQueued);
			__outBuffer.length = __outQueued;
			__outSent = 0;
		}
		return true;
	}

	/** Frames `length` bytes of `data` at the end of what waits to be written. Under __handleLock. **/
	@:noCompletion private function __frameOutput(data:ByteArray, length:Int):Void {
		if (__outBuffer == null) {
			__outBuffer = new ByteArray();
		}
		// In the byte order a frame always had: `ByteArray.defaultEndian`'s,
		// as the reader's own buffer reads it.
		__outBuffer.endian = ByteArray.defaultEndian;
		__outBuffer.position = __outBuffer.length;
		__outBuffer.writeInt(length);
		if (length > 0) {
			__outBuffer.writeBytes(data, 0, length);
		}
		__outQueued += 4 + length;
	}

	/**
		Whether this pass's sends can wait for its end: on the runtime's own
		thread, while it runs, they do, and one write takes them all; asked of
		the runtime once a pass. Under __handleLock.
	**/
	@:noCompletion private function __holdForPass():Bool {
		if (__outPassQueued) {
			return true;
		}
		var runtime:CrossByte = __runtime;
		if (runtime == null || @:privateAccess runtime.__didExit || CrossByte.__currentOrNull() != runtime) {
			return false;
		}
		__outPassQueued = true;
		@:privateAccess runtime.__queuePassFlush(this);
		return true;
	}

	/**
		The runtime's call at the end of a pass: what this pass's sends framed
		is written.

		What the channel does not take is tried again at the runtime's next
		frame, once a frame until it is all written, as well as by the reader
		thread, which waits a sleep between tries (on Windows a millisecond
		at least, so a burst larger than the pipe's buffer would cross a
		buffer a sleep, 4 KB messages at 20 MB/s). Once a frame, not at
		once: a peer that is not reading costs a runtime a write a frame, not
		a spin.
	**/
	@:noCompletion public function __flushPass():Void {
		var failure:LocalConnectionDispatch = null;
		#if (cpp || neko || hl)
		__handleLock.acquire();
		#end
		__outPassQueued = false;
		var pipe = __activePipe;
		if (__connected && pipe != null && __outQueued > 0 && !__flushOutput(pipe)) {
			failure = __writeFailure(pipe);
		}
		var runtime:CrossByte = __runtime;
		if (failure == null && __connected && pipe != null && __outQueued > 0 && !__outRetryArmed && runtime != null
			&& !@:privateAccess runtime.__didExit) {
			if (__outRetry == null) {
				__outRetry = __retryOutput;
			}
			__outRetryArmed = true;
			@:privateAccess runtime.__timer.setTimeout(0, __outRetry);
		}
		#if (cpp || neko || hl)
		__handleLock.release();
		#end
		if (failure != null) {
			__dispatchLifecycle(failure);
		}
	}

	/** The retry __flushPass arms: at the frame after, what still waits. **/
	@:noCompletion private function __retryOutput():Void {
		__outRetryArmed = false;
		__flushPass();
	}

	/** Why a write failed: the channel closed, or something else. Under __handleLock. **/
	@:noCompletion private function __writeFailure(pipe:LocalConnectionHandle):LocalConnectionDispatch {
		return __isOpen(pipe) ? Error(Reason.Error("Local transport write failed.")) : Error(Reason.Closed);
	}

	/** Drops whatever is queued to send. Under __handleLock. **/
	@:noCompletion private inline function __dropOutput():Void {
		if (__outBuffer != null) {
			__outBuffer.clear();
		}
		__outSent = 0;
		__outQueued = 0;
	}

	public function close():Void {
		__closeWith(Reason.Closed);
	}

	/** close(), telling onClose and the close observer `reason`. **/
	@:noCompletion private function __closeWith(reason:Reason):Void {
		var wasConnected = __connected;
		// The session ends under both locks its reader thread checks it under:
		// whatever that thread does for it afterwards is refused, and what it
		// did before is torn down or discarded below.
		#if (cpp || neko || hl)
		__handleLock.acquire();
		__dispatchLock.acquire();
		#end
		__session++;
		__running = false;
		#if (cpp || neko || hl)
		__dispatchLock.release();
		__handleLock.release();
		#end
		__dispatchFailed = false;
		__mode = NONE;
		__connectionName = null;
		__clearPendingPayloads();
		__discardQueued();

		// Clear connected state and tear down the handles under __handleLock so a
		// concurrent send() observes the closed connection and cannot write to a
		// handle that is being closed.
		#if (cpp || neko || hl)
		__handleLock.acquire();
		#end
		__connected = false;
		if (__activePipe != null) {
			// What is still queued goes if the channel takes it now; a close
			// does not wait for its peer.
			__flushOutput(__activePipe);
			__close(__activePipe);
			__activePipe = null;
		}
		if (__listeningPipe != null) {
			__close(__listeningPipe);
			__listeningPipe = null;
		}
		__dropOutput();
		#if (cpp || neko || hl)
		__handleLock.release();
		#end

		if (wasConnected) {
			__notifyClose(reason);
			try {
				__onClose(reason);
			} catch (error:Dynamic) {
				__callbackThrew(error);
			}
		}
	}

	@:noCompletion public function __observeClose(observer:Null<Reason->Void>):Void {
		__closeObserver = observer;
	}

	@:noCompletion public function __observeReady(observer:Null<Void->Void>):Void {
		__readyObserver = observer;
	}

	/** Before `onClose`, wherever that is called; see CloseObservable. **/
	@:noCompletion private inline function __notifyClose(reason:Reason):Void {
		final observer = __closeObserver;
		if (observer != null) {
			observer(reason);
		}
	}

	/** Before `onReady`, each time this becomes ready: a listener does again for each peer it takes. **/
	@:noCompletion private inline function __notifyReady():Void {
		final observer = __readyObserver;
		if (observer != null) {
			observer();
		}
	}

	/**
	 * The reader thread of one session, `session`.
	 *
	 * It acts only for that session. close() ends a session and listen() or
	 * connect() start the next at once, while this thread sleeps between
	 * polls, so it must not wake to find `__running` true again and carry
	 * on beside the next session's reader (reading its pipe, splitting its
	 * bytes, tearing it down when the read that lost the race found nothing,
	 * and making it a listener of its own). So what this thread does to the
	 * connection it does under `__handleLock` having checked the session is
	 * still its own, and what it hands on carries the session and is refused
	 * once it has ended.
	 */
	@:noCompletion private function __runLoop(session:Int):Void {
		var chunk:Bytes = Bytes.alloc(BUFFER_SIZE);
		// This session's framing, and this thread's alone: no reader shares
		// one with another, and close() never clears one being written to.
		var framing = new ByteArray();
		var idle:Float = POLL_MIN;
		// Whether the last wait ended because the socket was ready.
		var wokeForWork = false;

		while (__running && __session == session) {
			// Whether this pass read, wrote or took a client: the next look
			// comes soon if so, and later and later while nothing does.
			var busy = false;
			// Too much delivered-to-be already: the peer waits, in its own
			// queue, rather than this process holding more of what it sends.
			var full = __inboundFull();
			#if (cpp || neko || hl)
			__handleLock.acquire();
			#end
			if (__session != session) {
				#if (cpp || neko || hl)
				__handleLock.release();
				#end
				break;
			}

			// Published with the connected state under __handleLock, so send()
			// sees a consistent (handle, connected) pair.
			var accepted = false;
			if (__mode == SERVER && __activePipe == null && __listeningPipe != null && __accept(__listeningPipe)) {
				__activePipe = __listeningPipe;
				__listeningPipe = null;
				__connected = true;
				accepted = true;
				busy = true;
			}
			if (__mode == SERVER) {
				// The name's lock file kept from looking unused, hourly.
				__keepName(__activePipe != null ? __activePipe : __listeningPipe);
			}

			// Polled and read under the lock too: both are immediate, and a
			// handle closed and reused by the OS cannot be read as this one.
			var received:Bytes = null;
			var failure:Reason = null;
			var pipe = __activePipe;
			if (pipe != null && __outQueued > 0) {
				// What send() could not write at once.
				final before:Int = __outQueued;
				if (!__flushOutput(pipe)) {
					failure = Reason.Error("Local transport write failed.");
				} else if (__outQueued < before) {
					busy = true;
				}
			}
			if (pipe != null && failure == null) {
				var available = __getBytesAvailable(pipe);
				if (available < 0 || (available == 0 && !__isOpen(pipe))) {
					failure = Reason.Closed;
				} else if (available > 0 && !full) {
					busy = true;
					// At most READ_PER_PASS at a time; the next pass, at once,
					// reads on, so more than one frame's worth having arrived,
					// which a reader paused while the application catches up
					// lets happen, is no failure.
					// A frame too long is caught where it is framed.
					var bytesRemaining = available > READ_PER_PASS ? READ_PER_PASS : available;
					// One buffer of the size known, filled a chunk at a time: a
					// BytesBuffer on hxcpp adds a byte at a time.
					var whole:Bytes = Bytes.alloc(bytesRemaining);
					var filled:Int = 0;
					while (bytesRemaining > 0) {
						var length = bytesRemaining > BUFFER_SIZE ? BUFFER_SIZE : bytesRemaining;
						if (__read(pipe, chunk.getData(), length) != 0) {
							failure = Reason.Error("Local transport read failed.");
							break;
						}
						whole.blit(filled, chunk, 0, length);
						filled += length;
						bytesRemaining -= length;
					}
					if (failure == null) {
						received = whole;
					}
				}
			}
			// What to wait for until the next pass, read while the handle is
			// this session's: something to read, or a client to take, unless
			// enough waits to be delivered; room to write, if anything waits
			// to be written.
			var waitOn:Int = -1;
			var waitToRead = false;
			var waitToWrite = false;
			var held = __activePipe != null ? __activePipe : __listeningPipe;
			if (failure == null && held != null) {
				waitOn = __descriptorOf(held);
				waitToRead = !__inboundFull();
				waitToWrite = __activePipe != null && __outQueued > 0;
			}
			#if (cpp || neko || hl)
			__handleLock.release();
			#end

			if (accepted) {
				__dispatchFromReader(Ready, session);
			}
			if (received != null && !__appendReceivedBytes(framing, received, session)) {
				failure = Reason.Error("Local transport received an invalid frame.");
			}
			if (failure != null) {
				framing.clear();
				__disconnectActive(failure, session);
				busy = true;
			}

			idle = busy ? POLL_MIN : (idle * 2 > POLL_MAX ? POLL_MAX : idle * 2);
			// A pass that read, wrote or took a client is followed by another at
			// once, which finds out whether there is more, rather than a sleep
			// first (on Windows a millisecond at least, and up to the 15.6 of
			// the system's clock), at which a peer sending steadily would be
			// read a pass a sleep: 4 KB messages at 20 MB/s.
			if (busy) {
				wokeForWork = false;
				continue;
			}
			// Ready, and yet nothing came of it: once, and then a plain wait,
			// so a socket that says it is ready and lets nothing through
			// cannot spin this thread. (A Windows pipe's doorbell rings once
			// each time it is rung, and is rung for room made as well as for
			// data, so its wait never says it woke for work.)
			if (wokeForWork && !busy) {
				waitOn = -1;
			}
			wokeForWork = __waitForWork(waitOn, waitToRead, waitToWrite, idle);
		}

		// Its own session's handles, if close() has not already had them.
		#if (cpp || neko || hl)
		__handleLock.acquire();
		#end
		if (__session == session) {
			if (__activePipe != null) {
				__close(__activePipe);
				__activePipe = null;
			}
			if (__listeningPipe != null) {
				__close(__listeningPipe);
				__listeningPipe = null;
			}
		}
		#if (cpp || neko || hl)
		__handleLock.release();
		#end
		// Nothing of the runtime's holds a connection that ended by itself:
		// what it queued is delivered by posts, not by a listener on the
		// runtime's tick that had to be taken off again.
	}

	/** Frames `received` into `framing` and hands on each whole one; false for an invalid frame. **/
	@:noCompletion private function __appendReceivedBytes(framing:ByteArray, received:Bytes, session:Int):Bool {
		if (received == null || received.length == 0) {
			return true;
		}

		// After what is held, framed from where the last pass stopped.
		final unreadFrom:Int = framing.position;
		framing.position = framing.length;
		framing.writeBytes(received, 0, received.length);
		framing.position = unreadFrom;

		while (framing.bytesAvailable >= 4) {
			var frameStart = framing.position;
			var payloadLength = framing.readInt();
			if (payloadLength < 0 || payloadLength > MAX_FRAME_SIZE) {
				return false;
			}

			if (framing.bytesAvailable < payloadLength) {
				framing.position = frameStart;
				break;
			}

			var payload = new ByteArray();
			if (payloadLength > 0) {
				framing.readBytes(payload, 0, payloadLength);
			}
			payload.position = 0;
			inTimestamp = __timestamp();
			if (!__readEnabled) {
				__pushPendingPayload(payload, session);
			} else {
				__dispatchFromReader(Data(payload), session);
			}
		}

		__compactReceiveBuffer(framing);
		return true;
	}

	/**
		Lets go of what has been framed, leaving `framing.position` at what
		has not: all of it once all is framed, and otherwise only once it is
		at least as much as what is left, which is then moved to the front.

		Copying what is left out to a new array and back every pass would
		copy a frame arriving a little at a time whole once per arrival: 8 KB
		at a time, as macOS's local sockets give it, a 3 MB frame 384 times
		over (1.2 GB copied and as much allocated). Moved only when what went
		before it is as large, each byte is moved a bounded number of times.
	**/
	@:noCompletion private function __compactReceiveBuffer(framing:ByteArray):Void {
		final framed:Int = framing.position;
		final remaining:Int = framing.bytesAvailable;
		if (remaining <= 0) {
			framing.clear();
			return;
		}
		if (framed < remaining) {
			return;
		}

		// Source and destination do not overlap: what moves is no longer
		// than what it moves over.
		(cast framing : Bytes).blit(0, cast framing, framed, remaining);
		framing.length = remaining;
		framing.position = 0;
	}

	@:noCompletion private function __disconnectActive(reason:Reason, session:Int):Void {
		// Under __handleLock, so a concurrent send() cannot write to the handle
		// being closed, and only for the reader's own session: a stale one
		// closed the next session's pipe and made it a listener of its own.
		#if (cpp || neko || hl)
		__handleLock.acquire();
		#end
		if (__session != session) {
			#if (cpp || neko || hl)
			__handleLock.release();
			#end
			return;
		}
		var wasConnected = __connected;
		__connected = false;
		// Queued for a peer that has gone.
		__dropOutput();
		var relistenFailed = false;
		if (__mode == SERVER && __running) {
			// The same listener takes the next client: the one that went is
			// let go and the name is kept, never anyone's in between.
			if (__activePipe != null && __disconnect(__activePipe)) {
				__listeningPipe = __activePipe;
				__activePipe = null;
			} else {
				if (__activePipe != null) {
					__close(__activePipe);
					__activePipe = null;
				}
				try {
					__listeningPipe = __createInboundPipe(__connectionName);
				} catch (_:Dynamic) {
					__listeningPipe = null;
				}
				if (__listeningPipe == null) {
					__running = false;
					relistenFailed = true;
				}
			}
		} else {
			if (__activePipe != null) {
				__close(__activePipe);
				__activePipe = null;
			}
			__running = false;
		}
		#if (cpp || neko || hl)
		__handleLock.release();
		#end

		switch (reason) {
			case Error(_):
				__dispatchFromReader(Error(reason), session);
			default:
		}

		if (wasConnected) {
			__dispatchFromReader(Close(Reason.Closed), session);
		}

		if (relistenFailed) {
			__dispatchFromReader(Error(Reason.Error("Failed to recreate the local listener.")), session);
		}
	}

	@:noCompletion private function __dispatchPayload(payload:ByteArray):Void {
		if (!__readEnabled) {
			__pushPendingPayload(payload, __session);
			return;
		}

		var message = Data(payload);
		#if (cpp || neko || hl)
		if (!__canDispatchInline()) {
			__queueDispatch(message, __session);
			return;
		}
		#end

		__applyDispatch(message);
	}

	@:noCompletion private function __dispatchLifecycle(message:LocalConnectionDispatch):Void {
		#if (cpp || neko || hl)
		if (!__canDispatchInline()) {
			__queueDispatch(message, __session);
			return;
		}
		#end

		__applyDispatch(message);
	}

	/** From a reader thread, for its session: refused once close() has ended it. **/
	@:noCompletion private function __dispatchFromReader(message:LocalConnectionDispatch, session:Int):Void {
		#if (cpp || neko || hl)
		// A reader thread is never its runtime's: with a runtime, what it
		// reads is handed over, and nothing need be asked. Asking which
		// runtime this thread has would throw and catch for every frame.
		if (__runtime != null) {
			__queueDispatch(message, session);
			return;
		}
		if (!__canDispatchInline()) {
			__queueDispatch(message, session);
			return;
		}
		#end

		// No runtime to hand it to: this thread runs the callbacks itself.
		if (__session == session) {
			__applyDispatch(message);
		}
	}

	@:noCompletion private function __applyDispatch(message:LocalConnectionDispatch):Void {
		try {
			switch (message) {
				case Ready:
					__notifyReady();
					__onReady();
				case Close(reason):
					__notifyClose(reason);
					__onClose(reason);
				case Error(reason):
					__onError(reason);
				case Data(payload):
					if (!__readEnabled) {
						__pushPendingPayload(payload, __session);
						return;
					}
					payload.position = 0;
					__onData(payload);
			}
		} catch (error:Dynamic) {
			__handleCallbackFailure(error);
		}
	}

	@:noCompletion private function __handleCallbackFailure(error:Dynamic):Void {
		// Reported whatever follows: with no onError set, the connection
		// ended without a word of why.
		__callbackThrew(error);
		if (__dispatchFailed) {
			return;
		}

		__dispatchFailed = true;
		__running = false;
		__mode = NONE;
		__clearPendingPayloads();
		__discardQueued();

		// Clear connected state and tear down handles under __handleLock so a
		// concurrent send() cannot write to a handle being closed here.
		#if (cpp || neko || hl)
		__handleLock.acquire();
		#end
		__connected = false;
		if (__activePipe != null) {
			__close(__activePipe);
			__activePipe = null;
		}
		if (__listeningPipe != null) {
			__close(__listeningPipe);
			__listeningPipe = null;
		}
		#if (cpp || neko || hl)
		__handleLock.release();
		#end

		var reason = Reason.Error("Local transport callback failed: " + Std.string(error));
		try {
			__onError(reason);
		} catch (secondError:Dynamic) {
			__callbackThrew(secondError);
		}
	}

	/**
		Reports what a callback threw as the runtime reports a socket
		handler's failure (logged, and dispatched as
		`UncaughtErrorEvent.UNCAUGHT_ERROR`) on the runtime of the thread
		that called it; logged alone on a reader thread, where there is none.
	**/
	@:noCompletion private function __callbackThrew(error:Dynamic):Void {
		var runtime:Null<CrossByte> = CrossByte.__currentOrNull();
		if (runtime != null) {
			runtime.__uncaught(error, UncaughtErrorEvent.SOCKET, this);
			return;
		}
		try {
			Logger.error("A LocalConnection callback threw: " + Std.string(error));
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __flushPendingPayloads():Void {
		var pending:Array<ByteArray> = null;
		#if (cpp || neko || hl)
		__pendingLock.acquire();
		#end
		pending = __pendingPayloads;
		__pendingPayloads = [];
		__uncount(pending);
		#if (cpp || neko || hl)
		__pendingLock.release();
		#end

		for (payload in pending) {
			__dispatchPayload(payload);
		}
	}

	/** Held until reading is enabled, if `session` has not ended; close() clears what is held. **/
	@:noCompletion private function __pushPendingPayload(payload:ByteArray, session:Int):Void {
		#if (cpp || neko || hl)
		__pendingLock.acquire();
		#end
		if (__session == session) {
			__pendingPayloads.push(payload);
			__countInbound(payload.length);
		}
		#if (cpp || neko || hl)
		__pendingLock.release();
		#end
	}

	@:noCompletion private function __clearPendingPayloads():Void {
		#if (cpp || neko || hl)
		__pendingLock.acquire();
		#end
		__uncount(__pendingPayloads);
		__pendingPayloads = [];
		#if (cpp || neko || hl)
		__pendingLock.release();
		#end
	}

	@:noCompletion private function __uncount(payloads:Array<ByteArray>):Void {
		var bytes:Int = 0;
		for (payload in payloads) {
			bytes += payload.length;
		}
		if (bytes != 0) {
			__countInbound(-bytes);
		}
	}

	/*
		What waits to be delivered, in payload bytes: queued for the runtime's
		thread or held until reading is enabled. Counted as a payload is put
		in either and taken out, under the lock of the one it is in, so it is
		exactly what the two hold; atomic adds, since the reader thread reads
		it to decide whether to read without either lock.
	*/
	@:noCompletion private inline function __countInbound(bytes:Int):Void {
		#if cpp
		untyped __cpp__("_hx_atomic_add(&{0}, {1})", __inQueued, bytes);
		#else
		__inQueued += bytes;
		#end
	}

	/** Whether as much waits to be delivered as `maxQueuedBytes` allows. **/
	@:noCompletion private inline function __inboundFull():Bool {
		#if cpp
		final queued:Int = untyped __cpp__("_hx_atomic_load(&{0})", __inQueued);
		#else
		final queued:Int = __inQueued;
		#end
		return maxQueuedBytes > 0 && queued >= maxQueuedBytes;
	}

	#if (cpp || neko || hl)
	@:noCompletion private inline function __canDispatchInline():Bool {
		if (__runtime == null) {
			return true;
		}

		// Asked without an exception for the answer "none".
		return CrossByte.__currentOrNull() == __runtime;
	}

	/**
	 * Hands a dispatch from the reader thread to the runtime's thread: queued,
	 * and a delivery posted to the runtime (`CrossByte.__post`, its one
	 * thread-safe way in) unless one is on its way already.
	 *
	 * Not a listener on the runtime's tick: that would have to be attached
	 * on the runtime's thread (`EventDispatcher` is not thread-safe, and a
	 * reader thread's attach racing a listener change there could be lost
	 * for good) and would run every tick for every connection, idle or not.
	 * A post runs only when there is something to deliver. It is delivered
	 * at the runtime's next tick; a runtime asleep between ticks is woken by
	 * the post.
	 *
	 * Queued only while `session` is current, checked under the lock close()
	 * ends it under: a dispatch refused here is one close() would otherwise
	 * have had to discard after the fact, and one queued in time it discards.
	 */
	@:noCompletion private function __queueDispatch(message:LocalConnectionDispatch, session:Int):Void {
		var post = false;
		__dispatchLock.acquire();
		if (__session == session) {
			// Counted as it goes in, under the lock __discardQueued takes it
			// out under, so the count is what the queue holds.
			switch (message) {
				case Data(payload):
					__countInbound(payload.length);
				default:
			}
			__dispatchQueue.add(message);
			if (!__dispatchPending) {
				__dispatchPending = true;
				post = true;
			}
		}
		__dispatchLock.release();
		if (post) {
			__runtime.__post(__drain);
		}
	}

	/**
		Delivers what is queued, on the runtime's thread, for as long as
		`DRAIN_BUDGET` allows; what is left waits for another delivery, posted
		for the next tick.
	**/
	@:noCompletion private function __drainDispatchQueue():Void {
		// Lowered before draining, so a dispatch queued while this runs posts
		// another delivery.
		__dispatchLock.acquire();
		__dispatchPending = false;
		__dispatchLock.release();

		final deadline:Float = haxe.Timer.stamp() + DRAIN_BUDGET;
		var delivered:Int = 0;
		while (true) {
			var message = __dispatchQueue.pop(false);
			if (message == null) {
				return;
			}
			switch (message) {
				case Data(payload):
					__countInbound(-payload.length);
				default:
			}
			__applyDispatch(message);
			// The clock is read every sixteen, not every one.
			if ((++delivered & 15) == 0 && haxe.Timer.stamp() >= deadline) {
				break;
			}
		}

		// Out of time with more possibly queued: the rest at the next tick.
		var post = false;
		__dispatchLock.acquire();
		if (!__dispatchPending) {
			__dispatchPending = true;
			post = true;
		}
		__dispatchLock.release();
		if (post && __runtime != null) {
			__runtime.__post(__drain);
		}
	}
	#else
	@:noCompletion private inline function __canDispatchInline():Bool {
		return true;
	}

	@:noCompletion private function __drainDispatchQueue():Void {}
	#end

	/**
		Discards what is queued for delivery: it belongs to the connection
		being torn down, and left here, a later listen()/connect() on this
		object would deliver it.
	**/
	@:noCompletion private function __discardQueued():Void {
		#if (cpp || neko || hl)
		__dispatchLock.acquire();
		while (true) {
			var message = __dispatchQueue.pop(false);
			if (message == null) {
				break;
			}
			switch (message) {
				case Data(payload):
					__countInbound(-payload.length);
				default:
			}
		}
		__dispatchPending = false;
		__dispatchLock.release();
		#end
	}

	@:noCompletion private inline function __captureRuntime():Void {
		try {
			__runtime = CrossByte.current();
		} catch (_:IllegalOperationError) {
			__runtime = null;
		} catch (_:Dynamic) {
			__runtime = null;
		}
	}

	@:noCompletion private inline function __timestamp():Float {
		if (__runtime != null) {
			return __runtime.uptime;
		}

		var runtime = CrossByte.__currentOrNull();
		return runtime != null ? runtime.uptime : 0.0;
	}

	@:noCompletion private inline function get_remoteAddress():String {
		return __connectionName != null ? __connectionName : "";
	}

	@:noCompletion private inline function get_remotePort():Int {
		return 0;
	}

	@:noCompletion private inline function get_localAddress():String {
		return __connectionName != null ? __connectionName : "";
	}

	@:noCompletion private inline function get_localPort():Int {
		return 0;
	}

	@:noCompletion private inline function get_connected():Bool {
		return __connected;
	}

	@:noCompletion private inline function get_bytesPending():Int {
		// Read without the lock: a count a moment old.
		return __outQueued;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	@:noCompletion private inline function set_readEnabled(value:Bool):Bool {
		__readEnabled = value;
		if (value) {
			__flushPendingPayloads();
		}
		return value;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	@:noCompletion private inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		__onData = value != null ? value : __noopData;
		return __onData;
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return __onClose;
	}

	@:noCompletion private inline function set_onClose(value:Reason->Void):Reason->Void {
		__onClose = value != null ? value : __noopClose;
		return __onClose;
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		__onError = value != null ? value : __noopError;
		return __onError;
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __onReady;
	}

	@:noCompletion private inline function set_onReady(value:Void->Void):Void->Void {
		__onReady = value != null ? value : __noopReady;
		return __onReady;
	}

	/** Writes raw bytes to a native local handle. SharedChannel forwards through these helpers for tests. */
	@:noCompletion private static function __write(pipe:LocalConnectionHandle, data:BytesData, size:Int):Bool {
		#if cpp
		return NativeLocalConnection.__write(pipe, Pointer.ofArray(data), size);
		#else
		return false;
		#end
	}

	/**
		As much of `data` from `offset`, `size` bytes, as the channel takes now,
		without waiting: the bytes written, 0 when it is full, -1 when the
		connection is gone.
	**/
	@:noCompletion private static function __writeSome(pipe:LocalConnectionHandle, data:BytesData, offset:Int, size:Int):Int {
		#if cpp
		if (size <= 0) {
			return 0;
		}
		return NativeLocalConnection.__writeSome(pipe, Pointer.arrayElem(data, offset), size);
		#else
		return -1;
		#end
	}

	/** Lets a listener's client go, keeping it listening for the next; `false` if it cannot. **/
	@:noCompletion private static function __disconnect(pipe:LocalConnectionHandle):Bool {
		#if cpp
		return NativeLocalConnection.__disconnect(pipe);
		#else
		return false;
		#end
	}

	/** Connects to a native local endpoint handle. SharedChannel forwards through these helpers for tests. */
	@:noCompletion private static function __connect(name:String, timeoutMs:Int = 5000):LocalConnectionHandle {
		#if cpp
		return NativeLocalConnection.__connectWithTimeout(name, timeoutMs);
		#else
		return null;
		#end
	}

	@:noCompletion private static function __createInboundPipe(name:String):LocalConnectionHandle {
		#if cpp
		return NativeLocalConnection.__createInboundPipe(name);
		#else
		return null;
		#end
	}

	/** Whether the last listen or connect on this thread failed for something under the name that is not this user's. **/
	@:noCompletion private static function __notOwned():Bool {
		#if cpp
		return NativeLocalConnection.__lastError() == NativeLocalConnection.ERROR_NOT_OWNED;
		#else
		return false;
		#end
	}

	@:noCompletion private static function __notOwnedError(name:String):IOError {
		return new IOError('LocalConnection "$name": what is under the name is not this user\'s own, and is not used'
			+ ': another user made it, or others can reach it (on Linux and macOS, /tmp/crossbyte-<uid> must be a directory '
			+ 'of this user\'s with mode 0700)');
	}

	/** What the reader waits on for `pipe`: on Linux and macOS its socket, on Windows its doorbell; -1 for nothing. Under __handleLock. **/
	@:noCompletion private static function __descriptorOf(pipe:LocalConnectionHandle):Int {
		#if cpp
		return NativeLocalConnection.__descriptorOf(pipe);
		#else
		return -1;
		#end
	}

	/**
		Waits up to `seconds` for `fd` to be readable (`read`) or writable
		(`write`), on Linux and macOS, and on Windows for the pipe's doorbell
		to ring, which its peer rings as it writes, makes room or goes:
		whether it woke for that. For `fd` -1, a plain wait.
	**/
	@:noCompletion private static function __waitForWork(fd:Int, read:Bool, write:Bool, seconds:Float):Bool {
		#if cpp
		return NativeLocalConnection.__waitForWork(fd, read, write, Math.ceil(seconds * 1000));
		#else
		crossbyte._internal.system.Sleep.sleep(seconds);
		return false;
		#end
	}

	/** Tests only: the buffer size asked of each socket connected or taken from now on; 0 leaves the system's. Nothing on Windows. **/
	@:noCompletion private static function __setSocketBufferForTest(bytes:Int):Void {
		#if cpp
		NativeLocalConnection.__setSocketBufferForTest(bytes);
		#end
	}

	/** Tests only: whether a listener's pipe admits anyone but this user and SYSTEM, or another owns it. Always false off Windows. **/
	@:noCompletion private static function __admitsOthersForTest(pipe:LocalConnectionHandle):Bool {
		#if cpp
		return NativeLocalConnection.__admitsOthersForTest(pipe);
		#else
		return false;
		#end
	}

	/** Keeps a listener's name from looking unused to a cleaner of old files; nothing for any other handle. **/
	@:noCompletion private static function __keepName(pipe:LocalConnectionHandle):Void {
		#if cpp
		if (pipe != null) {
			NativeLocalConnection.__keepName(pipe);
		}
		#end
	}

	@:noCompletion private static function __accept(pipe:LocalConnectionHandle):Bool {
		#if cpp
		return NativeLocalConnection.__accept(pipe);
		#else
		return false;
		#end
	}

	@:noCompletion private static function __isOpen(pipe:LocalConnectionHandle):Bool {
		#if cpp
		return NativeLocalConnection.__isOpen(pipe);
		#else
		return false;
		#end
	}

	@:noCompletion private static function __read(pipe:LocalConnectionHandle, buffer:BytesData, size:Int):Int {
		#if cpp
		return NativeLocalConnection.__read(pipe, Pointer.ofArray(buffer), size);
		#else
		return -1;
		#end
	}

	@:noCompletion private static function __getBytesAvailable(pipe:LocalConnectionHandle):Int {
		#if cpp
		return NativeLocalConnection.__getBytesAvailable(pipe);
		#else
		return 0;
		#end
	}

	@:noCompletion private static function __close(pipe:LocalConnectionHandle):Void {
		#if cpp
		NativeLocalConnection.__close(pipe);
		#end
	}

	@:noCompletion private static inline function __requireSupported():Void {
		#if !cpp
		throw NativeOnly.error("LocalConnection");
		#end
	}

	@:noCompletion private static inline function __requireConnectionName(connectionName:String):Void {
		if (connectionName == null || connectionName.length == 0) {
			throw new ArgumentError("Connection name must not be empty.");
		}
	}

	@:noCompletion private static inline function __noopReady():Void {}

	@:noCompletion private static inline function __noopData(_:ByteArrayInput):Void {}

	@:noCompletion private static inline function __noopClose(_:Reason):Void {}

	@:noCompletion private static inline function __noopError(_:Reason):Void {}
}
#end
