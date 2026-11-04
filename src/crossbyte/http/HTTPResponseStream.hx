package crossbyte.http;

// Not built for the browser, like the HTTPRequestHandler it streams from.
#if !(js && !nodejs)
import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
#if (target.threaded && !js)
import sys.thread.Mutex;
#end

/**
 * The body of a response written as it is produced, from
 * `HTTPRequestHandler.beginResponse`: server-sent events, a download generated
 * as it goes, anything whose length is not known when it starts.
 *
 * ```haxe
 * var events = handler.beginResponse(200, "text/event-stream");
 * var ticks = new haxe.Timer(1000);
 * ticks.run = () -> events.writeText("data: tick\n\n");
 * handler.addEventListener(Event.CLOSE, _ -> ticks.stop());
 * ```
 *
 * Nothing here buffers: `write` hands its bytes to the connection, and
 * answers `false` once the client has more waiting than it is reading. A
 * producer with more to send stops there and carries on from `onDrain`. One
 * that writes regardless is stopped at `HTTPServerConfig.maxOutputBufferSize`:
 * the response ends, cut short, with an error logged, rather than the server
 * holding without bound what a client is not reading. And what a client
 * takes none of for 30 seconds is given up, as any response's is, ending the
 * response the same way.
 *
 * A stream belongs to the one response it was begun for. Once that has ended
 * (by `end`, by the client leaving, or at the cap) it refuses every write,
 * so a producer that has not noticed cannot reach the connection's next
 * response.
 *
 * `write`, `writeText` and `end` may be called from any thread, as
 * `HTTPRequestHandler.respond` may: a call from another thread is handed to
 * the runtime serving the connection and returns at once, its bytes copied,
 * and calls from one thread reach the client in the order they were made.
 * What such a `write` answers counts what it has handed over and not yet
 * sent, and `onDrain` is called on the connection's runtime, so a producer on
 * another thread that waits for room is told there.
 */
class HTTPResponseStream {
	/**
	 * Called once there is room again after `write` answered `false`, so a
	 * producer can go on. `null` to stop. Called on the runtime serving the
	 * connection, whichever thread writes.
	 */
	public var onDrain:Null<Void->Void> = null;

	/**
	 * Whether writes still reach the client: false once the response has
	 * ended, the client has gone, or under HTTP/2 the stream was reset.
	 */
	public var connected(get, never):Bool;

	@:noCompletion private var __handler:Null<HTTPRequestHandler>;
	// For a HEAD, or a status with no body: writes are accepted and dropped
	// until the producer ends.
	@:noCompletion private var __discards:Bool;
	@:noCompletion private var __ended:Bool = false;
	// A write was refused for want of room, so onDrain is owed.
	@:noCompletion private var __blocked:Bool = false;

	// The runtime serving the connection, which a call from any other thread
	// is handed to; null where there is one thread (Node), or for a stream
	// that reaches no client.
	@:noCompletion private var __owner:Null<CrossByte> = null;
	// Begun from another thread and not yet started on the runtime: not
	// connected yet, though writes are taken.
	@:noCompletion private var __pending:Bool = false;
	#if (target.threaded && !js)
	// Made by the first write from another thread, and guarding the two
	// counts below, which that thread and the runtime both change.
	@:noCompletion private var __lock:Null<Mutex> = null;
	#end
	// Bytes handed over from another thread and not yet written on the
	// runtime, and what the connection had waiting when the runtime last
	// wrote: together, what a write from another thread reports room by.
	@:noCompletion private var __queued:Int = 0;
	@:noCompletion private var __buffered:Int = 0;

	@:noCompletion private function new(handler:Null<HTTPRequestHandler>, discards:Bool) {
		__handler = handler;
		__discards = discards;
	}

	@:noCompletion private function get_connected():Bool {
		if (__pending) {
			return !__ended;
		}
		var handler:Null<HTTPRequestHandler> = __handler;
		return handler != null && handler.connected;
	}

	/**
	 * Sends `length` bytes of `data` from `offset`, all of what follows it by
	 * default.
	 *
	 * @return `true` when there is room for more now; `false` when the client
	 * is not keeping up (wait for `onDrain`), or the stream no longer
	 * reaches it (`connected`).
	 */
	public function write(data:ByteArray, offset:Int = 0, length:Int = -1):Bool {
		if (__ended || data == null) {
			return false;
		}
		if (length < 0) {
			length = data.length - offset;
		}

		var owner:Null<CrossByte> = __owner;
		if (owner != null && !@:privateAccess HTTPRequestHandler.__onThreadOf(owner)) {
			return __writeFromAnotherThread(owner, data, offset, length);
		}

		if (__discards) {
			return true;
		}
		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler == null) {
			return false;
		}
		if (length <= 0) {
			return true;
		}
		return @:privateAccess handler.__writeOpenStream(this, data, offset, length);
	}

	/**
	 * `write`, with `text` as UTF-8. The text is encoded into a buffer the
	 * thread keeps, since the connection copies what it is given: a call
	 * allocates nothing for an ASCII text natively.
	 */
	public function writeText(text:String):Bool {
		var bytes:ByteArray = crossbyte._internal.http.TextBody.take();
		if (text != null) {
			bytes.writeUtfBytes(text);
		}
		var room:Bool;
		try {
			room = write(bytes, 0, bytes.length);
		} catch (error:Dynamic) {
			crossbyte._internal.http.TextBody.give(bytes);
			throw error;
		}
		crossbyte._internal.http.TextBody.give(bytes);
		return room;
	}

	/**
	 * Finishes the response (the last chunk, or the end of the stream)
	 * and readies the connection for its next request, or closes it if this
	 * response said so. Anything written after is refused.
	 */
	public function end():Void {
		if (__ended) {
			return;
		}
		__ended = true;
		onDrain = null;

		var owner:Null<CrossByte> = __owner;
		if (owner != null && !@:privateAccess HTTPRequestHandler.__onThreadOf(owner)) {
			// After what this thread wrote before it, which went first.
			var stream:HTTPResponseStream = this;
			if (!owner.post(() -> stream.__endHanded())) {
				__handler = null;
			}
			return;
		}

		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler != null) {
			@:privateAccess handler.__endOpenStream(this);
		}
		__handler = null;
	}

	/** On the runtime: `end`, handed over from another thread. **/
	@:noCompletion private function __endHanded():Void {
		var handler:Null<HTTPRequestHandler> = __handler;
		__handler = null;
		if (handler != null) {
			@:privateAccess handler.__runHanded(() -> handler.__endOpenStream(this));
		}
	}

	/**
		A write from a thread other than the connection's runtime: `data`
		copied, handed over, and the room answered from what is waiting
		already, counting what this and earlier such writes handed over.
	**/
	@:noCompletion private function __writeFromAnotherThread(owner:CrossByte, data:ByteArray, offset:Int, length:Int):Bool {
		if (length <= 0) {
			return connected;
		}
		var copy:ByteArray = ByteArray.fromBytes((data : haxe.io.Bytes).sub(offset, length));
		#if (target.threaded && !js)
		if (__lock == null) {
			__lock = new Mutex();
		}
		var lock:Mutex = __lock;
		lock.acquire();
		__queued += length;
		var room:Bool = __queued + __buffered < __watermark();
		if (!room) {
			__blocked = true;
		}
		lock.release();
		#else
		var room:Bool = true;
		#end

		var stream:HTTPResponseStream = this;
		if (!owner.post(() -> stream.__writeHanded(copy, length))) {
			return false;
		}
		return room && connected;
	}

	/** On the runtime: a write handed over from another thread. **/
	@:noCompletion private function __writeHanded(data:ByteArray, length:Int):Void {
		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler != null && !__discards) {
			@:privateAccess handler.__runHanded(() -> handler.__writeOpenStream(this, data, 0, length));
		}
		#if (target.threaded && !js)
		var lock:Mutex = __lock;
		lock.acquire();
		__queued -= length;
		lock.release();
		#end
		if (__handler != null && __drainOwed(@:privateAccess handler.__writer.bufferedBytes)) {
			var callback:Null<Void->Void> = onDrain;
			if (callback != null) {
				callback();
			}
		}
	}

	/** What may wait before a write asks its producer to stop. **/
	@:noCompletion private function __watermark():Int {
		var handler:Null<HTTPRequestHandler> = __handler;
		return handler != null ? @:privateAccess handler.__openStreamWatermark() : @:privateAccess HTTPRequestHandler.STREAM_WATERMARK;
	}

	/**
		On the runtime, with `buffered` what the connection has waiting:
		whether `onDrain` is owed now, which it is once a write was refused
		and what waits, counting what writes from another thread have handed
		over and not yet sent, is under the watermark again. Answered and
		cleared in one step, so a refusal from another thread meanwhile is
		not lost. Notes `buffered` for those writes to report room by.
	**/
	@:noCompletion private function __drainOwed(buffered:Int):Bool {
		var watermark:Int = __watermark();
		#if (target.threaded && !js)
		var lock:Null<Mutex> = __lock;
		if (lock != null) {
			lock.acquire();
			__buffered = buffered;
			var owed:Bool = __blocked && __queued + buffered < watermark;
			if (owed) {
				__blocked = false;
			}
			lock.release();
			return owed;
		}
		#end
		var owed:Bool = __blocked && buffered < watermark;
		if (owed) {
			__blocked = false;
		}
		return owed;
	}
}
#end
