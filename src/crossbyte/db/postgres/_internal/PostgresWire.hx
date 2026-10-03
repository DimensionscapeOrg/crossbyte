package crossbyte.db.postgres._internal;

import crossbyte.db.postgres.PostgresParameter;
import crossbyte.errors.SQLError;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * Where `PostgresRawResult` was declared before it became a class of its
 * own, `crossbyte.db.postgres.PostgresRawResult`; kept so the old import
 * still names it.
 */
typedef PostgresRawResult = crossbyte.db.postgres.PostgresRawResult;

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
 * at a time so neither side depends on the host's endianness, but for
 * `affectedRows`, unsigned 64 bits as two halves, low first, and
 * `lastInsertRowID`, unsigned 32. The count was 32 bits, read with `atoi`,
 * and past 2^31 was clamped or wrapped.
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
 * ok:      affectedRows : u32 low, u32 high
 *          lastInsertRowID : u32
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
		var head:Head = __head(cursor);
		var fieldCount:Int = head.fields.length;
		var rows:Array<Array<Null<Bytes>>> = [];

		for (_ in 0...head.rowCount) {
			var row:Array<Null<Bytes>> = [];

			for (_ in 0...fieldCount) {
				var length:Int = cursor.readInt();
				row.push(length < 0 ? null : cursor.readBytes(length));
			}

			rows.push(row);
		}

		return {
			fields: head.fields,
			rows: rows,
			affectedRows: head.affectedRows,
			lastInsertRowID: head.lastInsertRowID,
			command: __command(cursor)
		};
	}

	/**
		Decodes what the bridge returned for `request()`, each row made an
		object with a field per column holding its text, or `null` for NULL:
		with fixed slots, from the builder `shapes` keeps for the columns
		(see `AnonBuilder`). Each value is decoded once, from the block, with
		no `Bytes` made for it.

		The bridge rendered `request()`'s rows as JSON, column names repeated
		in every row, and Haxe parsed it: 2.3-3.1 µs a row of 8 columns, where
		this block took 0.38-0.63 (the audit's PostgresPerf).
	**/
	public static function decodeRows(data:Bytes, shapes:Array<crossbyte._internal.AnonBuilder>):PostgresRows {
		var cursor:Cursor = new Cursor(data);
		var head:Head = __head(cursor);
		var fieldCount:Int = head.fields.length;
		var shape:crossbyte._internal.AnonBuilder = crossbyte._internal.AnonBuilder.recent(shapes, head.fields);
		var rows:Array<Dynamic> = [];

		for (_ in 0...head.rowCount) {
			var row:Dynamic = shape.begin();

			for (field in 0...fieldCount) {
				var length:Int = cursor.readInt();

				if (length < 0) {
					shape.set(row, field, null);
				} else {
					shape.setString(row, field, cursor.readString(length));
				}
			}

			rows.push(row);
		}

		return new PostgresRows(head.fields, rows, head.affectedRows, head.lastInsertRowID, __command(cursor));
	}

	/**
		Reads what the bridge returned row by row, as `row`, an `SQLRow`
		over the block itself, moved on to each row in turn, handing each to
		`each`: `PostgresStatement.executeEach`. Nothing is made for a row or
		a value until it is asked for. Answers the rows the statement changed
		or returned.
	**/
	public static function eachRow(data:Bytes, each:crossbyte.db.sql.SQLRow->Void):Float {
		var cursor:Cursor = new Cursor(data);
		var head:Head = __head(cursor);
		var row:PostgresBlockRow = new PostgresBlockRow(data, head.fields);

		for (_ in 0...head.rowCount) {
			row.__read(cursor);
			each(row);
		}

		// What a write changed; a statement that returns rows changed none.
		return head.fields.length > 0 ? 0 : head.affectedRows;
	}

	/** Raises the server's message when the block carries an error, as decoding it would. **/
	public static function check(data:Bytes):Void {
		var cursor:Cursor = new Cursor(data);
		var status:Int = cursor.readInt();

		if (status == STATUS_ERROR) {
			var message:String = cursor.readBytes(cursor.readInt()).toString();
			throw new SQLError("request", message, message);
		}

		if (status != STATUS_OK) {
			throw new SQLError("request", 'status=$status', 'Postgres bridge returned an unknown status: $status.');
		}
	}

	/** The block's status, counts and column names, raising its error. **/
	@:noCompletion private static function __head(cursor:Cursor):Head {
		var status:Int = cursor.readInt();

		if (status == STATUS_ERROR) {
			var message:String = cursor.readBytes(cursor.readInt()).toString();
			throw new SQLError("request", message, message);
		}

		if (status != STATUS_OK) {
			throw new SQLError("request", 'status=$status', 'Postgres bridge returned an unknown status: $status.');
		}

		var low:Float = cursor.readUInt();
		var affectedRows:Float = cursor.readUInt() * 4294967296.0 + low;
		var lastInsertRowID:Float = cursor.readUInt();

		var fieldCount:Int = cursor.readInt();

		if (fieldCount < 0) {
			throw new SQLError("request", 'fieldCount=$fieldCount', "Postgres bridge sent a negative field count.");
		}

		var fields:Array<String> = [];

		for (_ in 0...fieldCount) {
			fields.push(cursor.readBytes(cursor.readInt()).toString());
		}

		var rowCount:Int = cursor.readInt();

		if (rowCount < 0) {
			throw new SQLError("request", 'rowCount=$rowCount', "Postgres bridge sent a negative row count.");
		}

		// A row of no columns reads nothing, so with `fieldCount` at zero the
		// loop below is bounded by the row count alone and not by the block
		// holding anything: 20 bytes claiming twenty million rows allocated
		// twenty million of them, and the count could have said two billion.
		// Every other shape is self-limiting, because each column costs at
		// least its four-byte length and the cursor runs out.
		//
		// It is also not a result Postgres produces. A statement returning no
		// columns returns no rows.
		if (fieldCount == 0 && rowCount > 0) {
			throw new SQLError("request", 'rowCount=$rowCount fieldCount=0',
				"Postgres bridge claimed rows in a result with no columns.");
		}

		return {
			fields: fields,
			rowCount: rowCount,
			affectedRows: affectedRows,
			lastInsertRowID: lastInsertRowID
		};
	}

	/** The command tag after the rows, when the bridge sent one. **/
	@:noCompletion private static function __command(cursor:Cursor):Null<String> {
		return cursor.remaining() >= 4 ? cursor.readString(cursor.readInt()) : null;
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

	/** The next value as unsigned 32 bits, so whole past 2^31. **/
	public function readUInt():Float {
		var value:Int = readInt();
		return value < 0 ? value + 4294967296.0 : value;
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

	/** The next `length` bytes as UTF-8 text, made a string once, with no `Bytes` between. **/
	public function readString(length:Int):String {
		if (length < 0) {
			throw new SQLError("request", 'length=$length', "Postgres bridge sent a negative length.");
		}

		__require(length);
		var out:String = __data.getString(__position, length);
		__position += length;
		return out;
	}

	/** Steps over the next `length` bytes, which must be there. **/
	public function skip(length:Int):Void {
		if (length > 0) {
			__require(length);
			__position += length;
		}
	}

	/** Where the next read starts. **/
	public inline function position():Int {
		return __position;
	}

	/** How many bytes are left to read. **/
	public inline function remaining():Int {
		return __data.length - __position;
	}
	private inline function __require(count:Int):Void {
		// Measured against what is left, rather than by adding to the position.
		// `__position + count` overflows Int for a large count and wraps
		// negative, and a negative is not greater than the length, so the test
		// passed and handed `Bytes.sub` a span running off the end of the
		// buffer. A 20-byte block claiming a field name of 2147483647 bytes
		// segfaulted the process, the exact failure this class exists to
		// turn into an exception.
		//
		// The subtraction cannot overflow: `__position` never passes
		// `__data.length`, because it only advances after this check succeeds.
		if (count > __data.length - __position) {
			throw new SQLError("request", 'need=$count at=$__position of=${__data.length}',
				"Postgres bridge returned a truncated result block.");
		}
	}
}

/** The part of a result block before its rows. **/
@:structInit
private class Head {
	public var fields:Array<String>;
	public var rowCount:Int;
	public var affectedRows:Float;
	public var lastInsertRowID:Float;
}

/** `request()`'s rows, decoded, with what the server said of the statement. **/
@:noCompletion
class PostgresRows {
	public var fields(default, null):Array<String>;
	public var rows(default, null):Array<Dynamic>;
	public var affectedRows(default, null):Float;
	public var lastInsertRowID(default, null):Float;
	public var command(default, null):Null<String>;

	public function new(fields:Array<String>, rows:Array<Dynamic>, affectedRows:Float, lastInsertRowID:Float, command:Null<String>) {
		this.fields = fields;
		this.rows = rows;
		this.affectedRows = affectedRows;
		this.lastInsertRowID = lastInsertRowID;
		this.command = command;
	}
}

/**
	`SQLRow` over a result block, standing on one row at a time: where each of
	its values starts in the block, and how long it is, -1 for NULL. Values
	are the text the server sent; `getBytes` decodes a `bytea`'s `\x` hex.
**/
@:noCompletion
@:allow(crossbyte.db.postgres._internal.PostgresWire)
class PostgresBlockRow implements crossbyte.db.sql.SQLRow {
	public var columnCount(get, never):Int;

	@:noCompletion private var __data:Bytes;
	@:noCompletion private var __fields:Array<String>;
	@:noCompletion private var __starts:Array<Int>;
	@:noCompletion private var __lengths:Array<Int>;

	@:noCompletion private function new(data:Bytes, fields:Array<String>) {
		__data = data;
		__fields = fields;
		__starts = [for (_ in fields) 0];
		__lengths = [for (_ in fields) -1];
	}

	/** Moves on to the row `cursor` is at, and past it. **/
	@:noCompletion private function __read(cursor:Cursor):Void {
		for (i in 0...__fields.length) {
			var length:Int = cursor.readInt();
			__starts[i] = cursor.position();
			__lengths[i] = length;
			cursor.skip(length);
		}
	}

	private function get_columnCount():Int {
		return __fields.length;
	}

	public function columnName(index:Int):String {
		__check(index);
		return __fields[index];
	}

	public function isNull(index:Int):Bool {
		__check(index);
		return __lengths[index] < 0;
	}

	public function getInt(index:Int):Int {
		var text:Null<String> = getString(index);

		if (text == null) {
			return 0;
		}

		var parsed:Null<Int> = Std.parseInt(text);
		return parsed == null ? 0 : parsed;
	}

	public function getFloat(index:Int):Float {
		var text:Null<String> = getString(index);

		if (text == null) {
			return 0.0;
		}

		var parsed:Float = Std.parseFloat(text);
		return Math.isNaN(parsed) ? 0.0 : parsed;
	}

	public function getBool(index:Int):Bool {
		var text:Null<String> = getString(index);
		return !(text == null || text == "" || text == "0" || text == "f" || text == "false");
	}

	public function getString(index:Int):Null<String> {
		__check(index);
		var length:Int = __lengths[index];
		return length < 0 ? null : __data.getString(__starts[index], length);
	}

	public function getBytes(index:Int):Null<Bytes> {
		__check(index);
		var length:Int = __lengths[index];
		return length < 0 ? null : PostgresWire.decodeByteaHex(__data.sub(__starts[index], length));
	}

	public function getValue(index:Int):Dynamic {
		return getString(index);
	}

	@:noCompletion private inline function __check(index:Int):Void {
		if (index < 0 || index >= __fields.length) {
			throw new crossbyte.errors.RangeError('Column $index of ${__fields.length}.');
		}
	}
}
