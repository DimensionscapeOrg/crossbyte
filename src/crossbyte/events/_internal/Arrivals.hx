package crossbyte.events._internal;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;

/**
	How CrossByte hands out what arrives, and the two defines that change
	it. See `Event` for the contract itself: an event, a payload handed to
	a hook called once per arrival, and the received bytes either carries
	are valid only during that call.

	- Released, the hot ones are reused: one event and one payload per
	  socket or session, filled again for each arrival (`refill`), and
	  emptied once the call has returned (`release`). Each is guarded by
	  a flag while it is handed out, and taken afresh while the flag is
	  up: a listener that pumps the runtime can be handed the next
	  arrival inside its own call. `REUSE`.
	- `-D crossbyte_fresh_events`: every arrival gets objects of its own,
	  and nothing is reused or cleared: for code that keeps them, until
	  it copies instead.
	- `-D crossbyte_check_events`: every arrival gets objects of its own,
	  and each is killed when the outermost call that handed it out
	  returns, or throws: the payload's bytes overwritten with `POISON`
	  and its length and position set to 0, the event's fields cleared.
	  Nothing is reused, so a killed one stays dead, and code that kept
	  one reads poison, or reads nothing and throws, at the line that
	  reads it. `CHECK`.
**/
@:noCompletion
@:access(crossbyte.events.Event)
class Arrivals {
	/** Whether events and payloads are reused: neither define is set. **/
	public static inline var REUSE:Bool = #if (crossbyte_fresh_events || crossbyte_check_events) false #else true #end;

	/** Whether what was handed out is killed once its call returns. **/
	public static inline var CHECK:Bool = #if crossbyte_check_events true #else false #end;

	/** What a killed payload's bytes read as. **/
	public static inline var POISON:Int = 0xDB;

	/**
		The most storage a reused payload keeps from one arrival to the
		next: 16 KB. Past every datagram a network path carries whole (1,500
		bytes, 9,000 with jumbo frames) and the messages a game sends each
		tick, so the hot path allocates nothing; and small enough that a
		server with 10,000 idle connections holds at most 160 MB for it
		(each connection's last message just under the limit), where 64 KB
		would let it hold 640 MB. A larger arrival is rare enough to have
		storage of its own, let go once its call returns; natively and on the
		jvm a WebSocket session's message past 64 KB takes it from its
		runtime's `StoragePool` and gives it back.
	**/
	public static inline var KEEP:Int = 16 * 1024;

	// What a payload past KEEP is given in place of its storage, so the
	// storage can go: nothing ever writes into a buffer of no length.
	static var __nothing:Null<haxe.io.Bytes> = null;

	/**
		Takes back everything a listener can leave on a reused payload, so
		the next arrival starts as a `ByteArray` made for it would: empty
		(`length` 0), read from `position` 0, in `ByteArray.defaultEndian`
		and `ByteArray.defaultObjectEncoding`. Its storage is kept, to be
		filled; storage a listener grew, or swapped in by compressing it, is
		what `release` lets go of past `KEEP`.

		Those four are all a `ByteArray` carries besides its bytes. Every
		reused payload is filled through this (`refill`, `refillView`,
		`sized`, and the buffers a session puts a message together in), and
		an owner that reads in an order of its own (a socket's `endian`, a
		session's `objectEncoding`) sets it after.

		So no setting a handler makes for one arrival carries into the next:
		the byte order a `TurnClient.onData` or `DtlsTransport.onMessage`
		handler sets, say, or the order a reliable server's `admit` reads a
		CONNECT's payload in.
	**/
	public static function reset(payload:ByteArray):Void {
		var data:ByteArrayData = payload;
		payload.length = 0;
		data.position = 0;
		data.endian = ByteArrayData.defaultEndian;
		data.objectEncoding = ByteArrayData.defaultObjectEncoding;
	}

	/**
		Fills `payload` with `length` bytes of `bytes` from `offset`, for an
		arrival: what it held is gone, its storage is used again when it is
		large enough, and it is read from position 0. Storage too small grows
		by half again, but past `KEEP` only to what this arrival needs.
	**/
	public static function refill(payload:ByteArray, bytes:haxe.io.Bytes, offset:Int, length:Int):Void {
		var data:ByteArrayData = payload;
		reset(payload);
		__room(data, length, true);
		data.__writeRange(bytes, offset, length);
		data.position = 0;
	}

	#if js
	/** `refill`, from a view of bytes: Node's `Buffer` a datagram arrives in, copied in once. **/
	public static function refillView(payload:ByteArray, view:js.lib.Uint8Array):Void {
		var data:ByteArrayData = payload;
		reset(payload);
		__room(data, view.length, true);
		@:privateAccess data.__appendView(view);
		data.position = 0;
	}
	#end

	/**
		Makes a reused payload `length` bytes long, read from position 0, for
		its caller to fill in place (a native read into its storage),
		without zeroing what is about to be overwritten. Storage grows as
		`refill`'s does.
	**/
	public static function sized(payload:ByteArray, length:Int):Void {
		var data:ByteArrayData = payload;
		reset(payload);
		__room(data, length, true);
		@:privateAccess data.__resize(length, 0);
	}

	/**
		Empties a reused payload once the call that handed it out has
		returned: length and position 0, so a reference kept past the call
		reads nothing, and storage past `KEEP` let go.
	**/
	public static function release(payload:ByteArray):Void {
		var data:ByteArrayData = payload;
		payload.length = 0;
		data.position = 0;
		if (@:privateAccess data.__length > KEEP) {
			var nothing = __nothing;
			if (nothing == null) {
				nothing = __nothing = haxe.io.Bytes.alloc(0);
			}
			@:privateAccess data.__setData(nothing);
		}
	}

	/**
		Room in a reused payload for `length` bytes in all, before it is
		written to piece by piece, as a message put back together from its
		fragments is: by half again each time it grows, but not past `KEEP`
		while what is needed is within it, so a message just under `KEEP`
		keeps its storage for the next. `last` says `length` is all there
		will be, which past `KEEP` is then exactly what is made room for.
	**/
	public static function room(payload:ByteArray, length:Int, last:Bool = false):Void {
		__room(payload, length, last);
	}

	/**
		Storage for `length` bytes, by half again, but no further than `KEEP`
		while `length` is within it. Past it, exactly `length` for a payload
		filled at once (`exact`), which is let go after its call anyway, and
		by half again for one still growing.
	**/
	static inline function __room(data:ByteArrayData, length:Int, exact:Bool):Void {
		if (length > @:privateAccess data.__length) {
			var grown:Int = length + (length >> 1);
			if (length > KEEP) {
				if (exact) {
					grown = length;
				}
			} else if (grown > KEEP) {
				grown = KEEP;
			}
			data.__reserve(grown);
		}
	}

	/**
		Kills `payload`: every byte it held overwritten with `POISON`, so
		storage kept by reference reads poison, and its length and position
		set to 0, so the payload kept itself reads empty. Its storage is
		kept, as a cleared `ByteArray`'s is.
	**/
	public static function kill(payload:Null<ByteArray>):Void {
		if (payload == null) {
			return;
		}
		var length:Int = payload.length;
		if (length > 0) {
			(payload : haxe.io.Bytes).fill(0, length, POISON);
		}
		payload.length = 0;
		payload.position = 0;
	}

	/**
		For a payload this side made for one arrival (not one it reuses),
		once the outermost call that handed it out has returned: released,
		emptied as a reused one is (`release`: length and position 0, its
		storage let go past `KEEP`), since an event that is reused may still
		refer to it, and its docs say what it was handed reads empty after
		its call; under `-D crossbyte_check_events` killed; under
		`-D crossbyte_fresh_events` left as it is.

		So a session's reused event does not go on holding the last payload
		made for it alone (a WebSocket message inflated from
		permessage-deflate, up to a megabyte) while its peer is quiet.
	**/
	public static inline function done(payload:Null<ByteArray>):Void {
		#if crossbyte_check_events
		kill(payload);
		#elseif !crossbyte_fresh_events
		if (payload != null) {
			release(payload);
		}
		#end
	}

	/**
		Throws `error` on, as it was thrown, for the catch that finishes with
		an arrival when a listener throws: natively with the stack it was
		thrown from.
	**/
	public static inline function rethrow(error:Dynamic):Void {
		#if cpp
		cpp.Lib.rethrow(error);
		#else
		throw error;
		#end
	}

	/** Clears an event's fields, under `-D crossbyte_check_events`, once its dispatch has returned. **/
	public static inline function doneWith(event:Null<Event>):Void {
		#if crossbyte_check_events
		if (event != null) {
			event.__kill();
		}
		#end
	}

	/**
		A copy of `payload` to keep: its bytes from 0 to its length in
		storage of their own, at the same position, in the same byte order
		and object encoding. Null for null.
	**/
	public static function copyOf(payload:Null<ByteArray>):Null<ByteArray> {
		if (payload == null) {
			return null;
		}
		var length:Int = payload.length;
		var copy:ByteArray = new ByteArray();
		if (length > 0) {
			copy.length = length;
			(copy : haxe.io.Bytes).blit(0, payload, 0, length);
		}
		copy.endian = payload.endian;
		copy.objectEncoding = payload.objectEncoding;
		copy.position = payload.position;
		return copy;
	}
}
