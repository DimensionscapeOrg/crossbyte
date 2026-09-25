package crossbyte.ipc;

// Not built for the browser. Local IPC means an OS channel between processes on one machine, and a page has neither the channel nor the processes.
#if !js

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;
import haxe.io.Bytes;
import haxe.io.BytesData;
import haxe.io.BytesBuffer;
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
	// The reader thread of that session has ended; queued after all it sent.
	Ended(session:Int);
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
 */
@:access(haxe.io.Bytes)
#if cpp
@:access(crossbyte.ipc._internal.NativeLocalConnection)
#end
class LocalConnection implements INetConnection {
	public static inline var isSupported:Bool = #if cpp true #else false #end;

	/** Maximum payload size accepted by the framing layer, in bytes. */
	public static inline var MAX_FRAME_SIZE:Int = 8 * 1024 * 1024;
	@:noCompletion private static inline var DISPATCH_BUDGET_PER_TICK:Int = 32;

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
	 * Connection timeout in milliseconds used by `connect()`.
	 *
	 * `0` performs an immediate probe without waiting.
	 */
	public var timeout:Int = 5000;
	public var inTimestamp(default, null):Float = 0;
	public var outTimestamp(default, null):Float = 0;

	@:noCompletion private static inline var BUFFER_SIZE:Int = 4096;

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
	@:noCompletion private var __dispatchListener:TickEvent->Void;
	// Touched only on the runtime's thread: the listener is attached by
	// listen()/connect() and removed by close(), never by the reader thread.
	@:noCompletion private var __dispatchAttached:Bool = false;
	// Raised under __dispatchLock by whichever thread queues a dispatch.
	@:noCompletion private var __dispatchPending:Bool = false;
	// Advanced by close(), which listen() and connect() begin with, so a
	// reader thread can say which session it belonged to.
	@:noCompletion private var __session:Int = 0;
	@:noCompletion private var __pendingPayloads:Array<ByteArray> = [];
	@:noCompletion private var __dispatchFailed:Bool = false;

	public function new() {
		__captureRuntime();
		#if (cpp || neko || hl)
		__dispatchQueue = new Deque();
		__dispatchLock = new Mutex();
		__pendingLock = new Mutex();
		__handleLock = new Mutex();
		#end
		__dispatchListener = __flushDispatchQueue;
	}

	/**
	 * Starts listening for a local peer on the given pipe name.
	 *
	 * The connection becomes `connected == true` only after a client attaches.
	 *
	 * @param connectionName Named local IPC endpoint to listen on.
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
		__attachDispatchListener();

		#if cpp
		var session = __session;
		var handleQueue:Deque<LocalConnectionHandle> = new Deque();
		Thread.create(() -> {
			var handle:LocalConnectionHandle = null;
			try {
				handle = __createInboundPipe(connectionName);
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
			__detachDispatchListener();
			throw new ArgumentError("Connection name is already in use or invalid");
		}
		#end
	}

	/**
	 * Connects to a listening local endpoint.
	 *
	 * @param connectionName Named local IPC endpoint to connect to.
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
			__mode = NONE;
			var reason = Reason.Error("Failed to connect to local endpoint.");
			__dispatchLifecycle(Error(reason));
			throw new ArgumentError("Connection name is unavailable or invalid");
		}

		__activePipe = handle;
		__connected = true;
		__running = true;
		__attachDispatchListener();
		__dispatchLifecycle(Ready);

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
		// below so a concurrent close() cannot tear the handle down mid-write.
		if (!__connected || __activePipe == null || !__isOpen(__activePipe)) {
			__dispatchLifecycle(Error(Reason.Closed));
			return;
		}

		if (data == null || data.length > MAX_FRAME_SIZE) {
			__dispatchLifecycle(Error(Reason.Error("Invalid local payload size.")));
			return;
		}

		var frame = new ByteArray();
		frame.writeInt(data.length);
		frame.writeBytes(data, 0, data.length);
		frame.position = 0;
		var frameBytes:Bytes = cast frame;

		// Re-validate and write the handle atomically with respect to the reader
		// thread's close/disconnect so the handle cannot be closed (and the OS
		// handle reused) between the check and the write. Lifecycle errors are
		// dispatched after releasing the lock to avoid re-entering callbacks while
		// holding it.
		#if (cpp || neko || hl)
		__handleLock.acquire();
		#end
		var failure:LocalConnectionDispatch = null;
		var wrote = false;
		var pipe = __activePipe;
		if (!__connected || pipe == null || !__isOpen(pipe)) {
			failure = Error(Reason.Closed);
		} else if (!__write(pipe, frameBytes.getData(), frameBytes.length)) {
			failure = Error(Reason.Error("Local transport write failed."));
		} else {
			wrote = true;
		}
		#if (cpp || neko || hl)
		__handleLock.release();
		#end

		if (failure != null) {
			__dispatchLifecycle(failure);
			return;
		}

		if (wrote) {
			outTimestamp = __timestamp();
		}
	}

	public function close():Void {
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
		__detachDispatchListener();

		// Clear connected state and tear down the handles under __handleLock so a
		// concurrent send() observes the closed connection and cannot write to a
		// handle that is being closed.
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

		if (wasConnected) {
			try {
				__onClose(Reason.Closed);
			} catch (_:Dynamic) {}
		}
	}

	/**
	 * The reader thread of one session, `session`.
	 *
	 * It acts only for that session. close() ends a session and listen() or
	 * connect() start the next at once, while this thread sleeps between
	 * polls: it used to wake to find `__running` true again and carry on
	 * beside the next session's reader -- reading its pipe, splitting its
	 * bytes, tearing it down when the read that lost the race found nothing,
	 * and making it a listener of its own. So what this thread does to the
	 * connection it does under `__handleLock` having checked the session is
	 * still its own, and what it hands on carries the session and is refused
	 * once it has ended.
	 */
	@:noCompletion private function __runLoop(session:Int):Void {
		var chunk:Bytes = Bytes.alloc(BUFFER_SIZE);
		// This session's framing, and this thread's alone: no reader shares
		// one with another, and close() never clears one being written to.
		var framing = new ByteArray();

		while (__running && __session == session) {
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
			}

			// Polled and read under the lock too: both are immediate, and a
			// handle closed and reused by the OS cannot be read as this one.
			var received:Bytes = null;
			var failure:Reason = null;
			var pipe = __activePipe;
			if (pipe != null) {
				var available = __getBytesAvailable(pipe);
				if (available < 0 || (available == 0 && !__isOpen(pipe))) {
					failure = Reason.Closed;
				} else if (available > MAX_FRAME_SIZE + 4) {
					failure = Reason.Error("Local transport received an oversized frame.");
				} else if (available > 0) {
					var bytesRemaining = available;
					var aggregate = new BytesBuffer();
					while (bytesRemaining > 0) {
						var length = bytesRemaining > BUFFER_SIZE ? BUFFER_SIZE : bytesRemaining;
						if (__read(pipe, chunk.getData(), length) != 0) {
							failure = Reason.Error("Local transport read failed.");
							break;
						}
						aggregate.addBytes(chunk, 0, length);
						bytesRemaining -= length;
					}
					if (failure == null) {
						received = aggregate.getBytes();
					}
				}
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
			}

			Sys.sleep(0.001);
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

		// A connection that ended by itself -- its peer went away -- is let go
		// of by the runtime once what it queued has been delivered. The
		// listener was removed after each drain before, so a dead connection
		// was never held; held until close(), one would be for good.
		if (__runtime != null) {
			__queueDispatch(Ended(session), session);
		}
		#end
	}

	/** Frames `received` into `framing` and hands on each whole one; false for an invalid frame. **/
	@:noCompletion private function __appendReceivedBytes(framing:ByteArray, received:Bytes, session:Int):Bool {
		if (received == null || received.length == 0) {
			return true;
		}

		framing.position = framing.length;
		framing.writeBytes(received, 0, received.length);
		framing.position = 0;

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

	@:noCompletion private function __compactReceiveBuffer(framing:ByteArray):Void {
		var remaining = framing.bytesAvailable;
		if (remaining <= 0) {
			framing.clear();
			framing.position = 0;
			return;
		}

		var unread = new ByteArray();
		framing.readBytes(unread, 0, remaining);
		unread.position = 0;
		framing.clear();
		framing.writeBytes(unread, 0, unread.length);
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
		if (__activePipe != null) {
			__close(__activePipe);
			__activePipe = null;
		}
		var relistenFailed = false;
		if (__mode == SERVER && __running) {
			try {
				__listeningPipe = __createInboundPipe(__connectionName);
			} catch (_:Dynamic) {
				__running = false;
				relistenFailed = true;
			}
		} else {
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
					__onReady();
				case Close(reason):
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
				case Ended(session):
					// One from a session close() has already ended is stale.
					if (session == __session) {
						__detachDispatchListener();
					}
			}
		} catch (error:Dynamic) {
			__handleCallbackFailure(error);
		}
	}

	@:noCompletion private function __handleCallbackFailure(error:Dynamic):Void {
		if (__dispatchFailed) {
			return;
		}

		__dispatchFailed = true;
		__running = false;
		__mode = NONE;
		__clearPendingPayloads();
		__detachDispatchListener();

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
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __flushPendingPayloads():Void {
		var pending:Array<ByteArray> = null;
		#if (cpp || neko || hl)
		__pendingLock.acquire();
		pending = __pendingPayloads;
		__pendingPayloads = [];
		__pendingLock.release();
		#else
		pending = __pendingPayloads;
		__pendingPayloads = [];
		#end

		for (payload in pending) {
			__dispatchPayload(payload);
		}
	}

	/** Held until reading is enabled, if `session` has not ended; close() clears what is held. **/
	@:noCompletion private function __pushPendingPayload(payload:ByteArray, session:Int):Void {
		#if (cpp || neko || hl)
		__pendingLock.acquire();
		if (__session == session) {
			__pendingPayloads.push(payload);
		}
		__pendingLock.release();
		#else
		if (__session == session) {
			__pendingPayloads.push(payload);
		}
		#end
	}

	@:noCompletion private function __clearPendingPayloads():Void {
		#if (cpp || neko || hl)
		__pendingLock.acquire();
		__pendingPayloads = [];
		__pendingLock.release();
		#else
		__pendingPayloads = [];
		#end
	}

	#if (cpp || neko || hl)
	@:noCompletion private inline function __canDispatchInline():Bool {
		if (__runtime == null) {
			return true;
		}

		try {
			return CrossByte.current() == __runtime;
		} catch (_:Dynamic) {
			return false;
		}
	}

	/**
	 * Hands a dispatch from the reader thread to the runtime's thread.
	 *
	 * The reader thread used to attach the tick listener itself, on demand.
	 * `EventDispatcher` is not thread-safe -- adding a listener reads the list,
	 * copies it and stores the copy -- so an attach racing any listener change
	 * on the runtime's own thread could be lost while `__dispatchAttached` said
	 * it was made, and from then on nothing queued was ever delivered: a
	 * listening side that never saw `onReady` nor its first message. The
	 * listener is now attached by listen()/connect() on the runtime's thread,
	 * and this thread only queues and raises a flag.
	 *
	 * Queued only while `session` is current, checked under the lock close()
	 * ends it under: a dispatch refused here is one close() would otherwise
	 * have had to discard after the fact, and one queued in time it discards.
	 */
	@:noCompletion private function __queueDispatch(message:LocalConnectionDispatch, session:Int):Void {
		__dispatchLock.acquire();
		if (__session == session) {
			__dispatchQueue.add(message);
			__dispatchPending = true;
		}
		__dispatchLock.release();
	}
	#else
	@:noCompletion private inline function __canDispatchInline():Bool {
		return true;
	}
	#end

	@:noCompletion private function __attachDispatchListener():Void {
		if (__runtime == null || __dispatchAttached) {
			return;
		}
		__dispatchAttached = true;
		__runtime.addEventListener(TickEvent.TICK, __dispatchListener);
	}

	@:noCompletion private function __flushDispatchQueue(_event:TickEvent):Void {
		#if (cpp || neko || hl)
		// Read without the lock: a stale `false` costs one tick, and an idle
		// connection costs a field read a tick rather than a mutex.
		if (!__dispatchPending) {
			return;
		}
		// Lowered before draining, so a dispatch queued while this runs raises
		// it again and is picked up next tick at the latest.
		__dispatchLock.acquire();
		__dispatchPending = false;
		__dispatchLock.release();

		for (_ in 0...DISPATCH_BUDGET_PER_TICK) {
			var message = __dispatchQueue.pop(false);
			if (message == null) {
				return;
			}
			__applyDispatch(message);
		}

		// Out of budget with more possibly queued: look again next tick.
		__dispatchLock.acquire();
		__dispatchPending = true;
		__dispatchLock.release();
		#end
	}

	@:noCompletion private function __detachDispatchListener():Void {
		#if (cpp || neko || hl)
		// What is still queued belongs to the connection being torn down; left
		// here, a later listen()/connect() on this object would deliver it.
		while (__dispatchQueue.pop(false) != null) {}
		__dispatchLock.acquire();
		__dispatchPending = false;
		__dispatchLock.release();
		#end

		var runtime = __runtime;
		if (runtime == null || !__dispatchAttached) {
			return;
		}
		__dispatchAttached = false;
		runtime.removeEventListener(TickEvent.TICK, __dispatchListener);
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

		try {
			var runtime = CrossByte.current();
			return runtime != null ? runtime.uptime : 0.0;
		} catch (_:Dynamic) {
			return 0.0;
		}
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
		if (!isSupported) {
			throw new ArgumentError("LocalConnection is only supported on native cpp targets.");
		}
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
