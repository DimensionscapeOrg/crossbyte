package crossbyte.db.kv;

import crossbyte.errors.ArgumentError;

/**
	What a `KVStore` holds to: the most a caller can make it keep or hand
	back, the SQL table it keeps its records in, and the clock it stamps them
	with. An object literal makes one, each field it leaves out at its default:
	`new MemoryKVStore({maxValueBytes: 65536})`.

	The limits are refusals, never truncations: a key or value past one is
	refused with an `ArgumentError`, and a stored value past
	`maxValueBytes` (one written by something other than this store) is
	refused as it is read, with a `KVError` of `TooLarge`, without being
	read.
**/
@:structInit
final class KVOptions {
	/** `table` unless given. **/
	public static inline var DEFAULT_TABLE:String = "kv";

	/** `maxKeyBytes` unless given: 1 KiB. **/
	public static inline var DEFAULT_MAX_KEY_BYTES:Int = 1024;

	/** `maxValueBytes` unless given: 1 MiB. **/
	public static inline var DEFAULT_MAX_VALUE_BYTES:Int = 1048576;

	/** `maxScanLimit` unless given: 1,000 records. **/
	public static inline var DEFAULT_MAX_SCAN_LIMIT:Int = 1000;

	/** `maxPageBytes` unless given: 4 MiB. **/
	public static inline var DEFAULT_MAX_PAGE_BYTES:Int = 4194304;

	/** The most `maxKeyBytes` may be set to: PostgreSQL's index holds a key of up to about 2.7 KB. **/
	public static inline var MOST_KEY_BYTES:Int = 2048;

	/**
		The table the SQL stores keep their records in, `kv` unless given,
		with their migrations recorded in `<table>_migrations`. A plain
		identifier (letters, digits and `_`, not starting with a digit) of at
		most 48 characters, since it is written into SQL. Several stores with
		different tables can share one database. The memory store has none.
	**/
	public final table:String = DEFAULT_TABLE;

	/**
		The most bytes a key takes in UTF-8, `DEFAULT_MAX_KEY_BYTES` unless
		given, and at most `MOST_KEY_BYTES`. A scan's bounds are held to it
		too.
	**/
	public final maxKeyBytes:Int = DEFAULT_MAX_KEY_BYTES;

	/**
		The most bytes a value takes: `DEFAULT_MAX_VALUE_BYTES`, 1 MiB, unless
		given, as Firestore holds a document to. A record stored past it is
		refused as it is read.
	**/
	public final maxValueBytes:Int = DEFAULT_MAX_VALUE_BYTES;

	/** The most records a scan may ask for (`KVScanOptions.limit`): 1,000 unless given. **/
	public final maxScanLimit:Int = DEFAULT_MAX_SCAN_LIMIT;

	/**
		The most bytes of values a page of a scan holds: 4 MiB unless given. A
		page ends before the record that would take it past this, and holds
		at least one record whatever its size. Without it, a page of
		`maxScanLimit` values of `maxValueBytes` each would be a gigabyte.
	**/
	public final maxPageBytes:Int = DEFAULT_MAX_PAGE_BYTES;

	/**
		Seconds since the epoch, for `KVRecord.createdAt` and `updatedAt`:
		the time of day unless given. Read once per write, inside the write.
	**/
	public final clock:Null<Void->Float> = null;

	/** The time of day, or `clock`'s reading. **/
	@:noCompletion public function __now():Float {
		return clock != null ? clock() : __timeOfDay();
	}

	/** Refuses limits that are not limits, and a table that is not a plain identifier. **/
	@:noCompletion public function __check():KVOptions {
		if (maxKeyBytes < 1 || maxKeyBytes > MOST_KEY_BYTES) {
			throw new ArgumentError('KVOptions.maxKeyBytes is from 1 to $MOST_KEY_BYTES: $maxKeyBytes is not.');
		}

		if (maxValueBytes < 0) {
			throw new ArgumentError('KVOptions.maxValueBytes must not be negative: $maxValueBytes.');
		}

		if (maxScanLimit < 1) {
			throw new ArgumentError('KVOptions.maxScanLimit is at least 1: $maxScanLimit is not.');
		}

		if (maxPageBytes < 1) {
			throw new ArgumentError('KVOptions.maxPageBytes is at least 1: $maxPageBytes is not.');
		}

		if (table == null || table.length > 48 || !~/^[A-Za-z_][A-Za-z0-9_]*$/.match(table)) {
			throw new ArgumentError('KVOptions.table is a plain identifier of at most 48 characters, since it is written into SQL: "$table" is not.');
		}

		return this;
	}

	@:noCompletion private static inline function __timeOfDay():Float {
		#if sys
		return Sys.time(); // time of day: a record is stamped with when it was written
		#elseif js
		return js.lib.Date.now() / 1000; // time of day: as above
		#else
		return Date.now().getTime() / 1000; // time of day: as above
		#end
	}
}
