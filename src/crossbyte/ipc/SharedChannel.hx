package crossbyte.ipc;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.StatusEvent;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.Object;
import haxe.Timer;
import haxe.Unserializer;
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
 */
@:access(haxe.Serializer)
@:access(crossbyte.ipc.LocalConnection)
class SharedChannel extends EventDispatcher {
	public static inline var isSupported:Bool = LocalConnection.isSupported;

	/**
	 * The object that handles incoming messages.
	 * This should contain methods matching the message names sent by peers.
	 */
	public var client:Object;

	@:noCompletion private var __listener:LocalConnection;
	@:noCompletion private var __outbound:LocalConnection;
	@:noCompletion private var __outboundName:String;
	@:noCompletion private var __serializer:Serializer;
	@:noCompletion private var __outboundTimeout:Timer;
	@:noCompletion private var __runtime:CrossByte;
	#if (cpp || neko || hl)
	@:noCompletion private var __dispatchQueue:Deque<Bytes>;
	@:noCompletion private var __dispatchLock:Mutex;
	#end
	@:noCompletion private var __dispatchListener:TickEvent->Void;
	@:noCompletion private var __dispatchAttached:Bool = false;
	@:noCompletion private var __lastSentTime:Float = 0;
	@:noCompletion private var __running:Bool = false;

	@:noCompletion private static inline var TIME_OUT:Int = 45000;
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
		if (__outbound != null) {
			__outbound.close();
			__outbound = null;
		}
		__outboundName = null;
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
			if (__outbound == null || __outboundName != connectionName || !__outbound.connected) {
				if (__outbound != null) {
					__outbound.close();
				}
				__outbound = new LocalConnection();
				__outbound.connect(connectionName);
				__outboundName = connectionName;
			}

			__outbound.send(message);
			status = true;
		} catch (_:Dynamic) {
			status = false;
		}

		dispatchEvent(new StatusEvent(StatusEvent.STATUS, "0", status ? "status" : "error"));
		__lastSentTime = Sys.time();

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
		if (__outbound != null) {
			var elapsed = Sys.time() - __lastSentTime;
			if (elapsed >= TIME_OUT / 1000) {
				__outbound.close();
				__outbound = null;
				__outboundName = null;
			}
		}

		if (__outbound == null && __outboundTimeout != null) {
			__outboundTimeout.stop();
			__outboundTimeout = null;
			return;
		}

		__outboundTimeout = Timer.delay(() -> __checkTimeout(), 5000);
	}

	@:noCompletion private inline function __resetSerializer():Void {
		__serializer.buf = new StringBuf();
		__serializer.shash.clear();
		__serializer.cache = [];
		__serializer.scount = 0;
	}

	@:noCompletion private #if !debug inline #end function __onData(received:Bytes):Void {
		if (client == null) {
			return;
		}

		var offset = 0;
		try {
			if (received == null || received.length < 8 || received.length > MAX_MESSAGE_SIZE) {
				return;
			}

			var methodLength = received.getInt32(0);
			if (methodLength <= 0 || methodLength > MAX_METHOD_LENGTH || methodLength > received.length - 8) {
				return;
			}
			offset += 4;

			var method = received.getString(offset, methodLength);
			offset += methodLength;

			var serializationLength = received.getInt32(offset);
			if (serializationLength < 0 || serializationLength > MAX_MESSAGE_SIZE || offset + 4 + serializationLength > received.length) {
				return;
			}
			offset += 4;

			var serialization = received.getString(offset, serializationLength);
			var args:Array<Dynamic> = Unserializer.run(serialization);
			var field:Dynamic = Reflect.field(client, method);
			if (!Reflect.isFunction(field)) {
				return;
			}

			Reflect.callMethod(client, field, args);
		} catch (_:Dynamic) {}
	}

	@:noCompletion private function __dispatchReceivedData(received:Bytes):Void {
		#if (cpp || neko || hl)
		if (!__canDispatchInline()) {
			__dispatchQueue.add(received);
			__ensureDispatchListener();
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
	#end

	@:noCompletion private function __flushDispatchQueue(_event:TickEvent):Void {
		#if (cpp || neko || hl)
		while (true) {
			var received = __dispatchQueue.pop(false);
			if (received == null) {
				break;
			}

			__onData(received);
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

	@:noCompletion private static inline function __requireSupported():Void {
		if (!isSupported) {
			throw new ArgumentError("SharedChannel is only supported on native cpp targets.");
		}
	}

	/** Test hook that forwards through the low-level native helper. */
	@:noCompletion private static inline function __write(pipe:Dynamic, data:haxe.io.BytesData, size:Int):Bool {
		return LocalConnection.__write(pipe, data, size);
	}

	/** Test hook that forwards through the low-level native helper. */
	@:noCompletion private static inline function __connect(name:String):Dynamic {
		return LocalConnection.__connect(name);
	}

	/** Test hook that forwards through the low-level native helper. */
	@:noCompletion private static inline function __close(pipe:Dynamic):Void {
		LocalConnection.__close(pipe);
	}
}
