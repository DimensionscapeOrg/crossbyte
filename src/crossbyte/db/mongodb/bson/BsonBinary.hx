package crossbyte.db.mongodb.bson;

import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;

/**
	BSON binary data with a subtype.

	Plain `haxe.io.Bytes` is binary of subtype 0, the generic one, and the
	decoder returns subtype 0 as `Bytes`; this carries every other subtype,
	a UUID (4), an MD5 digest (5), encrypted data (6), a column (7), a
	sensitive value (8), a vector (9) or a user-defined one (128 and up), so
	it survives a round trip.
**/
@:access(crossbyte.db.mongodb.bson.ObjectId)
final class BsonBinary {
	public static inline var GENERIC:Int = 0x00;
	public static inline var FUNCTION:Int = 0x01;
	/** The old binary subtype, whose bytes carry a length of their own; decoded without it. **/
	public static inline var BINARY_OLD:Int = 0x02;
	public static inline var UUID_OLD:Int = 0x03;
	public static inline var UUID:Int = 0x04;
	public static inline var MD5:Int = 0x05;
	public static inline var ENCRYPTED:Int = 0x06;
	public static inline var COLUMN:Int = 0x07;
	public static inline var SENSITIVE:Int = 0x08;
	public static inline var VECTOR:Int = 0x09;
	public static inline var USER_DEFINED:Int = 0x80;

	public var subtype(default, null):Int;
	public var data(default, null):Bytes;

	/**
		Wraps `data`, kept as it is rather than copied, as `ObjectId` keeps
		its bytes: what is encoded is what `data` holds when the document is
		written. A payload a listener was handed for its call alone is
		written during that call, or wrapped as a copy (see
		`crossbyte.events.Event`).
	**/
	public function new(subtype:Int, data:Bytes) {
		if (subtype < 0 || subtype > 0xFF) {
			throw new ArgumentError('A BSON binary subtype is one byte, not $subtype.');
		}

		if (data == null) {
			throw new ArgumentError("BsonBinary needs data; use an empty Bytes for none.");
		}

		this.subtype = subtype;
		this.data = data;
	}

	/**
		A random (version 4) UUID, as MongoDB stores one: subtype 4. The
		random bytes come from the platform's secure generator where there is
		one.
	**/
	public static function randomUuid():BsonBinary {
		var bytes:Bytes = ObjectId.__randomBytes(16);
		bytes.set(6, (bytes.get(6) & 0x0F) | 0x40);
		bytes.set(8, (bytes.get(8) & 0x3F) | 0x80);
		return new BsonBinary(UUID, bytes);
	}

	/**
		Parses a UUID written as 32 hexadecimal digits, with or without the
		usual hyphens.
	**/
	public static function uuidFromString(text:String):BsonBinary {
		var hex:String = text == null ? "" : StringTools.replace(text, "-", "");

		if (hex.length != 32) {
			throw new ArgumentError('Not a UUID: "$text".');
		}

		var bytes:Bytes = Bytes.alloc(16);

		for (i in 0...16) {
			var high:Int = __nibble(StringTools.fastCodeAt(hex, i * 2));
			var low:Int = __nibble(StringTools.fastCodeAt(hex, i * 2 + 1));

			if (high < 0 || low < 0) {
				throw new ArgumentError('Not a UUID: "$text".');
			}

			bytes.set(i, (high << 4) | low);
		}

		return new BsonBinary(UUID, bytes);
	}

	/** The UUID form, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, of 16 bytes of data. **/
	public function toUuidString():String {
		if (data.length != 16) {
			throw new ArgumentError('A UUID is 16 bytes; this binary holds ${data.length}.');
		}

		var hex:String = data.toHex();
		return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" + hex.substr(12, 4) + "-" + hex.substr(16, 4) + "-" + hex.substr(20);
	}

	public function equals(other:BsonBinary):Bool {
		return other != null && other.subtype == subtype && other.data.compare(data) == 0;
	}

	public function toString():String {
		return 'BsonBinary($subtype, ${data.toHex()})';
	}

	@:noCompletion private static function __nibble(code:Int):Int {
		if (code >= "0".code && code <= "9".code) {
			return code - "0".code;
		}

		if (code >= "a".code && code <= "f".code) {
			return code - "a".code + 10;
		}

		if (code >= "A".code && code <= "F".code) {
			return code - "A".code + 10;
		}

		return -1;
	}
}
