package crossbyte.events._internal;

import crossbyte.io.ByteArray;

/**
	How CrossByte hands out what arrives, and the two defines that change
	it. See `Event` for the contract itself: an event, a payload handed to
	a hook called once per arrival, and the received bytes either carries
	are valid only during that call.

	- Released, the hot ones are reused: one event and one payload per
	  socket or session, filled again for each arrival. `REUSE`.
	- `-D crossbyte_fresh_events`: every arrival gets objects of its own,
	  and nothing is reused or cleared, for code that keeps them, until
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
		`kill(payload)` under `-D crossbyte_check_events`, and nothing
		otherwise: for a payload this side made for one arrival, once the
		outermost call that handed it out has returned.
	**/
	public static inline function done(payload:Null<ByteArray>):Void {
		#if crossbyte_check_events
		kill(payload);
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
