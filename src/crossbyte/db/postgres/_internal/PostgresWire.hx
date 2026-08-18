package crossbyte.db.postgres._internal;

import crossbyte.db.postgres.PostgresParameter;
import crossbyte.errors.SQLError;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * What one query returned, before anything has decided which columns are text.
 *
 * Values are bytes, not strings: a `bytea` column and a `text` column holding
 * invalid UTF-8 both have to survive the trip, and the driver's JSON result
 * path could carry neither.
 */
typedef PostgresRawResult = {
	var fields:Array<String>;
	var rows:Array<Array<Null<Bytes>>>;
	var affectedRows:Int;
	var lastInsertRowID:Int;
}

/**
 * The byte protocol between `PostgresConnection` and the libpq bridge.
 *
 * Both directions are length-prefixed rather than delimited or escaped, so a
 * value carrying NUL bytes, invalid UTF-8 or an embedded quote is just bytes
 * with a length in front of it. That is the property the previous path lacked:
 * parameters went into SQL text through an escape that stops at the first NUL,
 * and results came back as JSON strings that cannot represent a byte sequence
 * which is not valid UTF-8.
 *
 * Every integer is a signed little-endian 32-bit value, written and read a byte
 * at a time so neither side depends on the host's endianness.
 *
 * Parameter block:
 * ```
 * count : i32
 * count times:
 *   format : i32   0 = text, 1 = binary
 *   length : i32   -1 = SQL NULL, and no bytes follow
 *   bytes  : length bytes
 * ```
 *
 * Result block:
 * ```
 * status : i32   0 = ok, 1 = error
 * error:   messageLength : i32, message bytes
 * ok:      affectedRows : i32
 *          lastInsertRowID : i32
 *          fieldCount : i32
 *          fieldCount times: nameLength : i32, name bytes
 *          rowCount : i32
 *          rowCount * fieldCount times: length : i32 (-1 = NULL), value bytes
 * ```
 */
class PostgresWire {
	public static inline var FORMAT_TEXT:Int = 0;
	public static inline var FORMAT_BINARY:Int = 1;

	public static inline var STATUS_OK:Int = 0;
	public static inline var STATUS_ERROR:Int = 1;

	/**
	 * Encodes bound values for the bridge. Order is the placeholder order:
	 * the first entry is `$1`.
	 */
	public static function encodeParameters(params:Array<PostgresParameter>):Bytes {
		var out = new BytesBuffer();
		var count:Int = params == null ? 0 : params.length;
		__writeInt(out, count);

		for (i in 0...count) {
			switch (params[i]) {
				case Null:
					__writeInt(out, FORMAT_TEXT);
					// -1 rather than 0: a NULL and a zero-length value are
					// different rows, and collapsing them would be a data bug
					// that only shows up in a WHERE clause much later.
					__writeInt(out, -1);
				case Text(value):
					var bytes:Bytes = Bytes.ofString(value == null ? "" : value);
					__writeInt(out, FORMAT_TEXT);
					__writeInt(out, bytes.length);
					out.addBytes(bytes, 0, bytes.length);
				case Binary(value):
					var bytes:Bytes = value == null ? Bytes.alloc(0) : value;
					__writeInt(out, FORMAT_BINARY);
					__writeInt(out, bytes.length);
					out.addBytes(bytes, 0, bytes.length);
			}
		}

		return out.getBytes();
	}

	/**
	 * Decodes what the bridge returned, raising the server's own message when
	 * the block carries an error.
	 *
	 * Every read is bounds-checked against the block length. A truncated block
	 * means the bridge and this decoder disagree, and reading past the end of
	 * it would be a native crash rather than an exception.
	 */
	public static function decodeResult(data:Bytes):PostgresRawResult {
		var cursor:Cursor = new Cursor(data);
		var status:Int = cursor.readInt();

		if (status == STATUS_ERROR) {
			var message:String = cursor.readBytes(cursor.readInt()).toString();
			throw new SQLError("request", message, message);
		}

		if (status != STATUS_OK) {
			throw new SQLError("request", 'status=$status', 'Postgres bridge returned an unknown status: $status.');
		}

		var affectedRows:Int = cursor.readInt();
		var lastInsertRowID:Int = cursor.readInt();

		var fieldCount:Int = cursor.readInt();
		var fields:Array<String> = [];

		for (_ in 0...fieldCount) {
			fields.push(cursor.readBytes(cursor.readInt()).toString());
		}

		var rowCount:Int = cursor.readInt();
		var rows:Array<Array<Null<Bytes>>> = [];

		for (_ in 0...rowCount) {
			var row:Array<Null<Bytes>> = [];

			for (_ in 0...fieldCount) {
				var length:Int = cursor.readInt();
				row.push(length < 0 ? null : cursor.readBytes(length));
			}

			rows.push(row);
		}

		return {
			fields: fields,
			rows: rows,
			affectedRows: affectedRows,
			lastInsertRowID: lastInsertRowID
		};
	}

	/**
	 * Decodes PostgreSQL's text rendering of `bytea`, which is `\x` followed by
	 * two hex digits per byte.
	 *
	 * Results come back in text format, so this is what makes a binary column
	 * lossless anyway: hex is an exact encoding, and asking libpq for binary
	 * results instead would mean decoding every other column type from its
	 * network representation by OID.
	 *
	 * Anything not in that form is returned unchanged, since a `text` column
	 * beginning `\x` is a plain string and not a blob.
	 */
	public static function decodeByteaHex(value:Bytes):Bytes {
		if (value == null || value.length < 2 || value.get(0) != "\\".code || value.get(1) != "x".code) {
			return value;
		}

		var digits:Int = value.length - 2;

		if ((digits & 1) != 0) {
			return value;
		}

		var out:Bytes = Bytes.alloc(digits >> 1);

		for (i in 0...out.length) {
			var high:Int = __hex(value.get(2 + (i << 1)));
			var low:Int = __hex(value.get(3 + (i << 1)));

			if (high < 0 || low < 0) {
				return value;
			}

			out.set(i, (high << 4) | low);
		}

		return out;
	}

	/**
	 * Renders bytes as the `\x…` literal `bytea` accepts, for the paths that
	 * still build SQL text. Binding the value is better wherever it is
	 * possible; this exists so that the places which cannot are at least exact.
	 */
	public static function encodeByteaHex(value:Bytes):String {
		if (value == null) {
			return "\\x";
		}

		var out = new StringBuf();
		out.add("\\x");

		for (i in 0...value.length) {
			out.add(StringTools.hex(value.get(i), 2).toLowerCase());
		}

		return out.toString();
	}

	@:noCompletion private static inline function __writeInt(out:BytesBuffer, value:Int):Void {
		out.addByte(value & 0xFF);
		out.addByte((value >> 8) & 0xFF);
		out.addByte((value >> 16) & 0xFF);
		out.addByte((value >> 24) & 0xFF);
	}

	@:noCompletion private static inline function __hex(code:Int):Int {
		if (code >= "0".code && code <= "9".code) {
			return code - "0".code;
		}

		if (code >= "a".code && code <= "f".code) {
			return 10 + code - "a".code;
		}

		if (code >= "A".code && code <= "F".code) {
			return 10 + code - "A".code;
		}

		return -1;
	}
}

/**
 * A bounds-checked read head. Every field the decoder reads is checked against
 * the block length first, so a disagreement between the bridge and this file
 * raises rather than reading whatever follows the buffer.
 */
private class Cursor {
	private var __data:Bytes;
	private var __position:Int = 0;

	public function new(data:Bytes) {
		if (data == null) {
			throw new SQLError("request", "null", "Postgres bridge returned no result block.");
		}

		__data = data;
	}

	public function readInt():Int {
		__require(4);

		var value:Int = __data.get(__position)
			| (__data.get(__position + 1) << 8)
			| (__data.get(__position + 2) << 16)
			| (__data.get(__position + 3) << 24);

		__position += 4;
		return value;
	}

	public function readBytes(length:Int):Bytes {
		if (length < 0) {
			throw new SQLError("request", 'length=$length', "Postgres bridge sent a negative length.");
		}

		__require(length);
		var out:Bytes = __data.sub(__position, length);
		__position += length;
		return out;
	}

	private inline function __require(count:Int):Void {
		if (__position + count > __data.length) {
			throw new SQLError("request", 'need=$count at=$__position of=${__data.length}',
				"Postgres bridge returned a truncated result block.");
		}
	}
}
