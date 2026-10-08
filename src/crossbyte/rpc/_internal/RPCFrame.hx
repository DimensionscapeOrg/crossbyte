package crossbyte.rpc._internal;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;

/**
	A frame being written, and the buffer it is written in.

	A session keeps one and writes every frame it sends into it (calls,
	answers, error answers, pings and pongs, on both lanes) and hands it to
	`INetConnection.send` as it is, being a `ByteArray`. `send` copies what it
	keeps before it returns, so the next frame can be written over this one:
	a call allocates nothing to be framed. One asked for while the session's
	is still being written or sent (a handler calling or answering from
	inside a send that delivers at once) is a fresh one, used once.

	Written from `position`, little-endian as every frame is, each value
	making room for itself as it is written. A frame is begun with room for
	the most it can hold, as every frame here is, so it never grows on the
	way. `finish()` writes the length first and leaves `position` at 0 and
	`length` at the frame's, as `send` takes it.

	The writers are `put*`: a `ByteArray`'s own `write*` write in its
	`endian` and grow it differently, and a frame is little-endian whatever
	`ByteArray.defaultEndian` says.
**/
@:noCompletion
@:access(crossbyte.io.ByteArrayData)
class RPCFrame extends ByteArrayData {
	/**
		The most a session's buffer is kept at: one that grew past it, for a
		frame larger than this, is let go once that frame has been sent, and
		the next is framed in a new one. A session that sends large frames
		steadily (a snapshot of a few kilobytes to its client every tick)
		frames them all in one buffer, and a single huge one does not leave it
		holding megabytes. At 10,000 sessions the most they can hold is 160 MB;
		what they do hold is what their frames need, a few hundred bytes each
		for calls of a few numbers and strings.
	**/
	public static inline final KEEP_LIMIT:Int = 16384;

	/** The least a buffer is made at: a call of a few values, an answer, a ping. **/
	public static inline final MIN_CAPACITY:Int = 128;

	/** The byte a frame is filled with once sent, under `-D crossbyte_check_events`. **/
	public static inline final POISON:Int = 0xDB;

	/**
		Set from the moment a frame is begun until it has been sent, or will
		not be: a frame asked of the session meanwhile is a fresh one.
	**/
	public var busy:Bool = false;

	/**
		Set while an `RPCCallWriter` or `RPCRequestWriter` fills this frame,
		from `RPCSession.runtimeCall` or `runtimeRequest` until it is sent
		or cancelled: a writer used after that throws, rather than write into
		a frame that is another call's by then.
	**/
	public var building:Bool = false;

	/** For a writer: the session that sends the frame, its op and request id, the values written, and where their count goes. **/
	public var owner:Null<crossbyte.rpc.RPCSession<Dynamic, Dynamic>> = null;

	public var op:Int = 0;
	public var requestId:Int = 0;
	public var count:Int = 0;
	public var countAt:Int = 0;

	/** The bytes the buffer holds before it has to grow. **/
	public var capacity(get, never):Int;

	/** The bytes after the length, once finished: what `maxFrameLength` limits. **/
	public var payloadLength(get, never):Int;

	public function new(room:Int) {
		super(room < MIN_CAPACITY ? MIN_CAPACITY : room);
	}

	private inline function get_capacity():Int {
		return __length;
	}

	private inline function get_payloadLength():Int {
		return length - 4;
	}

	/**
		Begins a frame of at most `room` bytes, its length included: its
		flags and its op, and its request id when it has one. Grown first if
		`room` is more than it holds.
	**/
	public inline function begin(room:Int, flags:Int, op:Int, requestId:Int):Void {
		if (room > __length) {
			__reserve(room);
		}
		// Every byte up to the capacity is writable while the frame is: the
		// fixed-size writers check against `length`.
		length = __length;
		// The length goes first, once the frame is whole.
		set(4, flags);
		setInt32(5, op);
		position = 9;
		if (requestId != 0) {
			putVarUInt(requestId);
		}
	}

	/**
		Makes room for `count` more bytes from `position`, keeping what is
		written: an array of fixed-size elements makes room for all of them
		at once, then writes each where it goes with the `Bytes` setters.
	**/
	public inline function fit(count:Int):Void {
		__fit(count);
	}

	/** Makes room for `count` more bytes, keeping what is written. **/
	private inline function __fit(count:Int):Void {
		if (count > __length - position) {
			__enlarge(count);
		}
	}

	private function __enlarge(count:Int):Void {
		var wanted:Int = __length * 2;
		if (wanted - position < count) {
			wanted = position + count;
		}
		__reserve(wanted);
		length = __length;
	}

	public inline function putByte(value:Int):Void {
		__fit(1);
		set(position++, value);
	}

	public inline function putBool(value:Bool):Void {
		__fit(1);
		set(position++, value ? 1 : 0);
	}

	public inline function putInt(value:Int):Void {
		__fit(4);
		RPCBytes.setI32(this, position, value);
		position += 4;
	}

	public inline function putDouble(value:Float):Void {
		__fit(8);
		RPCBytes.setF64(this, position, value);
		position += 8;
	}

	/** `value` rounded to single precision: IEEE 754 binary32, four bytes. **/
	public inline function putFloat32(value:Float):Void {
		__fit(4);
		RPCBytes.setF32(this, position, value);
		position += 4;
	}

	/** The low sixteen bits of `value`, two bytes. **/
	public inline function putShort(value:Int):Void {
		__fit(2);
		RPCBytes.set16(this, position, value);
		position += 2;
	}

	/** An unsigned LEB128 varint: 0 to 0xFFFFFFFF, a negative `Int` as the unsigned value it holds. **/
	public inline function putVarUInt(value:Int):Void {
		__fit(5);
		var v:Int = value;
		while ((v & ~0x7F) != 0) {
			set(position++, (v & 0x7F) | 0x80);
			v >>>= 7;
		}
		set(position++, v);
	}

	/**
		`value` as its UTF-8 bytes after their count, as a varint: what
		`ByteArrayOutput.writeVarUTF` writes, without the `Bytes` it makes of
		the string first. Natively a string held a byte a character is copied
		as it stands (those bytes are its UTF-8), and on the jvm a short
		ASCII one a character at a time; anything else is encoded to UTF-8.

		@throws ArgumentError For `null`, which only an optional value (a
		        presence byte before it) can carry.
	**/
	public function putString(value:String):Void {
		if (value == null) {
			throw nullValue("String");
		}
		#if cpp
		if (!untyped __cpp__("{0}.isUTF16Encoded()", value)) {
			final count:Int = value.length;
			putVarUInt(count);
			__fit(count);
			if (count > 0) {
				untyped __cpp__("memcpy((char *){0}->GetBase() + {1}, {2}.raw_ptr(), {3})", getData(), position, value, count);
			}
			position += count;
			return;
		}
		#elseif (jvm || java)
		final count:Int = value.length;
		if (count <= DIRECT_TEXT_LIMIT && __ascii(value, count)) {
			putVarUInt(count);
			__fit(count);
			for (i in 0...count) {
				set(position + i, StringTools.fastCodeAt(value, i));
			}
			position += count;
			return;
		}
		#end
		final bytes:Bytes = crossbyte._internal.Utf8.bytesOf(value);
		putVarUInt(bytes.length);
		__putAll(bytes);
	}

	#if (jvm || java)
	/** The longest string the jvm copies a character at a time: past a few hundred, its encoder is no slower. **/
	private static inline final DIRECT_TEXT_LIMIT:Int = 256;

	private static function __ascii(value:String, count:Int):Bool {
		for (i in 0...count) {
			if (StringTools.fastCodeAt(value, i) >= 0x80) {
				return false;
			}
		}
		return true;
	}
	#end

	/**
		`bytes` after their count, as a varint. A `ByteArray` is its `length`
		bytes.

		@throws ArgumentError For `null`; see `putString`.
	**/
	public inline function putBytes(bytes:Bytes):Void {
		if (bytes == null) {
			throw nullValue("Bytes");
		}
		putVarUInt(bytes.length);
		__putAll(bytes);
	}

	private inline function __putAll(bytes:Bytes):Void {
		final count:Int = bytes.length;
		if (count > 0) {
			__fit(count);
			blit(position, bytes, 0, count);
			position += count;
		}
	}

	// ------------------------------------------- a writer's values, tagged

	/** Throws unless a writer may still write into this frame. **/
	public inline function requireBuilding():Void {
		if (!building) {
			throw new crossbyte.errors.IllegalOperationError(USED_WRITER);
		}
	}

	/** What a writer used after it was sent or cancelled throws. **/
	public static inline final USED_WRITER:String = "This RPC call writer has been sent or cancelled: take another from runtimeCall or runtimeRequest";

	public inline function valueInt(value:Int):Void {
		requireBuilding();
		putByte(RPCRuntimeCodec.TAG_INT);
		putInt(value);
		count++;
	}

	public inline function valueFloat(value:Float):Void {
		requireBuilding();
		putByte(RPCRuntimeCodec.TAG_FLOAT);
		putDouble(value);
		count++;
	}

	public inline function valueBool(value:Bool):Void {
		requireBuilding();
		putByte(value ? RPCRuntimeCodec.TAG_TRUE : RPCRuntimeCodec.TAG_FALSE);
		count++;
	}

	/** A `null` string goes as the lane's null, as `call` sends one. **/
	public inline function valueString(value:String):Void {
		requireBuilding();
		if (value == null) {
			putByte(RPCRuntimeCodec.TAG_NULL);
		} else {
			putByte(RPCRuntimeCodec.TAG_STRING);
			putString(value);
		}
		count++;
	}

	/** `null` goes as the lane's null; a `ByteArray` as its `length` bytes. **/
	public inline function valueBytes(value:Bytes):Void {
		requireBuilding();
		if (value == null) {
			putByte(RPCRuntimeCodec.TAG_NULL);
		} else {
			putByte(RPCRuntimeCodec.TAG_BYTES);
			putBytes(value);
		}
		count++;
	}

	public inline function valueNull():Void {
		requireBuilding();
		putByte(RPCRuntimeCodec.TAG_NULL);
		count++;
	}

	/** Any value the lane carries, tagged as `call` tags it. **/
	public function valueAny(value:Dynamic):Void {
		requireBuilding();
		RPCRuntimeCodec.writeValue(this, value);
		count++;
	}

	/**
		Ends a frame a writer filled: its count of values goes in the byte
		kept for it (moving the values along when the count needs more
		than one byte, past 127 of them, so the varint stays the one
		`RPCRuntimeCodec.writeArgs` writes), and the frame is finished.
	**/
	public function finishValues():RPCFrame {
		building = false;
		if (count < 0x80) {
			set(countAt, count);
			return finish();
		}
		var extra:Int = 0;
		var v:Int = count >>> 7;
		while (v != 0) {
			extra++;
			v >>>= 7;
		}
		__fit(extra);
		var from:Int = position - 1;
		while (from > countAt) {
			set(from + extra, get(from));
			from--;
		}
		final end:Int = position + extra;
		position = countAt;
		putVarUInt(count);
		position = end;
		return finish();
	}

	/**
		Ends the frame: its length is written first, and it is left as `send`
		takes it, `position` 0 and `length` the frame's.
	**/
	public inline function finish():RPCFrame {
		final end:Int = position;
		setInt32(0, end - 4);
		length = end;
		position = 0;
		return this;
	}

	/**
		Fills the buffer with `POISON` and empties it, so that what a
		transport kept of it reads as garbage, or as nothing. For
		`-D crossbyte_check_events`.
	**/
	public function poison():Void {
		length = __length;
		fill(0, __length, POISON);
		length = 0;
		position = 0;
	}

	/** What a `null` given where a value has to be is refused with. **/
	public static function nullValue(type:String):ArgumentError {
		return new ArgumentError('RPC cannot send a null $type where one is expected: to send null, declare the argument ?name or Null<$type>, or the answer Null<$type>.');
	}
}
