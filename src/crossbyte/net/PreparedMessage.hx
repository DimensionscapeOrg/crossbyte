package crossbyte.net;

// Not built for the browser, as WebSocket and ServerWebSocket are not: a page
// has one connection to send on, and nothing to send it to many.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import crossbyte.io.ByteArray;

/**
	A WebSocket message made ready once to send to many sessions: a chat
	room's line, a match's state, a dashboard's update. Its frames are built
	when it is made, the header and the payload, as a server sends them,
	unmasked, so each session it goes to only copies them into what its
	pass sends, where a `sendText` or `sendBinary` per session encoded,
	framed and copied the message again for every one.

	```haxe
	// Given server:ServerWebSocket, room:Array<WebSocket>.
	var update = PreparedMessage.text('{"type":"move","x":12,"y":40}');
	// Every session the server has open...
	server.broadcast(update);
	// ...or the ones the application chose: a room, a topic, an area.
	server.broadcast(update, room);
	// Or one at a time.
	for (session in room) {
		session.sendPrepared(update);
	}
	```

	Who receives a message, rooms, topics, areas of interest, is the
	application's: a prepared message is only the message.

	**Its bytes are its own.** Making one copies what it is given, so the
	buffer is the caller's again as soon as `text` or `binary` returns,
	the payload of a message event among them, which is valid only during
	its listener (see `Event`). Nothing changes it afterwards: it can be
	kept, and sent again, any number of times, from any runtime.

	**What is shared, and what is not:**

	- **permessage-deflate.** Made with `compress`, it also holds a
	  compressed form, compressed once, which every session that agreed to
	  compression is sent, where the message is at least its
	  `compressionThreshold`: each compresses a message on its own, with
	  no context taken from one to the next, so one compressed form serves
	  them all. Sessions that did not agree get the plain form. Made without
	  `compress`, every session gets the plain form, compressed or not:
	  RFC 7692 leaves compression to each message.
	- **TLS.** A secure session encrypts what it sends on its own, so what
	  is shared is the framing: the frames are copied into each session's
	  output once, and encrypted there.
	- **Clients.** A client masks every frame it sends with a key of its
	  own (RFC 6455 5.3), so a client's `sendPrepared` frames and masks the
	  payload as `sendBinary` would: it shares the encoding, a text's
	  UTF-8, a compressed form, and not the frames. Preparing is for a
	  server's sessions.
**/
final class PreparedMessage {
	/** Whether this is a text message; a binary one otherwise. **/
	public var isText(default, null):Bool;

	/** How long the message is, in bytes: its UTF-8 for a text. **/
	public var length(default, null):Int;

	/**
		Whether a compressed form was made: with `compress`, and only where
		compressing the message made it smaller.
	**/
	public var compressed(get, never):Bool;

	// The message, its own copy: what a client frames and masks.
	@:noCompletion private var __payload:ByteArray;
	// The frames a server sends it in.
	@:noCompletion private var __frames:ByteArray;
	// Its compressed form, and the frames of that, or null for none.
	@:noCompletion private var __deflated:Null<ByteArray> = null;
	@:noCompletion private var __deflatedFrames:Null<ByteArray> = null;

	/**
		A text message.

		@param text What to send, encoded as UTF-8; `null` sends an empty one.
		@param compress Whether to make a compressed form too, for the
			sessions that agreed to permessage-deflate. Off by default:
			compressing costs time once per message, and a server's sessions
			agree to it only where `ServerWebSocket.perMessageDeflate` is on.
	**/
	public static function text(text:String, compress:Bool = false):PreparedMessage {
		var payload:ByteArray = ByteArray.fromBytes(crossbyte._internal.Utf8.bytesOf(text == null ? "" : text));
		return new PreparedMessage(payload, true, compress);
	}

	/**
		A binary message: `length` bytes of `bytes` from `offset`, copied. A
		`length` of 0 takes everything from `offset`.

		@param compress As for `text`.
		@throws ArgumentError If `bytes` is `null`.
		@throws RangeError If the range falls outside `bytes`.
	**/
	public static function binary(bytes:ByteArray, offset:Int = 0, length:Int = 0, compress:Bool = false):PreparedMessage {
		if (bytes == null) {
			throw new ArgumentError("PreparedMessage.binary needs the bytes to send.");
		}
		if (offset < 0 || length < 0 || offset > bytes.length || length > bytes.length - offset) {
			throw new RangeError("The supplied index is out of bounds.");
		}
		if (length == 0) {
			length = bytes.length - offset;
		}
		var payload = new ByteArray();
		if (length > 0) {
			payload.writeBytes(bytes, offset, length);
		}
		return new PreparedMessage(payload, false, compress);
	}

	private function new(payload:ByteArray, isText:Bool, compress:Bool) {
		payload.position = 0;
		__payload = payload;
		this.isText = isText;
		length = payload.length;
		var opcode:Int = isText ? 0x1 : 0x2;

		// Everything made now, and nothing after, so sessions on several
		// runtimes can read it at once with nothing to agree on.
		__frames = new ByteArray();
		crossbyte._internal.websocket.WebSocket.__writeServerFrames(__frames, payload, 0, length, opcode, false);

		if (compress && length > 0) {
			var deflated:ByteArray = crossbyte._internal.websocket.WebSocket.__deflateMessage(payload);
			// Sent as it is where compressing did not make it smaller.
			if (deflated.length < length) {
				__deflated = deflated;
				__deflatedFrames = new ByteArray();
				crossbyte._internal.websocket.WebSocket.__writeServerFrames(__deflatedFrames, deflated, 0, deflated.length, opcode, true);
			}
		}
	}

	@:noCompletion private inline function get_compressed():Bool {
		return __deflated != null;
	}
}
#end
