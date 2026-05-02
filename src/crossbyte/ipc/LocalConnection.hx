package crossbyte.ipc;

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
	@:noCompletion private var __receiveBuffer:ByteArray;
	@:noCompletion private var __onData:ByteArrayInput->Void = __noopData;
	@:noCompletion private var __onClose:Reason->Void = __noopClose;
	@:noCompletion private var __onError:Reason->Void = __noopError;
	@:noCompletion private var __onReady:Void->Void = __noopReady;
	#if (cpp || neko || hl)
	@:noCompletion private var __dispatchQueue:Deque<LocalConnectionDispatch>;
	@:noCompletion private var __dispatchLock:Mutex;
	@:noCompletion private var __pendingLock:Mutex;
	#end
	@:noCompletion private var __dispatchListener:TickEvent->Void;
	@:noCompletion private var __dispatchAttached:Bool = false;
	@:noCompletion private var __pendingPayloads:Array<ByteArray> = [];

	public function new() {
		__captureRuntime();
		__receiveBuffer = new ByteArray();
		#if (cpp || neko || hl)
		__dispatchQueue = new Deque();
		__dispatchLock = new Mutex();
		__pendingLock = new Mutex();
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
		__mode = SERVER;
		__connectionName = connectionName;
		__running = true;

		#if cpp
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
				__runLoop();
			}
		});

		if (handleQueue.pop(true) == null) {
			__running = false;
			__mode = NONE;
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
		__dispatchLifecycle(Ready);

		#if (cpp || neko || hl)
		Thread.create(__runLoop);
		#else
		__runLoop();
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

		if (!__write(__activePipe, frameBytes.getData(), frameBytes.length)) {
			__dispatchLifecycle(Error(Reason.Error("Local transport write failed.")));
			return;
		}

		outTimestamp = __timestamp();
	}

	public function close():Void {
		var wasConnected = __connected;
		__running = false;
		__connected = false;
		__mode = NONE;
		__connectionName = null;
		__receiveBuffer.clear();
		__clearPendingPayloads();
		__detachDispatchListener();

		if (__activePipe != null) {
			__close(__activePipe);
			__activePipe = null;
		}
		if (__listeningPipe != null) {
			__close(__listeningPipe);
			__listeningPipe = null;
		}

		if (wasConnected) {
			__onClose(Reason.Closed);
		}
	}

	@:noCompletion private function __runLoop():Void {
		var chunk:Bytes = Bytes.alloc(BUFFER_SIZE);

		while (__running) {
			if (__mode == SERVER && __activePipe == null && __listeningPipe != null && __accept(__listeningPipe)) {
				__activePipe = __listeningPipe;
				__listeningPipe = null;
				__connected = true;
				__dispatchLifecycle(Ready);
			}

			var pipe = __activePipe;
			if (pipe != null) {
				var available = __getBytesAvailable(pipe);
				if (available < 0 || (available == 0 && !__isOpen(pipe))) {
					__disconnectActive(Reason.Closed);
				} else if (available > 0) {
					if (available > MAX_FRAME_SIZE + 4) {
						__disconnectActive(Reason.Error("Local transport received an oversized frame."));
					} else {
						var bytesRemaining = available;
						var aggregate = new BytesBuffer();
						var readOk = true;

						while (bytesRemaining > 0) {
							var length = bytesRemaining > BUFFER_SIZE ? BUFFER_SIZE : bytesRemaining;
							if (__read(pipe, chunk.getData(), length) != 0) {
								readOk = false;
								break;
							}
							aggregate.addBytes(chunk, 0, length);
							bytesRemaining -= length;
						}

						if (readOk) {
							__appendReceivedBytes(aggregate.getBytes());
						} else {
							__disconnectActive(Reason.Error("Local transport read failed."));
						}
					}
				}
			}

			Sys.sleep(0.001);
		}

		if (__activePipe != null) {
			__close(__activePipe);
			__activePipe = null;
		}
		if (__listeningPipe != null) {
			__close(__listeningPipe);
			__listeningPipe = null;
		}
	}

	@:noCompletion private function __appendReceivedBytes(received:Bytes):Void {
		if (received == null || received.length == 0) {
			return;
		}

		__receiveBuffer.position = __receiveBuffer.length;
		__receiveBuffer.writeBytes(received, 0, received.length);
		__receiveBuffer.position = 0;

		while (__receiveBuffer.bytesAvailable >= 4) {
			var frameStart = __receiveBuffer.position;
			var payloadLength = __receiveBuffer.readInt();
			if (payloadLength < 0 || payloadLength > MAX_FRAME_SIZE) {
				__disconnectActive(Reason.Error("Local transport received an invalid frame."));
				return;
			}

			if (__receiveBuffer.bytesAvailable < payloadLength) {
				__receiveBuffer.position = frameStart;
				break;
			}

			var payload = new ByteArray();
			if (payloadLength > 0) {
				__receiveBuffer.readBytes(payload, 0, payloadLength);
			}
			payload.position = 0;
			inTimestamp = __timestamp();
			__dispatchPayload(payload);
		}

		__compactReceiveBuffer();
	}

	@:noCompletion private function __compactReceiveBuffer():Void {
		var remaining = __receiveBuffer.bytesAvailable;
		if (remaining <= 0) {
			__receiveBuffer.clear();
			__receiveBuffer.position = 0;
			return;
		}

		var unread = new ByteArray();
		__receiveBuffer.readBytes(unread, 0, remaining);
		unread.position = 0;
		__receiveBuffer.clear();
		__receiveBuffer.writeBytes(unread, 0, unread.length);
		__receiveBuffer.position = 0;
	}

	@:noCompletion private function __disconnectActive(reason:Reason):Void {
		if (__activePipe != null) {
			__close(__activePipe);
			__activePipe = null;
		}

		var wasConnected = __connected;
		__connected = false;
		__receiveBuffer.clear();

		switch (reason) {
			case Error(_):
				__dispatchLifecycle(Error(reason));
			default:
		}

		if (wasConnected) {
			__dispatchLifecycle(Close(Reason.Closed));
		}

		if (__mode == SERVER && __running) {
			try {
				__listeningPipe = __createInboundPipe(__connectionName);
			} catch (_:Dynamic) {
				__running = false;
				__dispatchLifecycle(Error(Reason.Error("Failed to recreate the local listener.")));
			}
		} else {
			__running = false;
		}
	}

	@:noCompletion private function __dispatchPayload(payload:ByteArray):Void {
		if (!__readEnabled) {
			__pushPendingPayload(payload);
			return;
		}

		var message = Data(payload);
		#if (cpp || neko || hl)
		if (!__canDispatchInline()) {
			__dispatchQueue.add(message);
			__ensureDispatchListener();
			return;
		}
		#end

		__applyDispatch(message);
	}

	@:noCompletion private function __dispatchLifecycle(message:LocalConnectionDispatch):Void {
		#if (cpp || neko || hl)
		if (!__canDispatchInline()) {
			__dispatchQueue.add(message);
			__ensureDispatchListener();
			return;
		}
		#end

		__applyDispatch(message);
	}

	@:noCompletion private function __applyDispatch(message:LocalConnectionDispatch):Void {
		switch (message) {
			case Ready:
				__onReady();
			case Close(reason):
				__onClose(reason);
			case Error(reason):
				__onError(reason);
			case Data(payload):
				if (!__readEnabled) {
					__pushPendingPayload(payload);
					return;
				}
				payload.position = 0;
				__onData(payload);
		}
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

	@:noCompletion private function __pushPendingPayload(payload:ByteArray):Void {
		#if (cpp || neko || hl)
		__pendingLock.acquire();
		__pendingPayloads.push(payload);
		__pendingLock.release();
		#else
		__pendingPayloads.push(payload);
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

	@:noCompletion private function __ensureDispatchListener():Void {
		if (__runtime == null) {
			return;
		}

		__dispatchLock.acquire();
		var shouldAttach = !__dispatchAttached;
		if (shouldAttach) {
			__dispatchAttached = true;
		}
		__dispatchLock.release();

		if (shouldAttach) {
			__runtime.addEventListener(TickEvent.TICK, __dispatchListener);
		}
	}
	#else
	@:noCompletion private inline function __canDispatchInline():Bool {
		return true;
	}
	#end

	@:noCompletion private function __flushDispatchQueue(_event:TickEvent):Void {
		#if (cpp || neko || hl)
		var drained = false;
		var processed = 0;
		while (true) {
			if (processed >= DISPATCH_BUDGET_PER_TICK) {
				break;
			}
			var message = __dispatchQueue.pop(false);
			if (message == null) {
				drained = true;
				break;
			}
			__applyDispatch(message);
			processed++;
		}
		if (!drained) {
			return;
		}
		#end

		__detachDispatchListener();
	}

	@:noCompletion private function __detachDispatchListener():Void {
		var runtime = __runtime;
		if (runtime == null) {
			return;
		}

		#if (cpp || neko || hl)
		__dispatchLock.acquire();
		var shouldDetach = __dispatchAttached;
		__dispatchAttached = false;
		__dispatchLock.release();
		#else
		var shouldDetach = __dispatchAttached;
		__dispatchAttached = false;
		#end

		if (shouldDetach) {
			runtime.removeEventListener(TickEvent.TICK, __dispatchListener);
		}
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
