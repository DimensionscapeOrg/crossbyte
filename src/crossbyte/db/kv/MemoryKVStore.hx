package crossbyte.db.kv;

import crossbyte.db.kv._internal.KVKeys;
import crossbyte.db.kv._internal.KVWrites;
import crossbyte.db.kv._internal.SortedKeys;
import crossbyte.errors.IllegalOperationError;
import haxe.ds.StringMap;
import haxe.io.Bytes;
#if target.threaded
import sys.thread.Mutex;
#end

/**
	A `KVStore` in memory, on every target: for tests, and for state a
	process keeps only while it runs (sessions, presence, a match's lobby)
	with the same revisions and compare-and-set the durable stores have.
	Nothing survives the process.

	```haxe
	import crossbyte.db.kv.MemoryKVStore;
	import haxe.io.Bytes;

	var store = new MemoryKVStore({maxValueBytes: 64 * 1024});
	store.put("sessions/7f3a", Bytes.ofString("alice"));
	var page = store.scan({prefix: "sessions/"});
	trace(page.items.length); // 1
	```

	Gets are a hash lookup; keys are also kept in order (`SortedKeys`) for
	scans, so a write of a new key costs a binary search and moves at most
	about a thousand references. A value is copied as it is put and as it is
	read, so neither the caller's buffer nor what it is handed back can change
	what is stored.

	**Threading.** Any thread may use it: each call holds the store for its
	length. A transaction holds it from `begin()` to `commit()` or
	`rollback()`, for the thread that began it, and other threads' calls wait
	until then, as they would for SQLite's write lock; a transaction left open
	keeps them waiting.

	A transaction keeps the record each key had before its first write in
	it, and `rollback()` puts those back: it costs what the transaction
	writes, not the size of the store.
**/
class MemoryKVStore implements KVStore {
	/** The limits it holds to, and its clock. **/
	public final options:KVOptions;

	/**
		Whether a transaction is open, on the thread asking. Asked from another
		thread while one is open, it waits for the transaction to end, as every
		call does, and then answers `false`.
	**/
	public var inTransaction(get, null):Bool;

	@:noCompletion private var __records:StringMap<KVRecord> = new StringMap();
	@:noCompletion private var __keys:SortedKeys = new SortedKeys();
	// The open transaction's record of what each key held before it first
	// wrote it, in the order written; null with none open.
	@:noCompletion private var __undo:Null<Array<KVUndo>> = null;
	@:noCompletion private var __logged:Null<StringMap<Bool>> = null;
	@:noCompletion private var __closed:Bool = false;
	#if target.threaded
	// Re-entrant, as sys.thread.Mutex is on every target: a transaction holds
	// it once from begin() on, and each call inside takes it again.
	@:noCompletion private final __lock:Mutex = new Mutex();
	#end

	@:noCompletion private static final __EMPTY:Bytes = Bytes.alloc(0);

	/**
		@param options Its limits and clock; `KVOptions`' defaults unless
		given. `table` is not used.
		@throws ArgumentError When a limit in `options` is out of range.
	**/
	public function new(?options:KVOptions) {
		this.options = (options == null ? ({} : KVOptions) : options).__check();
	}

	public function get(key:String):Null<KVRecord> {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		__enter();
		var record:Null<KVRecord> = __records.get(key);
		__leave();

		if (record == null || record.tombstone) {
			return null;
		}

		return __copy(record);
	}

	public function put(key:String, value:Bytes, schema:Int = 0):KVRecord {
		return __write(key, __own(key, value), schema, false, 0);
	}

	public function compareAndSet(key:String, value:Bytes, expected:Float, schema:Int = 0):Null<KVRecord> {
		KVWrites.checkExpected(expected, false);
		return __write(key, __own(key, value), schema, true, expected);
	}

	public function delete(key:String):Bool {
		return __delete(key, false, 0);
	}

	public function compareAndDelete(key:String, expected:Float):Bool {
		KVWrites.checkExpected(expected, true);
		return __delete(key, true, expected);
	}

	public function scan(?options:KVScanOptions):KVPage<KVRecord> {
		var scan:KVScanOptions = options == null ? ({} : KVScanOptions) : options;
		var range = KVKeys.rangeOf(scan, "", this.options.maxKeyBytes, this.options.maxScanLimit);

		if (range == null) {
			__enter();
			__leave();
			return new KVPage([], false, null);
		}

		var found:Array<KVRecord> = [];
		var more:Bool = false;
		var bytes:Float = 0.0;
		__enter();
		var keys = __keys.from(range.low);

		while (keys.hasNext()) {
			var key:String = keys.next();

			if (KVKeys.compare(key, range.high) >= 0) {
				break;
			}

			var record:KVRecord = __records.get(key);

			if (record.tombstone && !scan.includeTombstones) {
				continue;
			}

			if (found.length == scan.limit || (found.length > 0 && bytes + record.value.length > this.options.maxPageBytes)) {
				more = true;
				break;
			}

			bytes += record.value.length;
			found.push(record);
		}

		__leave();

		// Copied once the store is let go of: what is stored never changes,
		// only which record a key holds.
		var items:Array<KVRecord> = [for (record in found) __copy(record)];
		return new KVPage(items, more, more ? items[items.length - 1].key : null);
	}

	public function purgeTombstones(before:Float):Int {
		__enter();
		var purged:Array<String> = [];

		for (key => record in __records) {
			if (record.tombstone && record.updatedAt < before) {
				purged.push(key);
			}
		}

		for (key in purged) {
			__log(key);
			__records.remove(key);
			__keys.remove(key);
		}

		__leave();
		return purged.length;
	}

	public function begin():Void {
		__enter();

		if (__undo != null) {
			__leave();
			throw new IllegalOperationError("MemoryKVStore: a transaction is open already, and they do not nest.");
		}

		// Held from here to commit() or rollback(): this call's hold is kept.
		__undo = [];
		__logged = new StringMap();
	}

	public function commit():Void {
		__enter();

		if (__undo == null) {
			__leave();
			throw new IllegalOperationError("MemoryKVStore: commit() with no transaction open.");
		}

		__undo = null;
		__logged = null;
		__leave();
		// And begin()'s hold.
		__leave();
	}

	/**
		Puts back what the open transaction wrote over, and ends it; does
		nothing when none is open, so it is safe in a `catch` whatever
		happened before it.
	**/
	public function rollback():Void {
		__hold();

		if (__closed || __undo == null) {
			__leave();
			return;
		}

		__restore();
		__leave();
		__leave();
	}

	public function close():Void {
		__hold();

		if (__closed) {
			__leave();
			return;
		}

		var open:Bool = __undo != null;

		if (open) {
			__restore();
		}

		__closed = true;
		__records = new StringMap();
		__keys.clear();
		__leave();

		if (open) {
			__leave();
		}
	}

	/** How many keys it holds, tombstones included: what it costs in memory, for a gauge. **/
	public function count():Int {
		__enter();
		var count:Int = __keys.length;
		__leave();
		return count;
	}

	@:noCompletion private function get_inTransaction():Bool {
		__hold();
		var open:Bool = !__closed && __undo != null;
		__leave();
		return open;
	}

	/**
		Writes `value` under `key`, or only when the record is at `expected`
		if `conditional`; null when it was not.
	**/
	@:noCompletion private function __write(key:String, value:Bytes, schema:Int, conditional:Bool, expected:Float):Null<KVRecord> {
		__enter();
		var current:Null<KVRecord> = __records.get(key);

		if (conditional && !__at(current, expected)) {
			__leave();
			return null;
		}

		var now:Float = __stamp();
		var live:Bool = current != null && !current.tombstone;
		var written:KVRecord = new KVRecord(key, value, current == null ? 1.0 : current.revision + 1, live ? current.createdAt : now, now, schema, false);
		__log(key);

		if (current == null) {
			__keys.insert(key);
		}

		__records.set(key, written);
		__leave();
		return __copy(written);
	}

	@:noCompletion private function __delete(key:String, conditional:Bool, expected:Float):Bool {
		KVKeys.check(key, options.maxKeyBytes, "A key", false);
		__enter();
		var current:Null<KVRecord> = __records.get(key);

		if (current == null || current.tombstone || (conditional && current.revision != expected)) {
			__leave();
			return false;
		}

		var now:Float = __stamp();
		__log(key);
		__records.set(key, new KVRecord(key, __EMPTY, current.revision + 1, current.createdAt, now, 0, true));
		__leave();
		return true;
	}

	/** Whether `current` is at `expected`: 0 for none or a tombstone, else its revision. **/
	@:noCompletion private static inline function __at(current:Null<KVRecord>, expected:Float):Bool {
		return expected == 0 ? (current == null || current.tombstone) : (current != null && !current.tombstone && current.revision == expected);
	}

	/** `value`, checked and copied, so the caller's buffer is theirs again. **/
	@:noCompletion private function __own(key:String, value:Bytes):Bytes {
		KVWrites.checkWrite(key, value, options);
		return value.length == 0 ? __EMPTY : value.sub(0, value.length);
	}

	/** The clock's reading, letting go of the store if the clock throws. **/
	@:noCompletion private function __stamp():Float {
		try {
			return options.__now();
		} catch (e:Dynamic) {
			__leave();
			#if cpp
			cpp.Lib.rethrow(e);
			#else
			throw e;
			#end
			return 0;
		}
	}

	/** Keeps what `key` holds before the open transaction first writes it. **/
	@:noCompletion private inline function __log(key:String):Void {
		if (__undo != null && !__logged.exists(key)) {
			__logged.set(key, true);
			__undo.push(new KVUndo(key, __records.get(key)));
		}
	}

	/** Puts back what the open transaction wrote over, latest first, and ends it. **/
	@:noCompletion private function __restore():Void {
		var undo:Array<KVUndo> = __undo;
		__undo = null;
		__logged = null;
		var i:Int = undo.length;

		while (i-- > 0) {
			var entry:KVUndo = undo[i];
			var held:Bool = __records.exists(entry.key);

			if (entry.prior == null) {
				if (held) {
					__records.remove(entry.key);
					__keys.remove(entry.key);
				}
			} else {
				if (!held) {
					__keys.insert(entry.key);
				}

				__records.set(entry.key, entry.prior);
			}
		}
	}

	@:noCompletion private static function __copy(record:KVRecord):KVRecord {
		return new KVRecord(record.key, record.value.length == 0 ? Bytes.alloc(0) : record.value.sub(0, record.value.length), record.revision,
			record.createdAt, record.updatedAt, record.schema, record.tombstone);
	}

	/** Takes the store, closed or not. **/
	@:noCompletion private inline function __hold():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	/** Takes the store, refusing a closed one. **/
	@:noCompletion private inline function __enter():Void {
		__hold();

		if (__closed) {
			__leave();
			throw new IllegalOperationError("MemoryKVStore: the store is closed.");
		}
	}

	@:noCompletion private inline function __leave():Void {
		#if target.threaded
		__lock.release();
		#end
	}
}

/** What a key held before a transaction first wrote it: null for nothing. **/
@:noCompletion
private final class KVUndo {
	public final key:String;
	public final prior:Null<KVRecord>;

	public function new(key:String, prior:Null<KVRecord>) {
		this.key = key;
		this.prior = prior;
	}
}
