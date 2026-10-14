package crossbyte.db.kv._internal;

import crossbyte.db.kv.KVError;
import crossbyte.db.kv.KVErrorKind;
import crossbyte.db.kv.KVOptions;
import crossbyte.db.kv.KVPage;
import crossbyte.db.kv.KVRecord;
import crossbyte.errors.ArgumentError;
import haxe.io.Bytes;

/**
	What every store refuses alike, and the scan the SQL stores share.
**/
@:noCompletion
class KVWrites {
	/** Refuses a key that is not one, and a value that is null or past `maxValueBytes`. **/
	public static function checkWrite(key:String, value:Bytes, options:KVOptions):Void {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);

		if (value == null) {
			throw new ArgumentError('The value for $key is null: an empty value is Bytes.alloc(0).');
		}

		if (value.length > options.maxValueBytes) {
			throw new ArgumentError('The value for $key is ${value.length} bytes, past the store\'s maxValueBytes of ${options.maxValueBytes}.');
		}
	}

	/** Refuses an expected revision that is not one: a whole number, of 1 or more where a record must be there. **/
	public static function checkExpected(expected:Float, mustBeRecord:Bool):Void {
		if (!(expected >= (mustBeRecord ? 1 : 0)) || expected != Math.ffloor(expected) || expected > 9007199254740992.0) {
			throw new ArgumentError('$expected is not a revision: a whole number of ${mustBeRecord ? 1 : 0} or more.');
		}
	}

	/** A whole number as SQL takes one, past 2^31 too, never with an exponent. **/
	public static function whole(value:Float):String {
		return value < 2147483648.0 ? Std.string(Std.int(value)) : haxe.Int64.toStr(haxe.Int64.fromFloat(value));
	}

	/** Refuses a stored value past `maxValue`, which is not read. **/
	public static inline function checkSize(key:String, size:Float, maxValue:Int):Void {
		if (size > maxValue) {
			throw new KVError(TooLarge, key,
				'$key holds ${Std.int(size)} bytes, past the store\'s maxValueBytes of $maxValue: it is refused, and was not read.');
		}
	}

	/**
		A page of a scan in one statement, for SQLite and PostgreSQL alike:
		the keys from `low` to `high` (and `live`'s condition, unless it is
		null), `fetch` of them (the limit and one more, to tell whether there
		are more), each with its value's size, its place and the bytes up to
		and including it; and the value itself only for the records the page
		keeps: within `limit`, at most `maxValue` bytes, and within
		`pageBytes` (the first whatever its size). So no value is read that
		the page does not hand back, and the sizes come from the row's header
		(`length` of a blob in SQLite, `octet_length` of a bytea in
		PostgreSQL, neither of which reads the value).

		Its columns: key, revision, created, updated, deleted, schema, size,
		place, running bytes, value.
	**/
	public static function scanSql(table:String, length:String, low:String, high:String, fetch:String, limit:String, maxValue:String,
			pageBytes:String, live:Null<String>):String {
		return 'SELECT p.record_key, p.revision, p.created_at, p.updated_at, p.deleted, p.value_schema, p.size, p.n, p.running, '
			+ 'CASE WHEN p.n <= $limit AND p.size <= $maxValue AND (p.n = 1 OR p.running <= $pageBytes) '
			+ 'THEN (SELECT v.record_value FROM $table AS v WHERE v.record_key = p.record_key) END AS value '
			+ 'FROM (SELECT record_key, revision, created_at, updated_at, deleted, value_schema, size, '
			+ 'row_number() OVER (ORDER BY record_key) AS n, sum(size) OVER (ORDER BY record_key ROWS UNBOUNDED PRECEDING) AS running '
			+ 'FROM (SELECT record_key, revision, created_at, updated_at, deleted, value_schema, $length(record_value) AS size '
			+ 'FROM $table WHERE record_key >= $low AND record_key < $high' + (live == null ? '' : ' AND ' + live)
			+ ' ORDER BY record_key LIMIT $fetch) AS w) AS p ORDER BY p.record_key';
	}
}

/**
	A page as the scan statement's rows make it: the rows in order, kept until
	one past the limit or past the page's bytes, which says there are more.
**/
@:noCompletion
final class PageReader {
	public final items:Array<KVRecord> = [];

	@:noCompletion private final __limit:Int;
	@:noCompletion private final __maxValue:Int;
	@:noCompletion private final __maxPage:Int;
	@:noCompletion private var __more:Bool = false;
	@:noCompletion private var __done:Bool = false;

	public function new(limit:Int, maxValue:Int, maxPage:Int) {
		__limit = limit;
		__maxValue = maxValue;
		__maxPage = maxPage;
	}

	/**
		Whether the row at place `n` is in the page; refuses one whose value is
		past the limit. Once a row is not, no row after it is.
	**/
	public function wants(n:Int, key:String, size:Float, running:Float):Bool {
		if (__done) {
			return false;
		}

		if (n > __limit || (n > 1 && running > __maxPage)) {
			__more = true;
			__done = true;
			return false;
		}

		KVWrites.checkSize(key, size, __maxValue);
		return true;
	}

	public inline function add(record:KVRecord):Void {
		items.push(record);
	}

	public function finish():KVPage<KVRecord> {
		return new KVPage(items, __more, __more ? items[items.length - 1].key : null);
	}
}
