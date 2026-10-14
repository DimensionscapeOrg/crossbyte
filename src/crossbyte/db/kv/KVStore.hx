package crossbyte.db.kv;

import haxe.io.Bytes;

/**
	A durable store of records by string key, each with a revision, in the
	shape etcd and Consul keep theirs: get, put and delete; compare-and-set
	on the revision a record was read at; scans of a prefix or a range, in key
	order, a page at a time; and transactions.

	`MemoryKVStore` keeps its records in memory, on every target;
	`SQLiteKVStore` in an SQLite database, natively and on PHP; and
	`PostgresKVStore` in PostgreSQL, natively.

	```haxe
	import crossbyte.db.kv.KVStore;
	import crossbyte.db.kv.MemoryKVStore;
	import haxe.io.Bytes;

	var store:KVStore = new MemoryKVStore();
	var first = store.put("users/alice", Bytes.ofString("{}"));
	// Written only if nobody wrote it since it was read:
	var second = store.compareAndSet("users/alice", Bytes.ofString("{\"level\":2}"), first.revision);
	if (second == null) {
		trace("someone else wrote users/alice first: read it again");
	}
	```

	**Revisions.** A key's first write is revision 1 and each write after,
	a delete included, is one more. A delete leaves a tombstone with the
	revision, which a write after it goes on from, so a revision read once
	is never mistaken for a later value of the key (the "ABA" a
	compare-and-set otherwise falls for); `purgeTombstones` removes them
	once nothing still holds a revision of what they replaced.

	**Keys** are text of at most `KVOptions.maxKeyBytes` in UTF-8 (1 KiB
	unless set), not empty, holding no NUL, no unpaired surrogate and not
	U+10FFFF. They sort by code point, the order of their UTF-8, the same on
	every target and backend. **Values** are bytes, at most
	`KVOptions.maxValueBytes` (1 MiB unless set).

	**Threading.** `MemoryKVStore` may be used from any thread. An SQL store
	is used by one thread at a time, as its connection is; a
	`ConnectionPool` of them is how several threads share a database.

	It is an `ITransactionalConnection`, so a `ConnectionPool` rolls back a
	transaction a borrower left open.
**/
interface KVStore extends crossbyte.db.ITransactionalConnection {
	/**
		The record under `key`, or null when there is none or it was deleted.

		@throws ArgumentError When `key` is not a key.
		@throws KVError `TooLarge`, when the stored value is past
		`KVOptions.maxValueBytes`.
	**/
	function get(key:String):Null<KVRecord>;

	/**
		Writes `value` under `key`, whatever is there: a new record at
		revision 1 (one more than its tombstone's, after a delete), or the
		next revision of the one there. Answers the record written.

		@param schema The fingerprint of the value's format, 0 for none: kept
		as `KVRecord.schema` for a reader to check.
		@throws ArgumentError When `key` is not a key, or `value` is null or
		past `KVOptions.maxValueBytes`.
	**/
	function put(key:String, value:Bytes, schema:Int = 0):KVRecord;

	/**
		Writes `value` under `key` only if the record there is at revision
		`expected`, or, with `expected` 0, only if there is none (or only a
		tombstone): the check and the write are one step, which no other
		write can come between. Answers the record written, or null when the
		record was not at `expected`, the usual sign that someone else wrote
		it first: read it again and decide again.

		@throws ArgumentError As `put`, and when `expected` is negative or
		not a whole number.
	**/
	function compareAndSet(key:String, value:Bytes, expected:Float, schema:Int = 0):Null<KVRecord>;

	/**
		Deletes the record under `key`, leaving a tombstone at its next
		revision. Answers whether there was a record to delete.

		@throws ArgumentError When `key` is not a key.
	**/
	function delete(key:String):Bool;

	/**
		Deletes the record under `key` only if it is at revision `expected`,
		in one step as `compareAndSet` writes. Answers whether it was.

		@throws ArgumentError When `key` is not a key, or `expected` is not
		a revision (a whole number of 1 or more).
	**/
	function compareAndDelete(key:String, expected:Float):Bool;

	/**
		Records in ascending key order, a page at a time: those `options`
		bound (see `KVScanOptions`), up to its `limit` or
		`KVOptions.maxPageBytes` of values, whichever comes first, and none
		that are tombstones unless asked for. `KVPage.next` says where the
		next page starts. Null `options` reads the first page of the whole
		store.

		A page is read in one step, so it holds no record half written. Pages
		are read apart: a write between two may land in a page still to come
		or one already read, as in any store read a page at a time. Read them
		in a transaction for one view of them all.

		@throws ArgumentError When a bound is not a key, or `limit` is not
		from 1 to `KVOptions.maxScanLimit`.
		@throws KVError `TooLarge`, when a stored value in the page is past
		`KVOptions.maxValueBytes`.
	**/
	function scan(?options:KVScanOptions):KVPage<KVRecord>;

	/**
		Removes the tombstones written before `before` (seconds since the
		epoch, as `KVRecord.updatedAt`), and answers how many. A key whose
		tombstone is gone starts again at revision 1, so remove them only once
		nothing holds a revision from before the delete, as etcd's compaction
		does: a tombstone older than any read still in flight, an hour, a day.
	**/
	function purgeTombstones(before:Float):Int;

	/**
		Begins a transaction: the writes until `commit()` are kept together,
		and `rollback()` discards them all. One at a time: transactions do not
		nest.

		`MemoryKVStore` holds the store for the thread that began it, so other
		threads' calls wait for it to end. `SQLiteKVStore` begins with `BEGIN
		IMMEDIATE`, which takes the database's write lock at once.
		`PostgresKVStore` begins one at the connection's
		`PostgresConnection.isolationLevel`.

		@throws IllegalOperationError When a transaction is open already.
	**/
	function begin():Void;

	/**
		Commits the transaction `begin()` opened.

		@throws IllegalOperationError When there is none.
	**/
	function commit():Void;

	/**
		Closes the store and whatever it holds, with any transaction open
		rolled back. Calls after it throw an `IllegalOperationError`; closing
		again does nothing.
	**/
	function close():Void;
}
