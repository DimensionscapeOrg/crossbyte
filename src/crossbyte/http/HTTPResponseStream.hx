package crossbyte.http;

// Not built for the browser, like the HTTPRequestHandler it streams from.
#if !(js && !nodejs)
import crossbyte.io.ByteArray;

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
 * A stream belongs to the one response it was begun for. Once that has ended,
 * by `end`, by the client leaving, or at the cap, it refuses every write,
 * so a producer that has not noticed cannot reach the connection's next
 * response.
 */
class HTTPResponseStream {
	/**
	 * Called once there is room again after `write` answered `false`, so a
	 * producer can go on. `null` to stop.
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

	@:noCompletion private function new(handler:Null<HTTPRequestHandler>, discards:Bool) {
		__handler = handler;
		__discards = discards;
	}

	@:noCompletion private function get_connected():Bool {
		return __handler != null && __handler.connected;
	}

	/**
	 * Sends `length` bytes of `data` from `offset`, all of what follows it by
	 * default.
	 *
	 * @return `true` when there is room for more now; `false` when the client
	 * is not keeping up, wait for `onDrain`, or the stream no longer
	 * reaches it (`connected`).
	 */
	public function write(data:ByteArray, offset:Int = 0, length:Int = -1):Bool {
		if (__ended || data == null) {
			return false;
		}
		if (__discards) {
			return true;
		}

		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler == null) {
			return false;
		}

		if (length < 0) {
			length = data.length - offset;
		}
		if (length <= 0) {
			return true;
		}
		return @:privateAccess handler.__writeOpenStream(this, data, offset, length);
	}

	/** `write`, with `text` as UTF-8. */
	public function writeText(text:String):Bool {
		var bytes:ByteArray = new ByteArray();
		if (text != null) {
			bytes.writeUTFBytes(text);
		}
		return write(bytes, 0, bytes.length);
	}

	/**
	 * Finishes the response, the last chunk, or the end of the stream,
	 * and readies the connection for its next request, or closes it if this
	 * response said so. Anything written after is refused.
	 */
	public function end():Void {
		if (__ended) {
			return;
		}
		__ended = true;
		onDrain = null;

		var handler:Null<HTTPRequestHandler> = __handler;
		if (handler != null) {
			@:privateAccess handler.__endOpenStream(this);
		}
		__handler = null;
	}
}
#end
