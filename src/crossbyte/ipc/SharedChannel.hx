package crossbyte.ipc;

// Not built for any JavaScript target (Node included, which has no threads): shared memory and IPC handles between OS processes.
#if !js

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
#if !cpp
import crossbyte.crypto._internal.NativeOnly;
#end
import crossbyte.events.EventDispatcher;
import crossbyte.events.StatusEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.UncaughtErrorEvent;
import crossbyte.utils.Logger;
import crossbyte.io.ByteArray;
import crossbyte.Object;
import haxe.Timer;
import crossbyte._internal.serial.BoundedUnserializer;
import haxe.Serializer;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/**
 * `SharedChannel` is CrossByte's higher-level local message IPC surface.
 *
 * It preserves the classic method-name plus serialized-arguments programming
 * model that used to live on `LocalConnection`, but now runs on top of the
 * low-level byte-oriented `LocalConnection` transport.
 *
 * A channel name is its user's own, as a `LocalConnection` name is: the
 * processes of one user meet over it, those of two users never do, and what
 * another user put under it is refused with an `IOError` -- by `connect`, or
 * by `send` as an error `StatusEvent`.
 */
@:access(haxe.Serializer)
@:access(crossbyte.ipc.LocalConnection)
class SharedChannel extends EventDispatcher {
	/**
	 * Whether this target has the transport underneath, `LocalConnection`:
	 * natively (cpp) on Windows, Linux and macOS. Elsewhere `connect` and
	 * `send` throw an `IllegalOperationError` naming the target.
	 */
	public static inline var isSupported:Bool = LocalConnection.isSupported;

	/**
	 * The object that handles incoming messages.
	 * This should contain methods matching the message names sent by peers.
	 *
	 * A message naming no method of it, or whose arguments cannot be read --
	 * not Haxe serialization, naming a class this build does not have, or
	 * nested more than 256 deep -- is dropped.
	 *
	 * A method that throws is reported as a callback the runtime runs is:
	 * logged with `Logger.error`, and dispatched as
	 * `UncaughtErrorEvent.UNCAUGHT_ERROR` (source `POSTED`, origin this
	 * channel) on the runtime the channel was connected on. The channel
	 * goes on listening, and the next message is delivered as usual. A
	 * channel connected on a thread no runtime belongs to calls its client
	 * on its reader thread, and only logs what a method throws.
	 */
	public var client:Object;
	/**
	 * How long, in milliseconds, `send` waits on the calling thread for
	 * something to listen on a channel name it has no connection to yet;
	 * past it, the send fails with an error `StatusEvent`. The default is
	 * 5,000 (five seconds). It is `LocalConnection.timeout` for the
	 * connection underneath.
	 *
	 * 0 (or less) means no deadline: the send waits until something
	 * listens, however long that is. It used to make a single try. One try
	 * is what any timeout of 50 or less makes.
	 */
	public var timeout:Int = 5000;

	@:noCompletion private var __listener:LocalConnection;
	// A connection to each destination sent to lately, by name. It was one
	// connection, closed and dialled again whenever a send went somewhere
	// other than where the last one did, so two destinations sent to in turn
	// cost a connect each send. One is closed after TIME_OUT without a send,
	// and the least recently used when a new one would pass MAX_OUTBOUND:
	// each connection has a reader thread.
	@:noCompletion private var __outbound:Map<String, OutboundLink> = new Map();
	@:noCompletion private var __outboundCount:Int = 0;
	@:noCompletion private var __serializer:Serializer;
	@:noCompletion private var __outboundTimeout:Timer;
	@:noCompletion private var __runtime:CrossByte;
	#if (cpp || neko || hl)
	@:noCompletion private var __dispatchQueue:Deque<Bytes>;
	@:noCompletion private var __dispatchLock:Mutex;
	#end
	@:noCompletion private var __dispatchListener:TickEvent->Void;
	// Touched only on the runtime's thread; see LocalConnection.__queueDispatch.
	@:noCompletion private var __dispatchAttached:Bool = false;
	// Raised under __dispatchLock by whichever thread queues a message.
	@:noCompletion private var __dispatchPending:Bool = false;
	@:noCompletion private var __running:Bool = false;

	@:noCompletion private static inline var TIME_OUT:Int = 45000;
	@:noCompletion private static inline var MAX_OUTBOUND:Int = 16;
	@:noCompletion private static inline var MAX_METHOD_LENGTH:Int = 256;
	@:noCompletion private static inline var MAX_MESSAGE_SIZE:Int = 1024 * 1024;

	public function new() {
		super();
		__serializer = new Serializer();
		__serializer.useCache = true;
		#if (cpp || neko || hl)
		__dispatchQueue = new Deque();
		__dispatchLock = new Mutex();
		#end
		__dispatchListener = __flushDispatchQueue;
		__captureRuntime();
	}

	/**
	 * Closes the listening side and any cached outbound transport.
	 */
	public function close():Void {
		__running = false;
		if (__listener != null) {
			__listener.close();
			__listener = null;
		}
		__dropAllLinks();
		if (__outboundTimeout != null) {
			__outboundTimeout.stop();
			__outboundTimeout = null;
		}
		__detachDispatchListener();
	}

	/**
	 * Starts listening for incoming method calls on the given shared channel name.
	 *
	 * @param connectionName Channel name to listen on.
	 */
	public function connect(connectionName:String):Void {
		__requireSupported();
		close();
		__captureRuntime();
		__running = true;
		__listener = new LocalConnection();
		__listener.onData = input -> {
			var payload = new ByteArray();
			if (input.length > 0) {
				payload.writeBytes(cast input, 0, input.length);
			}
			payload.position = 0;
			__dispatchReceivedData(payload);
		};
		__listener.readEnabled = true;
		__listener.listen(connectionName);
		// After listen(), which throws for a name in use: a channel that never
		// listened is not left attached. Anything queued first waits, flagged,
		// for the first tick.
		__attachDispatchListener();
	}

	/**
	 * Sends a method call to another process listening on the named channel.
	 *
	 * @param connectionName Channel name to send to.
	 * @param methodName Receiving method to invoke.
	 * @param arguments Serialized arguments to pass to the method.
	 */
	public function send(connectionName:String, methodName:String, ...arguments):Void {
		__requireSupported();
		if (methodName == null || methodName.length == 0 || methodName.length > MAX_METHOD_LENGTH) {
			dispatchEvent(new StatusEvent(StatusEvent.STATUS, "0", "error"));
			return;
		}

		__resetSerializer();
		__serializer.serialize(arguments);

		var methodBytes = Bytes.ofString(methodName);
		var serializationBytes = Bytes.ofString(__serializer.toString());
		if (8 + methodBytes.length + serializationBytes.length > MAX_MESSAGE_SIZE) {
			dispatchEvent(new StatusEvent(StatusEvent.STATUS, "0", "error"));
			return;
		}

		var messageBuffer = new BytesBuffer();
		messageBuffer.addInt32(methodBytes.length);
		messageBuffer.addBytes(methodBytes, 0, methodBytes.length);
		messageBuffer.addInt32(serializationBytes.length);
		messageBuffer.addBytes(serializationBytes, 0, serializationBytes.length);

		var payload = messageBuffer.getBytes();
		var message = new ByteArray();
		message.writeBytes(payload, 0, payload.length);
		message.position = 0;

		var status = false;

		try {
			var link = __outbound.get(connectionName);
			if (link == null || !link.connection.connected) {
				if (link != null) {
					__dropLink(connectionName);
				}
				if (__outboundCount >= MAX_OUTBOUND) {
					__dropLeastRecentLink();
				}
				var connection = new LocalConnection();
				connection.timeout = timeout;
				connection.connect(connectionName);
				link = new OutboundLink(connection);
				__outbound.set(connectionName, link);
				__outboundCount++;
			}

			link.connection.send(message);
			link.lastSent = haxe.Timer.stamp();
			// A send the connection could not take closes or reports it.
			status = link.connection.connected;
		} catch (_:Dynamic) {
			status = false;
		}

		dispatchEvent(new StatusEvent(StatusEvent.STATUS, "0", status ? "status" : "error"));

		if (__outboundTimeout == null) {
			__startTimeoutCheck();
		}
	}

	@:noCompletion private function __startTimeoutCheck():Void {
		if (__outboundTimeout != null) {
			return;
		}

		__outboundTimeout = Timer.delay(() -> __checkTimeout(), 5000);
	}

	@:noCompletion private function __checkTimeout():Void {
		final now = haxe.Timer.stamp();
		for (name in [for (name in __outbound.keys()) name]) {
			var link = __outbound.get(name);
			if (now - link.lastSent >= TIME_OUT / 1000 || !link.connection.connected) {
				__dropLink(name);
			}
		}

		if (__outboundCount == 0) {
			if (__outboundTimeout != null) {
				__outboundTimeout.stop();
				__outboundTimeout = null;
			}
			return;
		}

		__outboundTimeout = Timer.delay(() -> __checkTimeout(), 5000);
	}

	@:noCompletion private function __dropLink(name:String):Void {
		var link = __outbound.get(name);
		if (link == null) {
			return;
		}
		__outbound.remove(name);
		__outboundCount--;
		try {
			link.connection.close();
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __dropLeastRecentLink():Void {
		var oldest:String = null;
		var oldestSent = Math.POSITIVE_INFINITY;
		for (name => link in __outbound) {
			if (link.lastSent < oldestSent) {
				oldest = name;
				oldestSent = link.lastSent;
			}
		}
		if (oldest != null) {
			__dropLink(oldest);
		}
	}

	@:noCompletion private function __dropAllLinks():Void {
		for (name in [for (name in __outbound.keys()) name]) {
			__dropLink(name);
		}
		__outboundCount = 0;
	}

	@:noCompletion private inline function __resetSerializer():Void {
		__serializer.buf = new StringBuf();
		__serializer.shash.clear();
		__serializer.cache = [];
		__serializer.scount = 0;
	}

	@:noCompletion private function __onData(received:Bytes):Void {
		var target:Object = client;
		if (target == null) {
			return;
		}

		var call:Null<ChannelCall> = null;
		var method:Dynamic = null;
		try {
			call = __readCall(received);
			if (call != null) {
				method = Reflect.field(target, call.method);
			}
		} catch (_:Dynamic) {
			// What cannot be read is dropped, as the doc says.
			method = null;
		}
		if (!Reflect.isFunction(method)) {
			return;
		}

		// Kept apart from the reading above: what the method throws is the
		// application's failure, not the message's, and was dropped with the
		// unreadable ones, without a word.
		try {
			Reflect.callMethod(target, method, call.args);
		} catch (error:Dynamic) {
			__clientThrew(error);
		}
	}

	/**
		The call `received` frames, or null when it is not one this channel
		takes. Throws for arguments that cannot be read.
	**/
	@:noCompletion private function __readCall(received:Bytes):Null<ChannelCall> {
		if (received == null || received.length < 8 || received.length > MAX_MESSAGE_SIZE) {
			return null;
		}

		var offset = 0;
		var methodLength = received.getInt32(0);
		if (methodLength <= 0 || methodLength > MAX_METHOD_LENGTH || methodLength > received.length - 8) {
			return null;
		}
		offset += 4;

		var method = received.getString(offset, methodLength);
		offset += methodLength;

		var serializationLength = received.getInt32(offset);
		if (serializationLength < 0 || serializationLength > MAX_MESSAGE_SIZE || offset + 4 + serializationLength > received.length) {
			return null;
		}
		offset += 4;

		var serialization = received.getString(offset, serializationLength);
		// Bounded: natively a peer's arguments nested 6,000 deep overflowed
		// the stack and ended this process. See BoundedUnserializer.
		var args:Array<Dynamic> = BoundedUnserializer.run(serialization);
		return {method: method, args: args};
	}

	/**
		Reports what a client method threw as the runtime reports a posted
		callback's failure -- logged, and dispatched as
		`UncaughtErrorEvent.UNCAUGHT_ERROR` -- on the runtime of the thread
		that called it, which is the channel's; logged alone where there is
		none.
	**/
	@:noCompletion private function __clientThrew(error:Dynamic):Void {
		var runtime:Null<CrossByte> = CrossByte.__currentOrNull();
		if (runtime != null) {
			runtime.__uncaught(error, UncaughtErrorEvent.POSTED, this);
			return;
		}
		try {
			Logger.error("A SharedChannel client method threw: " + Std.string(error));
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __dispatchReceivedData(received:Bytes):Void {
		#if (cpp || neko || hl)
		if (!__canDispatchInline()) {
			__dispatchQueue.add(received);
			__dispatchLock.acquire();
			__dispatchPending = true;
			__dispatchLock.release();
			return;
		}
		#end

		__onData(received);
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
	#end

	// Attached by connect() on the runtime's thread and removed by close(),
	// never from another thread: EventDispatcher is not thread-safe. See
	// LocalConnection.__queueDispatch.
	@:noCompletion private function __attachDispatchListener():Void {
		if (__runtime == null || __dispatchAttached) {
			return;
		}
		__dispatchAttached = true;
		__runtime.addEventListener(TickEvent.TICK, __dispatchListener);
	}

	@:noCompletion private function __flushDispatchQueue(_event:TickEvent):Void {
		#if (cpp || neko || hl)
		// Read without the lock: a stale `false` costs one tick.
		if (!__dispatchPending) {
			return;
		}
		__dispatchLock.acquire();
		__dispatchPending = false;
		__dispatchLock.release();

		while (true) {
			var received = __dispatchQueue.pop(false);
			if (received == null) {
				break;
			}

			__onData(received);
		}
		#end
	}

	@:noCompletion private function __detachDispatchListener():Void {
		#if (cpp || neko || hl)
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

	@:noCompletion private static inline function __requireSupported():Void {
		#if !cpp
		throw NativeOnly.error("SharedChannel");
		#end
	}

	/** Test hook that forwards through the low-level native helper. */
	@:noCompletion private static inline function __write(pipe:Dynamic, data:haxe.io.BytesData, size:Int):Bool {
		return LocalConnection.__write(pipe, data, size);
	}

	/** Test hook that forwards through the low-level native helper. */
	@:noCompletion private static inline function __connect(name:String, timeoutMs:Int = 5000):Dynamic {
		return LocalConnection.__connect(name, timeoutMs);
	}

	/** Test hook that forwards through the low-level native helper. */
	@:noCompletion private static inline function __close(pipe:Dynamic):Void {
		LocalConnection.__close(pipe);
	}
}

/** A method call read from a message: the method's name and its arguments. **/
private typedef ChannelCall = {
	method:String,
	args:Array<Dynamic>
}

/** A channel's connection to one destination, and when it last sent there. **/
private class OutboundLink {
	public final connection:LocalConnection;
	public var lastSent:Float = 0;

	public function new(connection:LocalConnection) {
		this.connection = connection;
	}
}
#end
