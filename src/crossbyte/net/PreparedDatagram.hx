package crossbyte.net;

// Not built for the browser, as reliable UDP is not.
#if !(js && !nodejs)

import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import crossbyte.io.ByteArray;

/**
	A reliable UDP message made ready once to send to many sessions: a
	match's state, a room's chat line, an event for everyone in an area.
	Its bytes are copied once, when it is made, and every session it is sent
	to refers to them (to send it, and to send it again until the peer has
	it), rather than each session copying the message and holding the copy
	until its peer acknowledged it: a thousand copies of a 1 KB update to a
	thousand players, held for a round trip at least, and for as long as a
	player who lost it takes to get it.

	```haxe
	// Given server:ReliableDatagramServerSocket, room:Array<ReliableDatagramSocket>, snapshot:crossbyte.io.ByteArray.
	var state = PreparedDatagram.of(snapshot);
	// Every session the server has connected...
	server.broadcast(state);
	// ...or the ones the application chose: a room, a team, an area.
	server.broadcast(state, room);
	// In any delivery mode.
	server.broadcast(state, room, DeliveryMode.sequenced(0));
	// Or one at a time.
	for (session in room) {
		session.sendPrepared(state);
	}
	```

	Who receives a message (rooms, teams, areas of interest) is the
	application's: a prepared datagram is only the message.

	**Its bytes are its own.** Making one copies what it is given, so the
	buffer is the caller's again as soon as `of` returns, the payload of a
	message event among them, which is valid only during its listener (see
	`Event`). Nothing changes it afterwards: it can be kept, and sent again,
	any number of times, to sessions on any runtime, which only ever read
	it.

	**What each session still does for itself.** It frames the message with
	its own sequence numbers and acknowledgements, as `send` would; bundles
	it with whatever else it sends in the pass; paces it by its own
	congestion window; and sends it again, from the shared bytes, as often as
	its own peer needs. A message larger than one frame is split into frames
	by each session, over the same bytes: 1,200 bytes in the clear, 1,179 encrypted
	(`ReliableDatagramSocket.maxPayloadSize`). What a
	session holds for it is a record of each frame in flight, a few dozen
	bytes, where `send` holds a copy.

	**Encrypted sessions** share it as sessions in the clear do: a session
	seals each datagram as it goes out, into a buffer its server's sessions
	share, so nothing it holds for the message is its own copy. What they
	cannot share is the sealing itself, done per datagram per session,
	since each session's keys differ: the memory is saved, and the time of
	the seal is not.
**/
final class PreparedDatagram {
	/** How long the message is, in bytes. **/
	public var length(default, null):Int;

	// The message, its own copy, never changed once made.
	@:noCompletion private var __bytes:ByteArray;

	/**
		A message: `length` bytes of `bytes` from `offset`, copied. A `length`
		of 0 takes everything from `offset`, as `ReliableDatagramSocket.send`
		does.

		@throws ArgumentError If `bytes` is `null`.
		@throws RangeError If the range falls outside `bytes`.
	**/
	public static function of(bytes:ByteArray, offset:Int = 0, length:Int = 0):PreparedDatagram {
		if (bytes == null) {
			throw new ArgumentError("PreparedDatagram.of needs the bytes to send.");
		}
		var total:Int = bytes.length;
		if (offset < 0 || offset > total || length < 0 || length > total - offset) {
			throw new RangeError("The supplied index is out of bounds.");
		}
		if (length == 0) {
			length = total - offset;
		}
		var copy = new ByteArray(length);
		if (length > 0) {
			(copy : haxe.io.Bytes).blit(0, bytes, offset, length);
		}
		return new PreparedDatagram(copy, length);
	}

	private function new(bytes:ByteArray, length:Int) {
		__bytes = bytes;
		this.length = length;
	}
}
#end
