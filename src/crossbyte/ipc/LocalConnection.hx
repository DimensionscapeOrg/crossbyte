package crossbyte.ipc;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
import haxe.Timer;
import haxe.io.BytesBuffer;
import crossbyte.errors.ArgumentError;
import crossbyte.events.StatusEvent;
import crossbyte.events.TickEvent;
import crossbyte.Object;
import haxe.Unserializer;
import haxe.Serializer;
#if cpp
import cpp.Pointer;
import crossbyte.ipc._internal.NativeLocalConnection;
#if windows
import crossbyte.ipc._internal.win.HANDLE;
#end
import crossbyte.ipc._internal.VoidPointer;
#end
import haxe.io.Bytes;
import haxe.io.BytesData;
import sys.thread.Deque;
import crossbyte.events.EventDispatcher;
#if (cpp || neko || hl)
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

/**
 * `LocalConnection` provides inter-process communication (IPC) using Named Pipes.
 * 
 * This class allows **sending messages between processes** on the same **local machine**.
 * The communication model follows a **client-server architecture**, where:
 * - A **server** process listens for incoming messages.
 * - A **client** process connects to the server and sends data.
 *
 * This implementation supports **asynchronous, non-blocking communication** and handles **multiple clients**.
 *
 */
@:access(haxe.Serializer)
#if cpp
@:access(crossbyte.ipc._internal.NativeLocalConnection)
#end
class LocalConnection extends EventDispatcher {
	public static inline var isSupported:Bool = #if cpp true #else false #end;

	/**
	 * The object that handles incoming messages.
	 * This should be set to an instance containing methods corresponding to the message names sent by other processes.
	 */
	public var client:Object;

	@:noCompletion private var __inboundPipe:LocalConnectionHandle;
	@:noCompletion private var __outboundPipe:LocalConnectionHandle;
	@:noCompletion private var __serializer:Serializer;
	@:noCompletion private var __clientPipes:Array<Dynamic>;
	@:noCompletion private var __outboundTimeout:Timer;
	@:noCompletion private var __runtime:CrossByte;
	#if (cpp || neko || hl)
	@:noCompletion private var __dispatchQueue:Deque<Bytes>;
	@:noCompletion private var __dispatchLock:Mutex;
	#end
	@:noCompletion private var __dispatchListener:TickEvent->Void;
	@:noCompletion private var __dispatchAttached:Bool = false;
	@:noCompletion private var __lastSentTime:Float = 0;
	@:noCompletion private var __connected:Bool = false;
	@:noCompletion private var __running:Bool = false;

	@:noCompletion private static inline var TIME_OUT:Int = 45000;
	@:noCompletion private static inline var BUFFER_SIZE:Int = 4096;
	@:noCompletion private static inline var MAX_METHOD_LENGTH:Int = 256;
	@:noCompletion private static inline var MAX_MESSAGE_SIZE:Int = 1024 * 1024;

	/**
	 * Creates a new `LocalConnection` instance.
	 *
	 * This instance must either `connect()` to receive messages or use `send()` to send messages.
	 */
	public function new() {
		super();
		__serializer = new Serializer();
		__serializer.useCache = true;
		__clientPipes = [];
		#if (cpp || neko || hl)
		__dispatchQueue = new Deque();
		__dispatchLock = new Mutex();
		#end
		__dispatchListener = __flushDispatchQueue;
		try {
			__runtime = CrossByte.current();
		} catch (_:IllegalOperationError) {
			__runtime = null;
		} catch (_:Dynamic) {
			__runtime = null;
		}
	}

	/**
	 * Closes the **inbound** (server-side) connection.
	 *
	 * This stops the server from receiving further messages.
	 */
	public function close():Void {
		__running = false;
		if (__inboundPipe != null) {
			__close(__inboundPipe);
			__inboundPipe = null;
		}
		if (__outboundPipe != null) {
			__close(__outboundPipe);
			__outboundPipe = null;
		}
		__closeClientPipes();
		if (__outboundTimeout != null) {
			__outboundTimeout.stop();
			__outboundTimeout = null;
		}
		__detachDispatchListener();
		__connected = false;
	}

	/**
	 * Starts listening for incoming messages on the given connection.
	 *
	 * @param connectionName The name of the connection (pipe) to listen for messages.
	 */
	public function connect(connectionName:String):Void {
		__requireSupported();
		try {
			__runtime = CrossByte.current();
		} catch (_:IllegalOperationError) {
			__runtime = null;
		} catch (_:Dynamic) {
			__runtime = null;
		}
		// trace('Connecting as server: ' + connectionName);
		if (!__setupNamedPipe(connectionName)) {
			// trace("Error setting up named pipe: " + connectionName);
			throw new ArgumentError("Connection name is already in use or invalid");
		} else {
			__connected = true;
		}
	}

	/**
	 * Sends a message to another process.
	 *
	 * @param connectionName The name of the connection (pipe) to send the message to.
	 * @param methodName The name of the method to invoke on the receiving process.
	 * @param arguments The arguments to pass to the method.
	 */
	public function send(connectionName:String, methodName:String, ...arguments):Void {
		__requireSupported();
		if (methodName == null || methodName.length == 0 || methodName.length > MAX_METHOD_LENGTH) {
			dispatchEvent(new StatusEvent(StatusEvent.STATUS, "0", "error"));
			return;
		}

		__resetSeralizer();

		var status:Bool = false;

		__serializer.serialize(arguments);
		var methodBytes:Bytes = Bytes.ofString(methodName);
		var serializationBytes:Bytes = Bytes.ofString(__serializer.toString());
		if (8 + methodBytes.length + serializationBytes.length > MAX_MESSAGE_SIZE) {
			dispatchEvent(new StatusEvent(StatusEvent.STATUS, "0", "error"));
			return;
		}

		var messageBuffer:BytesBuffer = new BytesBuffer();
		messageBuffer.addInt32(methodBytes.length);
		messageBuffer.addBytes(methodBytes, 0, methodBytes.length);
		messageBuffer.addInt32(serializationBytes.length);
		messageBuffer.addBytes(serializationBytes, 0, serializationBytes.length);

		var messageBytes:Bytes = messageBuffer.getBytes();
		// trace("Attempt to send: " + message);

		// Connects to the outbound pipe

		if (__outboundPipe == null || !__isOpen(__outboundPipe)) {
			__outboundPipe = __connect(connectionName);
		}

		// Send the message
		if (__outboundPipe != null) {
			status = __write(__outboundPipe, messageBytes.getData(), messageBytes.length);
		}

		// trace("Send message status is: " + (status ? "Success" : "Failure"));
		var level:String = status ? "status" : "error";

		dispatchEvent(new StatusEvent(StatusEvent.STATUS, "0", level));
		// __close(pipe);

		// Update last sent time
		__lastSentTime = Sys.time();

		// Ensure timeout checking is running
		if (__outboundTimeout == null) {
			__startTimeoutCheck();
		}
	}

	/** Starts the timeout check (but does not hold a strong reference) */
	@:noCompletion private function __startTimeoutCheck():Void {
		if (__outboundTimeout != null)
			return; // Prevent multiple timers

		__outboundTimeout = Timer.delay(() -> __checkTimeout(), 5000);
	}

	/** Checks if the pipe should be closed due to timeout */
	@:noCompletion private function __checkTimeout():Void {
		if (__outboundPipe != null) {
			var elapsed:Float = Sys.time() - __lastSentTime;
			if (elapsed >= TIME_OUT / 1000) {
				// trace("Timeout expired. Closing outbound pipe.");
				__close(__outboundPipe);
				__outboundPipe = null;
			}
		}

		// Stop the timer if there’s no active pipe
		if (__outboundPipe == null && __outboundTimeout != null) {
			// trace("No active pipe, stopping timeout checks.");
			__outboundTimeout.stop();
			__outboundTimeout = null; // Allow garbage collection
			return;
		}

		// Continue checking if still active
		__outboundTimeout = Timer.delay(() -> __checkTimeout(), 5000);
	}

	/** Writes data to a named pipe */
	@:noCompletion private static function __write(pipe:LocalConnectionHandle, data:BytesData, size:Int):Bool {
		#if cpp
		return NativeLocalConnection.__write(pipe, Pointer.ofArray(data), size);
		#else
		return false;
		#end
	}

	/** Connects to an outbound pipe */
	@:noCompletion private static function __connect(name:String):LocalConnectionHandle {
		#if cpp
		return NativeLocalConnection.__connect(name);
		#else
		return null;
		#end
	}

	/** Creates an inbound pipe (server) */
	@:noCompletion private static function __createInboundPipe(name:String):LocalConnectionHandle {
		#if cpp
		return NativeLocalConnection.__createInboundPipe(name);
		#else
		return null;
		#end
	}

	/** Accepts a new client connection */
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

	/** Reads from the named pipe */
	@:noCompletion private static function __read(pipe:LocalConnectionHandle, buffer:BytesData, size:Int):Int {
		#if cpp
		return NativeLocalConnection.__read(pipe, Pointer.ofArray(buffer), size);
		#else
		return -1;
		#end
	}

	/** Gets available bytes in the pipe */
	@:noCompletion private static function __getBytesAvailable(pipe:LocalConnectionHandle):Int {
		#if cpp
		return NativeLocalConnection.__getBytesAvailable(pipe);
		#else
		return 0;
		#end
	}

	/** Closes a named pipe */
	@:noCompletion private static function __close(pipe:LocalConnectionHandle):Void {
		#if cpp
		NativeLocalConnection.__close(pipe);
		#end
	}

	/** Resets our serializer internally */
	@:noCompletion private inline function __resetSeralizer():Void {
		__serializer.buf = new StringBuf();
		__serializer.shash.clear();
		__serializer.cache = [];
		__serializer.scount = 0;
	}

	/** Initializes the Named Pipe Server */
	@:noCompletion private function __setupNamedPipe(connectionName:String):Bool {
		close();
		__running = true;
		var handleQueue:Deque<LocalConnectionHandle> = new Deque();
		#if (cpp || neko || hl)
		Thread.create(() -> {
			var handle:LocalConnectionHandle = null;
			try {
				handle = __createInboundPipe(connectionName);
				__inboundPipe = handle;
				handleQueue.add(handle);
			} catch (e:Dynamic) {
				handleQueue.add(null);
			}
			if (handle != null) {
				__runLocalConnection(connectionName, handle);
			}
		});
		#else
		var handle:LocalConnectionHandle = null;
		try {
			handle = __createInboundPipe(connectionName);
			__inboundPipe = handle;
			handleQueue.add(handle);
		} catch (e:Dynamic) {
			handleQueue.add(null);
		}
		if (handle != null) {
			__runLocalConnection(connectionName, handle);
		}
		#end

		var handle:LocalConnectionHandle = handleQueue.pop(true);
		if (handle != null) {
			return true;
		}

		__running = false;
		return false;
	}

	@:noCompletion private #if !debug inline #end function __onData(received:Bytes):Void {
		if (client == null) {
			return;
		}

		var offset:Int = 0;
		try {
			if (received == null || received.length < 8 || received.length > MAX_MESSAGE_SIZE) {
				return;
			}

			var methodLength:Int = received.getInt32(0);
			if (methodLength <= 0 || methodLength > MAX_METHOD_LENGTH || methodLength > received.length - 8) {
				return;
			}
			offset += 4;

			var method:String = received.getString(offset, methodLength);
			offset += methodLength;

			var serializationLength:Int = received.getInt32(offset);
			if (serializationLength < 0 || serializationLength > MAX_MESSAGE_SIZE || offset + 4 + serializationLength > received.length) {
				return;
			}
			offset += 4;

			var serialization:String = received.getString(offset, serializationLength);

			var args:Array<Dynamic> = Unserializer.run(serialization);
			var field:Dynamic = Reflect.field(client, method);
			if (!Reflect.isFunction(field)) {
				return;
			}

			Reflect.callMethod(client, field, args);
		} catch (_:Dynamic) {}

		/*try{
				Reflect.callMethod(client, client[method], args);
			}
			catch (e:Dynamic)
			{
				// De nada
		}*/
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

	/** Listens for incoming messages in a background thread */
	@:noCompletion private function __runLocalConnection(connectionName:String, listeningPipe:LocalConnectionHandle):Void {
		var buffer:Bytes = Bytes.alloc(BUFFER_SIZE);

		while (__running) {
			// Accepts new clients
			if (listeningPipe != null && __accept(listeningPipe)) {
				// trace("New client connected!");

				// we store new client pipe
				__clientPipes.push(listeningPipe);
				// Creates a new pipe for next client
				listeningPipe = __createInboundPipe(connectionName);
				__inboundPipe = listeningPipe;
			}

			// we can iterate in reverse to safely remove elements
			var i = __clientPipes.length - 1;
			while (i >= 0) {
				var pipe = __clientPipes[i];

				// Checks if the client disconnected
				var available:Int = __getBytesAvailable(pipe);
				if (available < 0) {
					__close(pipe);
					__clientPipes.splice(i, 1);
				} else if (available == 0) {
					// Check if the pipe is still valid?
					if (!__isOpen(pipe)) {
						// trace("Client disconnected. Removing handle.");
						__close(pipe);
						__clientPipes.splice(i, 1); // Remove client from the list
					}
				} else if (available > 0) {
					if (available > MAX_MESSAGE_SIZE) {
						__close(pipe);
						__clientPipes.splice(i, 1);
					} else if (available > BUFFER_SIZE) {
						var largeMessageBuffer:BytesBuffer = new BytesBuffer();
						var bytesRemaining:Int = available;
						while (bytesRemaining > 0) {
							var length:Int = bytesRemaining > BUFFER_SIZE ? BUFFER_SIZE : bytesRemaining;
							if (__read(pipe, buffer.getData(), length) == 0) {
								bytesRemaining -= length;
								largeMessageBuffer.addBytes(buffer, 0, length);
							} else {
								bytesRemaining = 0;
							}
						}
						__dispatchReceivedData(largeMessageBuffer.getBytes());
					} else {
						// Read theavailable data
						if (__read(pipe, buffer.getData(), available) == 0) {
							var received:Bytes = buffer.sub(0, available);
							// trace("Received: " + received);
							__dispatchReceivedData(received);
						}
					}
				}

				i--; // Moves to the previous index
			}

			// Application seems to lock up without sleep
			Sys.sleep(0.001);
		}

		if (listeningPipe != null && listeningPipe == __inboundPipe) {
			__close(listeningPipe);
			__inboundPipe = null;
		}
		__closeClientPipes();
	}

	@:noCompletion private function __closeClientPipes():Void {
		for (pipe in __clientPipes) {
			if (pipe != null) {
				__close(pipe);
			}
		}
		__clientPipes.resize(0);
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

	@:noCompletion private static inline function __requireSupported():Void {
		if (!isSupported) {
			throw new ArgumentError("LocalConnection is only supported on native cpp targets.");
		}
	}
}
