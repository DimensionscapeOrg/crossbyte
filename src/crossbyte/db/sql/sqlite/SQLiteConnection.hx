package crossbyte.db.sql.sqlite;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import sys.db.Sqlite;
import crossbyte.Function;
import crossbyte.Object;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.IOError;
import crossbyte.errors.SQLError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.EventType;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.io.File;
import crossbyte.sys.Worker;
import sys.db.Connection;
import sys.db.ResultSet;
import crossbyte.db.sql.sqlite._internal.SQLiteJob;
#if cpp
import crossbyte.db.sql.sqlite._internal.NativeSQLiteConnection;
#end
#if !php
import sys.thread.Deque;
import sys.thread.Mutex;
import sys.thread.Thread;
#end
import haxe.Int64;

/**
 * SQLite-specific connection with convenience properties and helpers
 * around common PRAGMAs and maintenance operations.
 *
 * Failures are reported as the other drivers report theirs. On a
 * synchronous connection an operation SQLite refuses -- `begin()`,
 * `commit()`, a statement -- is dispatched as an `SQLErrorEvent` and thrown
 * as its `SQLError`; `request()` throws the `SQLError` and dispatches
 * nothing, as `MySQLConnection.request()` does. On an asynchronous
 * connection it is dispatched, since the caller has returned by then.
 *
 * An asynchronous connection (`openAsync()`) is used by its worker alone.
 * What answers at once -- `request()`, and the properties and methods that
 * ask SQLite, such as `journalMode`, `lastInsertRowID` or `stats()` -- is
 * run by the worker in its turn, behind the work queued before it, while
 * the calling thread waits for the answer, for at most `queueTimeout`.
 * `connected` and `getSchemaResult()` answer from what the connection has
 * been told, and wait for nothing.
 */
@:access(crossbyte.db.sql.sqlite.SQLiteStatement)
class SQLiteConnection extends EventDispatcher implements crossbyte.db.ITransactionalConnection {
	public static inline var isSupported:Bool = #if cpp true; #else false; #end

	@:noCompletion private static inline var DEFAULT_CACHE_SIZE:Int = 2000;
	// What the worker decides of a job a cancel() may have overtaken.
	@:noCompletion private static inline var JOB_RUNS:Int = 0;
	@:noCompletion private static inline var JOB_WITHDRAWN:Int = 1;
	@:noCompletion private static inline var JOB_CANCELLED:Int = 2;
	@:noCompletion private static inline var CANCELLED_REASON:String = "Cancelled: cancel() was called before it ran.";

	/**
		Whether the database gives the space of deleted rows back to the
		file system at every commit, so its file shrinks: SQLite's FULL
		`auto_vacuum`, set when `open()` creates the database with
		`autoCompact`, as AIR's is. A database made by an earlier CrossByte
		with `autoCompact` is INCREMENTAL, which keeps its free pages until
		`PRAGMA incremental_vacuum` runs, and reads `false`; `compact()`
		reclaims the space of any database.
	**/
	public var autoCompact(get, null):Bool;
	/**
		How much of the database the connection keeps in memory, as SQLite's
		`PRAGMA cache_size` has it: a positive number of pages, or a negative
		number of KiB -- `-2000` is about 2 MB, SQLite's own default. `open()`
		sets 2000 pages, as AIR's does.

		It was a `UInt`, which can hold no negative: `-4096` set was written
		as 4294963200, which SQLite took as 0, and a size SQLite kept in KiB
		read back as four billion pages.
	**/
	public var cacheSize(get, set):Int;
	// public var columnNameStyle(get, set):String;

	/**
		Whether the connection is open. A synchronous connection asks SQLite.
		An asynchronous one answers from its events -- `SQLEvent.OPEN`
		dispatched, and neither `close()` called nor `SQLEvent.CLOSE`
		dispatched since -- and asks its worker nothing, so it never waits.
	**/
	public var connected(get, null):Bool;

	/**
		Seconds a call that answers at once waits on an asynchronous
		connection for its turn: `request()`, and every property and method
		that asks SQLite -- `journalMode`, `lastInsertRowID`, `stats()` and
		the rest. The worker runs such a call behind the work queued before
		it, so what it answers is the connection's state once that work is
		done. A call not started within this many seconds is withdrawn
		without running and throws an `SQLError`; one that has started is
		waited for to its end, as on a synchronous connection. `0` waits
		without limit. Defaults to 10. A synchronous connection has nothing
		to wait for, and does not read it.

		Those calls ran on the calling thread, on the connection the worker
		was running statements on: a read made while the worker stepped a
		statement finalized it under the worker, which crashed the process.

		@throws ArgumentError When set to a negative number, or NaN.
	**/
	public var queueTimeout(default, set):Float = 10.0;

	/**
		Whether a transaction is open. On cpp this is SQLite's own answer
		(`sqlite3_get_autocommit`), so a transaction begun as SQL text --
		`request("BEGIN")` -- counts, and one SQLite rolled back by itself
		after an error does not. It used to change only in `begin()`,
		`commit()` and `rollback()`, so a `ConnectionPool` handed a
		connection with a `BEGIN` sent as SQL on to the next borrower with
		its transaction still open.
	**/
	public var inTransaction(get, null):Bool;
	public var lastInsertRowID(get, null):Float;
	public var pageSize(get, null):UInt;

	/**
		The rows inserted, updated or deleted since the connection opened, as
		SQLite's `total_changes()` counts them: a `Float`, exact to 2^53. It
		was an `Int`, parsed with `Std.parseInt`, which past 2^31 answers
		differently on each target and never the number.
	**/
	public var totalChanges(get, null):Float;

	/**
	 * Controls the on-disk journaling mode for transactions.
	 *
	 * Common values: {@link JournalMode#WAL}, {@link JournalMode#DELETE}, etc.
	 * This is usually set once after opening a database.
	 *
	 * Getter reads the current effective mode from SQLite.
	 * Setter issues `PRAGMA journal_mode=<value>`.
	 *
	 * @see JournalMode
	 */
	public var journalMode(get, set):JournalMode;

	/**
	 * Durability level for writes (fsync strategy).
	 *
	 * - `OFF` = fastest, lowest durability
	 * - `NORMAL` = good balance (often used with WAL)
	 * - `FULL`/`EXTRA` = strongest durability, more I/O
	 *
	 * Getter/Setter wrap `PRAGMA synchronous`.
	 *
	 * @see SynchronousMode
	 */
	public var synchronous(get, set):SynchronousMode;

	/**
	 * Enables or disables foreign-key constraint enforcement.
	 *
	 * Getter/Setter wrap `PRAGMA foreign_keys`.
	 * Recommend enabling (`true`) for safety.
	 */
	public var foreignKeys(get, set):Bool;

	/**
	 * Threshold (in pages) at which SQLite auto-checkpoints the WAL.
	 *
	 * Getter/Setter wrap `PRAGMA wal_autocheckpoint`.
	 * Default is typically ~1000 pages.
	 */
	public var walAutoCheckpoint(get, set):Int;

	/**
	 * Milliseconds to wait on a locked database before failing.
	 *
	 * Getter/Setter wrap `PRAGMA busy_timeout`.
	 * Useful when multiple processes/threads contend for the DB.
	 */
	public var busyTimeout(get, set):Int;

	/**
	 * Memory-mapped I/O window size in bytes.
	 *
	 * Getter/Setter wrap `PRAGMA mmap_size`.
	 * Set `0` to disable; large values may improve read throughput on
	 * supported platforms/filesystems.
	 */
	public var mmapSize(get, set):Int64;

	/**
	 * Where SQLite stores temporary tables and indices.
	 *
	 * Getter/Setter wrap `PRAGMA temp_store`.
	 * Values: {@link TempStoreMode#DEFAULT}, {@link TempStoreMode#FILE}, {@link TempStoreMode#MEMORY}.
	 */
	public var tempStore(get, set):TempStoreMode;

	/**
	 * Securely overwrite deleted content.
	 *
	 * Getter/Setter wrap `PRAGMA secure_delete` (0/1).
	 * Enable for stronger privacy; disable for slightly better performance.
	 */
	public var secureDelete(get, set):Bool;

	/**
	 * Allow reading uncommitted (dirty) rows.
	 *
	 * Getter/Setter wrap `PRAGMA read_uncommitted` (0/1).
	 * Use with caution; can expose inconsistent data.
	 */
	public var readUncommitted(get, set):Bool;

	@:noCompletion private var __async:Bool = false;
	// Whether open() or openAsync() has been called, and close() has not, as
	// the calling thread sees it. An asynchronous connection is open from
	// openAsync() on, before its worker has opened anything.
	@:noCompletion private var __opened:Bool = false;
	// An asynchronous close() asked for and not yet over: until its CLOSE
	// arrives the old worker still holds its connection, and an open now
	// would race it.
	@:noCompletion private var __closing:Bool = false;
	// Whether the worker's OPEN has been dispatched, and its CLOSE (or the
	// open's failure) not yet: an asynchronous connection's `connected`, on
	// the runtime's thread.
	@:noCompletion private var __ready:Bool = false;
	// How many times cancel() has been called, as each job was queued and as
	// the worker reads it: work queued before the latest cancel is dropped.
	@:noCompletion private var __cancelEpoch:Int = 0;
	// How many cancel()s there have been, of the connection or of any of its
	// statements: a job notes it as it is queued, and the worker compares as
	// the job starts, asking whether the job was cancelled only when the two
	// differ. Moved on by an atomic add on cpp, after which a cancel() reads
	// the run under way -- as the worker publishes its run and then reads
	// this -- so that one of the two always sees the other.
	@:noCompletion private var __cancelGen:Int = 0;
	@:noCompletion private var __savepoints:Array<String> = [];
	@:noCompletion private var __savepointSeq:Int = 0;
	@:noCompletion private var __inTransaction:Bool = false;
	@:noCompletion private var __reference:String;
	@:noCompletion private var __initAutoCompact:Bool;
	@:noCompletion private var __initPageSize:UInt;

	@:noCompletion private var __openMode:SQLiteMode;
	@:noCompletion private var __connection:Connection;
	#if cpp
	// The same object as __connection, typed, for what only it can answer.
	@:noCompletion private var __native:NativeSQLiteConnection;
	#end
	@:noCompletion private var __sqlWorker:Worker;

	// Gated the same way the imports above are, not on cpp alone. The queue is
	// written by whichever thread calls the connection and read by the worker,
	// so it needs a structure built for that -- and neko, hl, java and jvm all
	// have real threads and both of these types. They were getting a plain
	// Array instead, pushed and popped with no lock at all.
	#if !php
	// The current worker's queue: replaced with the worker, so a worker that
	// is stopping keeps to its own.
	@:noCompletion private var __sqlQueue:SQLiteQueue;
	// Guards whether a call a caller has given up on runs (SQLiteCall). One
	// for the connection's life, so what holds it outlives a reopen.
	@:noCompletion private var __sqlMutex:Mutex = new Mutex();
	// The worker's thread, which runs at once what it asks of the
	// connection itself rather than queueing it behind itself.
	@:noCompletion private var __sqlThread:Null<Thread> = null;
	#end
	#if cpp
	// An asynchronous connection's record of its runs, in native memory: the
	// worker publishes there the run it has under way, a cancel() asks that
	// run to stop there, and the progress handler stops it. Made by
	// openAsync() and freed once the connection has closed, both on the
	// runtime's thread, which is where cancel() is called, so a cancel()
	// never reaches one freed. Null on a synchronous connection, which runs
	// its work on the thread that asks for it: its native connection keeps
	// a record of its own, with each request as a run.
	@:noCompletion private var __sqlRuns:cpp.Pointer<cpp.Void> = null;
	#end
	// On the worker: the statement whose result was left with rows unread
	// after its last page, until it is read to its end, run again or
	// cancelled. A cancelled one's result is let go of before the next job,
	// so its read ends and its rows are never read.
	@:noCompletion private var __pagedStatement:Null<SQLiteStatement> = null;

	public function new() {
		super();
	}

	public function walCheckpoint(mode:CheckpointMode = CheckpointMode.PASSIVE):WalCheckpointResult {
		var rs:ResultSet = __pragma('wal_checkpoint(' + mode + ')');
		if (rs != null && rs.hasNext()) {

			var row:Dynamic = rs.next();

			return {
				busy: Std.parseInt(Std.string(Reflect.field(row, "busy"))),
				log: Std.parseInt(Std.string(Reflect.field(row, "log"))),
				checkpointed: Std.parseInt(Std.string(Reflect.field(row, "checkpointed")))
			};
		}

		return {busy: 0, log: 0, checkpointed: 0};
	}

	public inline function walTruncate():WalCheckpointResult{
		return walCheckpoint(CheckpointMode.TRUNCATE);}


	public function integrityCheck():String {
		var rs:ResultSet = __pragma("integrity_check");

		return (rs != null && rs.hasNext()) ? Std.string(Reflect.field(rs.next(), "integrity_check")) : "";
	}

	/**
		The rows that break a foreign key, as `PRAGMA foreign_key_check`
		reports them. Each `rowid` is whole, exact to 2^53, or null for a row
		of a `WITHOUT ROWID` table; it was parsed into an `Int`, so a
		violation at rowid 3,000,000,000 was reported at 2147483647 -- the row
		a repair would then have touched.
	**/
	public function foreignKeyCheck():Array<FKViolation> {
		var rs:ResultSet = __pragma("foreign_key_check");
		var out:Array<FKViolation> = [];

		if (rs != null) {
			while (rs.hasNext()) {
				var row:Dynamic = rs.next();
				var rowid:Dynamic = Reflect.field(row, "rowid");

				out.push({
					table: Std.string(Reflect.field(row, "table")),
					rowid: rowid == null ? null : __wholeNumber(rowid),
					parent: Std.string(Reflect.field(row, "parent")),
					fkid: Std.int(__wholeNumber(Reflect.field(row, "fkid")))
				});
			}
		}
		return out;
	}

	public function compileOptions():Array<String> {
		var rs:ResultSet = __pragma("compile_options");
		var out:Array<String> = [];
		if (rs != null)
			while (rs.hasNext())
				out.push(Std.string(Reflect.field(rs.next(), "compile_options")));
		return out;
	}


	public function pragmaList():Array<String> {
		final rs = __pragma("pragma_list");
		var out:Array<String> = [];
		if (rs != null)
			while (rs.hasNext())
				out.push(Std.string(Reflect.field(rs.next(), "name")));
		return out;
	}

	public function stats():DBStats {
		var pageSizeRow:Dynamic = __pragmaFirstRow("page_size");
		var pageCountRow:Dynamic = __pragmaFirstRow("page_count");
		var freeListRow = __pragmaFirstRow("freelist_count");

		// Counted as Floats and multiplied as them: a page count can pass 2^31,
		// and the product of two Ints wrapped past 2 GB -- a 3 GB database
		// reported a negative size -- before it ever reached the Int64.
		var pageSize:Float = pageSizeRow != null ? __wholeNumber(Reflect.field(pageSizeRow, "page_size")) : 0;
		var pageCount:Float = pageCountRow != null ? __wholeNumber(Reflect.field(pageCountRow, "page_count")) : 0;
		var freeList:Float = freeListRow != null ? __wholeNumber(Reflect.field(freeListRow, "freelist_count")) : 0;

		return {
			pageSize: Std.int(pageSize),
			pageCount: pageCount,
			freeListCount: freeList,
			dbSizeBytes: __bytesOf(pageSize, pageCount),
			freeBytes: __bytesOf(pageSize, freeList)
		};
	}

	/**
	 * List user tables in the database.
	 *
	 * Thin public wrapper around the base-class introspection.
	 *
	 * @return Array of table names.
	 */
	public function tableList():Array<String> {
		return __getTables();
	}

	/**
		Opens another database in this connection under `name`, as SQLite's
		`ATTACH DATABASE`: its tables are then reached as `name.table` from
		this connection's statements, joins included, and written in the same
		transactions as the main database. `reference` is a path or a `File`,
		as `open` takes; null attaches a new in-memory database. Dispatches
		`SQLEvent.ATTACH`, or for an asynchronous connection
		`SQLErrorEvent.ERROR` when SQLite refuses -- a name in use, a file it
		cannot open.

		`SQLEvent.ATTACH` was declared, as AIR's `SQLConnection` has it, and
		nothing could make one: there was no way to attach a database at all.
	**/
	public function attach(name:String, reference:Object = null):Void {
		var path:String = ":memory:";
		if (reference != null && reference != ":memory:") {
			if (Std.isOfType(reference, String)) {
				path = new File(reference).nativePath;
			} else if (Std.isOfType(reference, File)) {
				var file:File = reference;
				path = file.nativePath;
			} else {
				throw new ArgumentError("The reference argument is neither a String to a path or a File Object.");
			}
		}
		__run("ATTACH DATABASE " + __quoteLiteral(path) + " AS " + __quoteIdentifier(name) + ";", SQLEvent.ATTACH);
	}

	/** Closes a database `attach` opened. Dispatches `SQLEvent.DETACH`. **/
	public function detach(name:String):Void {
		__run("DETACH DATABASE " + __quoteIdentifier(name) + ";", SQLEvent.DETACH);
	}

	/**
		Reads what `database` holds -- `"main"`, or one `attach` opened -- for
		`getSchemaResult()`: its tables with their columns, and its views,
		indices and triggers, as SQLite records them. Dispatches
		`SQLEvent.SCHEMA` when read.
	**/
	public function loadSchema(database:String = "main"):Void {
		__perform(SQLEvent.SCHEMA, () -> __schemaResult = __readSchema(database));
	}

	/** What the last `loadSchema` read, or null before one has finished. **/
	public function getSchemaResult():Null<SQLSchemaResult> {
		return __schemaResult;
	}

	@:noCompletion private var __schemaResult:Null<SQLSchemaResult> = null;

	@:noCompletion private function __readSchema(database:String):SQLSchemaResult {
		var schema:String = __quoteIdentifier(database == null || database == "" ? "main" : database);
		var result:SQLSchemaResult = {tables: [], views: [], indices: [], triggers: []};
		var rows:ResultSet = __connection.request("SELECT type, name, tbl_name, sql FROM " + schema
			+ ".sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name;");
		var entries:Array<Dynamic> = [];
		while (rows.hasNext()) {
			entries.push(rows.next());
		}

		for (entry in entries) {
			var name:String = Std.string(Reflect.field(entry, "name"));
			var table:String = Std.string(Reflect.field(entry, "tbl_name"));
			var sql:Dynamic = Reflect.field(entry, "sql");
			var text:Null<String> = sql == null ? null : Std.string(sql);
			switch (Std.string(Reflect.field(entry, "type"))) {
				case "table":
					result.tables.push({name: name, sql: text, columns: __readColumns(schema, name)});
				case "view":
					result.views.push({name: name, sql: text});
				case "index":
					result.indices.push({name: name, table: table, sql: text});
				case "trigger":
					result.triggers.push({name: name, table: table, sql: text});
				default:
			}
		}
		return result;
	}

	@:noCompletion private function __readColumns(schema:String, table:String):Array<SQLColumnSchema> {
		var columns:Array<SQLColumnSchema> = [];
		var rows:ResultSet = __connection.request("PRAGMA " + schema + ".table_info(" + __quoteIdentifier(table) + ");");
		while (rows.hasNext()) {
			var row:Dynamic = rows.next();
			var fallback:Dynamic = Reflect.field(row, "dflt_value");
			columns.push({
				name: Std.string(Reflect.field(row, "name")),
				dataType: Std.string(Reflect.field(row, "type")),
				allowNull: __wholeNumber(Reflect.field(row, "notnull")) == 0,
				primaryKey: __wholeNumber(Reflect.field(row, "pk")) > 0,
				defaultValue: fallback == null ? null : Std.string(fallback)
			});
		}
		return columns;
	}

	/** `sql` now, or on the worker for an asynchronous connection, then `type`. **/
	@:noCompletion private function __run(sql:String, type:EventType<SQLEvent>):Void {
		__perform(type, () -> __connection.request(sql));
	}

	/**
		Does `work` and reports it as `operation`: now, dispatching the
		`SQLEvent` -- or, when SQLite refuses, dispatching the `SQLErrorEvent`
		and throwing the `SQLError` -- or, on an asynchronous connection, on
		the worker, where the event is sent back to be dispatched instead.
		Every operation of the connection's own goes through here, so each
		reports the same way on both.
	**/
	@:noCompletion private function __perform(operation:String, work:Void->Void):Void {
		__requireOpen();

		if (__async) {
			var worker:Worker = __sqlWorker;
			__addToQueue(function() {
				var event:Event;

				try {
					work();
					event = new SQLEvent(operation);
				} catch (e:Dynamic) {
					event = new SQLErrorEvent(SQLErrorEvent.ERROR, __asSQLError(operation, e));
				}

				worker.sendProgress(event);
			}, operation);
			return;
		}

		try {
			work();
		} catch (e:Dynamic) {
			__fail(operation, e);
		}

		__dispatchSQLEvent(operation);
	}

	/**
		Runs `work` against the connection and answers what it answers: now,
		on a synchronous connection, and on an asynchronous one on the
		worker, in its turn, while the calling thread waits -- for at most
		`queueTimeout` before it starts -- so that only the worker ever
		touches an asynchronous connection. What SQLite refuses is thrown as
		an `SQLError` either way. Asked on the worker itself, by code it is
		running, it runs at once: queued, it would wait behind itself.
	**/
	@:noCompletion private function __now<T>(operation:String, work:Void->T):T {
		__requireOpen();

		#if !php
		if (__async && !__onWorker()) {
			var queue:SQLiteQueue = __sqlQueue;
			var call:SQLiteCall = new SQLiteCall(cast work, __sqlMutex);
			__addToQueue(call.run, operation, false, call);
			__awaitCall(call, operation, queue);

			if (call.failed) {
				if (Std.isOfType(call.failure, IllegalOperationError)) {
					// Closed under it: as a call on a closed connection.
					throw call.failure;
				}
				throw __asSQLError(operation, call.failure);
			}

			return call.result;
		}
		#end

		try {
			return work();
		} catch (e:Dynamic) {
			throw __asSQLError(operation, e);
		}
	}

	#if !php
	/**
		Waits for `call`, queued on `queue`: at most `queueTimeout` for the
		worker to take it up -- after which it is withdrawn and refused -- and
		then to its end. Waits in slices, looking between them whether the
		worker has stopped: after an open that failed it has, before the
		calling thread has heard so, and a call queued then waited out the
		whole of `queueTimeout` for nothing.
	**/
	@:noCompletion private function __awaitCall(call:SQLiteCall, operation:String, queue:SQLiteQueue):Void {
		var limit:Float = queueTimeout;
		var deadline:Float = limit > 0 ? haxe.Timer.stamp() + limit : 0;

		while (true) {
			var slice:Float = 0.05;

			if (deadline > 0) {
				var left:Float = deadline - haxe.Timer.stamp();

				if (left < slice) {
					slice = left;
				}
			}

			if (slice > 0 && call.waitDone(slice)) {
				return;
			}

			var gone:Bool = queue.gone;

			if (!gone && (deadline == 0 || haxe.Timer.stamp() < deadline)) {
				continue;
			}

			if (!call.withdraw()) {
				// Taken up as this gave up: its own work, waited out.
				call.waitDone(-1);
				return;
			}

			if (gone) {
				throw new IllegalOperationError("The SQLiteConnection is not open.");
			}

			throw new SQLError(operation, "Timed out waiting for the worker",
				'The connection\'s worker did not take this call up within queueTimeout ($limit s): it is still running the work queued before it. The call did not run.');
		}
	}
	#end

	/** Whether this is the worker's own thread. **/
	@:noCompletion private function __onWorker():Bool {
		#if !php
		var worker:Null<Thread> = __sqlThread;
		return worker != null && Thread.current() == worker;
		#else
		return false;
		#end
	}

	/**
		`result`, for whoever asked: as it is on a synchronous connection,
		whose rows the calling thread reads as it goes, and read whole on an
		asynchronous connection's worker, so the caller reads it without
		touching the connection.
	**/
	@:noCompletion private function __rows(result:ResultSet):ResultSet {
		return __async ? new SQLiteReadRows(result) : result;
	}

	private function set_queueTimeout(value:Float):Float {
		// Written to refuse NaN as well, which every comparison is false for.
		if (!(value >= 0)) {
			throw new ArgumentError("SQLiteConnection queueTimeout must be 0 or more seconds.");
		}

		return queueTimeout = value;
	}

	/**
		Reports a failed operation both ways, as the other drivers do: as the
		`SQLErrorEvent` it never was, for listeners, and as the `SQLError` it
		throws in place of the driver's raw `String`.
	**/
	@:noCompletion private function __fail(operation:String, e:Dynamic):Void {
		var error:SQLError = __asSQLError(operation, e);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
	}

	/** `e` as an `SQLError`: itself when it is one, or carrying its text, never itself. **/
	@:noCompletion private static function __asSQLError(operation:String, e:Dynamic):SQLError {
		if (Std.isOfType(e, SQLError)) {
			return e;
		}

		var detail:String = Std.string(e);
		return new SQLError(operation, detail, "Execution failed: " + detail);
	}

	/**
		`value` as an SQLite literal: `NULL`, `1` or `0` for a `Bool`, a
		number as one, and anything else as a quoted string -- a hex blob when
		it holds a NUL, which a quoted string would cut short. Needs no open
		connection, so an asynchronous statement's parameters can be bound on
		the calling thread before the worker has opened one.
	**/
	@:noCompletion private static function __literal(value:Dynamic):String {
		if (value == null) {
			return "NULL";
		}

		if (Std.isOfType(value, Bool)) {
			return value ? "1" : "0";
		}

		// Before Int: an Int64 held in a Dynamic passes for one on cpp and the
		// jvm, and printed as a Float loses what is past 2^53.
		if (__isInt64(value)) {
			return Int64.toStr(value);
		}

		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			return Std.string(value);
		}

		if (Std.isOfType(value, haxe.io.Bytes)) {
			return "x'" + (value : haxe.io.Bytes).toHex() + "'";
		}

		var text:String = Std.string(value);

		if (text.indexOf(String.fromCharCode(0)) >= 0) {
			var hex:StringBuf = new StringBuf();
			hex.add("x'");

			for (i in 0...text.length) {
				hex.add(StringTools.hex(StringTools.fastCodeAt(text, i), 2));
			}

			hex.add("'");
			return hex.toString();
		}

		return "'" + text.split("'").join("''") + "'";
	}

	/** Whether `value` is an `Int64`, and not an `Int` that converts to one. **/
	@:noCompletion private static inline function __isInt64(value:Dynamic):Bool {
		#if cpp
		return value != null && (untyped __cpp__("{0}->__GetType() == vtInt64", value) : Bool);
		#else
		return !Std.isOfType(value, Int) && Int64.isInt64(value);
		#end
	}

	/** Whether the connection is open, as the calling thread sees it. **/
	@:noCompletion private inline function __isOpen():Bool {
		return __async ? __opened : __connection != null;
	}

	/**
		Refuses what needs an open connection, as AIR's `SQLConnection`
		does, where each dereferenced the connection it did not have.
	**/
	@:noCompletion private inline function __requireOpen():Void {
		if (!__isOpen()) {
			throw new IllegalOperationError("The SQLiteConnection is not open.");
		}
	}

	/**
		The open connection, for what the calling thread asks of it now; an
		`IllegalOperationError` when there is none.
	**/
	@:noCompletion private function __live():Connection {
		var connection:Connection = __connection;

		if (connection == null) {
			throw new IllegalOperationError("The SQLiteConnection is not open.");
		}

		return connection;
	}

	/**
		Refuses an open while one is open, or an asynchronous close is not yet
		over, as AIR's `open()` does. The handle it had was replaced and left
		open -- unreachable, holding whatever locks it held -- and on an
		asynchronous connection a second worker started over the same object.
	**/
	@:noCompletion private function __refuseIfOpen():Void {
		if (__opened || __closing || __connection != null && !__async) {
			throw new IllegalOperationError("This SQLiteConnection is already open; close() it first"
				+ (__closing ? ", and wait for its CLOSE." : "."));
		}
	}

	/** `name` as an SQL identifier, quoted, so any name -- one with a space or a quote -- is one. **/
	@:noCompletion private static inline function __quoteIdentifier(name:String):String {
		if (name == null || name == "") {
			throw new ArgumentError("A database name is required.");
		}
		return '"' + name.split('"').join('""') + '"';
	}

	/** `text` as an SQL string literal. **/
	@:noCompletion private static inline function __quoteLiteral(text:String):String {
		return "'" + text.split("'").join("''") + "'";
	}

	public function analyze():Void {
		__perform(SQLEvent.ANALYZE, () -> __connection.request("ANALYZE;"));
	}

	public function begin(options:String = null):Void {
		__perform(SQLEvent.BEGIN, function() {
			__beginWith(options);
			__inTransaction = true;
		});
	}

	/**
		`BEGIN IMMEDIATE` and `BEGIN EXCLUSIVE` take their locks when the
		transaction starts, where a plain (deferred) one waits for its first
		write -- and can then fail with SQLITE_BUSY part way through. Both
		paths take the option from here: the asynchronous one ignored it and
		always began deferred.
	**/
	@:noCompletion private function __beginWith(options:String):Void {
		switch (options) {
			case "IMMEDIATE":
				__connection.request("BEGIN IMMEDIATE;");
			case "EXCLUSIVE":
				__connection.request("BEGIN EXCLUSIVE;");
			default:
				__connection.startTransaction();
		}
	}

	/**
		Removes the statistics `analyze()` gathered -- the rows of
		`sqlite_stat1`, and of `sqlite_stat4` where SQLite keeps one -- from
		every database the connection has open, attached ones included, and
		has the query planner read them again, so it plans without them, as
		AIR's `deanalyze()` does. Dispatches `SQLEvent.DEANALYZE` once that is
		done.

		It closed the connection and opened it again, and touched no
		statistics: an in-memory database lost every table, a file kept its
		statistics, and the session lost its transaction, attached databases
		and settings. On an asynchronous connection `DEANALYZE` came at once,
		and the reopen, made from the worker's thread, left the connection
		answering nothing.
	**/
	public function deanalyze():Void {
		__perform(SQLEvent.DEANALYZE, __removeStatistics);
	}

	@:noCompletion private function __removeStatistics():Void {
		var schemas:Array<String> = [];
		var list:ResultSet = __connection.request("PRAGMA database_list;");

		while (list.hasNext()) {
			schemas.push(Std.string(Reflect.field(list.next(), "name")));
		}

		for (schema in schemas) {
			var quoted:String = __quoteIdentifier(schema);
			var tables:Array<String> = [];
			var found:ResultSet = __connection.request("SELECT name FROM " + quoted
				+ ".sqlite_master WHERE type = 'table' AND name IN ('sqlite_stat1', 'sqlite_stat4');");

			while (found.hasNext()) {
				tables.push(Std.string(Reflect.field(found.next(), "name")));
			}

			if (tables.length == 0) {
				// Reloading a database with no statistics would make it an
				// empty sqlite_stat1.
				continue;
			}

			for (table in tables) {
				__connection.request("DELETE FROM " + quoted + "." + table + ";");
			}

			// The planner keeps what it read until it reads again, and
			// ANALYZE sqlite_schema reloads the statistics without gathering
			// any.
			__connection.request("ANALYZE " + quoted + ".sqlite_schema;");
		}
	}

	/**
		Stops what this connection is doing and what it has been asked to do,
		then dispatches `SQLEvent.CANCEL` once that has taken effect, as AIR's
		`cancel()` does. The connection stays open and usable: what is asked
		of it after the call runs as usual.

		On an asynchronous connection the work running now is interrupted --
		SQLite stops it at its next step, or within a thousand steps of its
		virtual machine when the call lands just as it starts, and it fails
		with "interrupted" -- and everything queued before the call is
		dropped, each reporting an `SQLErrorEvent` that says so, to its
		statement or to this connection, so nothing waiting on one waits for
		ever. `CANCEL` follows them. An open or a close already asked for is
		not dropped.

		On a synchronous connection nothing is queued: a statement running on
		another thread -- a `request()`, or a statement's `execute()` or
		`next()` -- is interrupted at its next step, and `CANCEL` is
		dispatched at once. A `request()` or a statement's `execute()` called
		before the call that has not yet reached SQLite fails as interrupted
		without running, and a statement SQLite is still preparing is
		stopped within a thousand steps of its virtual machine, or at its next
		step when its first one ends sooner: SQLite clears an interrupt that
		lands as a statement starts, and such a statement ran on, for as long
		as it took. What is asked for after the call runs as usual.

		SQLite takes a whole transaction back when a write inside it is
		interrupted, and leaves one open otherwise: `inTransaction` says which.
		On targets other than cpp a statement already running is not
		interrupted, and finishes first. Does nothing on a connection that is
		not open.

		It cancelled the connection's worker instead: the statement running
		finished with nothing left to report it, the work queued was dropped
		without a word, `CANCEL` came at once, and `close()` never closed,
		holding the connection and its file lock for the life of the process.
	**/
	public function cancel():Void {
		if (!__isOpen()) {
			return;
		}

		if (!__async) {
			// Its work runs on the thread that asks for it, so a cancel()
			// comes from another, and stops what runs there now.
			__interrupt();
			__dispatchSQLEvent(SQLEvent.CANCEL);
			return;
		}

		#if !php
		if (__sqlQueue.gone) {
			// Stopped by an open that failed, which has yet to be heard: not
			// open, so nothing to cancel.
			return;
		}

		// Counted before CANCEL is queued: the worker drops whatever it takes
		// up from now on that was queued before this.
		__cancelEpoch++;
		__countCancel();
		__stopRun(null);
		var worker:Worker = __sqlWorker;
		__addToQueue(() -> worker.sendProgress(new SQLEvent(SQLEvent.CANCEL)), SQLEvent.CANCEL, true);
		#end
	}

	/** Stops the statement running now at its next step, where the target can. **/
	@:noCompletion private function __interrupt():Void {
		#if cpp
		var native:NativeSQLiteConnection = __native;

		if (native != null) {
			native.interrupt();
		}
		#end
	}

	public function close():Void {
		if (__async) {
			if (!__opened) {
				// Closed already, or never opened: nothing to close.
				return;
			}

			__opened = false;
			// The calling thread's, as on a synchronous connection: closing
			// ends the transaction they belonged to.
			__savepoints = [];

			#if !php
			if (__sqlQueue.gone) {
				// Stopped by an open that failed, which has yet to be heard:
				// nothing was opened, so there is nothing to close, and no
				// CLOSE comes.
				__ready = false;
				return;
			}
			#end

			__closing = true;
			var worker:Worker = __sqlWorker;
			#if !php
			var queue:SQLiteQueue = __sqlQueue;
			#end
			var queued:Bool = __addToQueue(function() {
				var event:Event;
				var connection:Connection = __connection;
				// Let go of here, before the CLOSE that allows another open
				// is sent: the next worker's open sets these afresh.
				__connection = null;
				#if cpp
				__native = null;
				#end
				__inTransaction = false;
				__pagedStatement = null;

				try {
					if (connection != null) {
						connection.close();
					}
					event = new SQLEvent(SQLEvent.CLOSE);
				} catch (e:Dynamic) {
					event = new SQLErrorEvent(SQLErrorEvent.ERROR, __asSQLError(SQLEvent.CLOSE, e));
				}

				worker.sendProgress(event);

				// The loop this job is running inside checks the flag on its
				// next pass and returns, so the worker thread ends without
				// being blocked in pop(true) waiting for work that will never
				// arrive. The loop sends the worker's Complete once it has told
				// what was queued behind this that it will not run.
				#if !php
				queue.closing = true;
				#end
			}, SQLEvent.CLOSE, true);

			if (!queued) {
				// Its worker stopped as this was asked for, after an open that
				// failed: as above, nothing to close and no CLOSE to come. Left
				// closing, the connection refused every open after this one.
				__closing = false;
				__ready = false;
			}
		} else {
			var connection:Connection = __connection;

			if (connection == null) {
				// Not open, or closed already: nothing to close, as on the
				// other drivers. It dereferenced the connection it did not
				// have.
				return;
			}

			// Let go of first, so a connection whose close failed is not
			// reported open, and is not closed a second time.
			__connection = null;
			#if cpp
			__native = null;
			#end
			__opened = false;
			// Closing ends any transaction, as SQLite does by rolling it back.
			__inTransaction = false;
			__savepoints = [];

			try {
				connection.close();
			} catch (e:Dynamic) {
				__fail(SQLEvent.CLOSE, e);
			}
			__dispatchSQLEvent(SQLEvent.CLOSE);
		}
	}

	/**
		Runs `sql` and answers its result. Throws an `SQLError` when SQLite
		refuses it, where it let the driver's raw `String` escape.

		On a synchronous connection it runs now, on the calling thread, and
		the rows are read as they are asked for. On an asynchronous one the
		worker runs it in its turn, behind the work queued before it, while
		the calling thread waits (see `queueTimeout`), and reads every row
		there: what it answers holds them, to be read by name with `next()`.
		`getResult()`, `getIntResult()` and `getFloatResult()`, which read
		the row a statement stands on, throw on it. It ran on the calling
		thread while the worker ran statements on the same connection, and
		crashed the process.
	**/
	public function request(sql:String):ResultSet {
		if (!__async) {
			// Read first, before anything is made: a cancel() from another
			// thread from now on stops this request, however far it has got.
			var since:Int = __cancelsNow();
			return __now("request", () -> __requestSince(sql, since));
		}

		return __now("request", () -> __rows(__connection.request(sql)));
	}

	/**
		On a synchronous connection, the count of `cancel()`s so far, read as
		work is asked for: a `cancel()` made after it stops that work,
		however far it has got (see `__requestSince`). 0 off cpp, where
		nothing is stopped.
	**/
	@:noCompletion private inline function __cancelsNow():Int {
		#if cpp
		var native:NativeSQLiteConnection = __native;
		return native != null ? native.cancels() : 0;
		#else
		return 0;
		#end
	}

	/**
		On a synchronous connection, `sql` run now, asked for when
		`__cancelsNow()` read `since`: a `cancel()` made since stops it --
		before it starts, as it is prepared, or at its next step -- where one
		landing as SQLite prepared it was lost, and the statement ran on.
	**/
	@:noCompletion private function __requestSince(sql:String, since:Int):ResultSet {
		#if cpp
		var native:NativeSQLiteConnection = __native;

		if (native != null) {
			return native.requestSince(sql, since);
		}
		#end

		return __live().request(sql);
	}

	/**
		A statement's `text` run with its `parameters`, on the thread that
		runs the connection's work: natively prepared once and kept, its
		values bound to its `:name`s (`NativeSQLiteConnection.requestBound`);
		otherwise -- a connection that is not SQLite's own, such as a test's
		-- written into the text as literals, as before.
	**/
	@:noCompletion private function __requestStatement(text:String, parameters:Null<haxe.ds.StringMap<Dynamic>>, since:Int):ResultSet {
		#if cpp
		var native:NativeSQLiteConnection = __native;

		if (native != null) {
			return native.requestBound(text, parameters, since);
		}
		#end

		return __live().request(__substitute(text, parameters));
	}

	/** `text` with `parameters` written into it as literals; see `__literal`. **/
	@:noCompletion private static function __substitute(text:String, parameters:Null<haxe.ds.StringMap<Dynamic>>):String {
		if (parameters == null) {
			return crossbyte.db.sql._internal.ParamBinder.substituteWith(text, _ -> false, _ -> null, __literal, false);
		}

		return crossbyte.db.sql._internal.ParamBinder.substituteWith(text, name -> parameters.exists(name), name -> parameters.get(name), __literal, false);
	}

	/** `value` with each quote doubled, for inside an SQL string literal. Needs no SQLite. **/
	public function escape(value:String):String {
		__requireOpen();
		return value.split("'").join("''");
	}

	/**
		`value` as an SQL string literal, quoted -- a hex blob when it holds a
		NUL, which a quoted string would cut short. Needs no SQLite, so an
		asynchronous connection answers it at once.
	**/
	public function quote(value:String):String {
		__requireOpen();
		return __literal(value);
	}

	public function commit():Void {
		__endSavepoints();
		__perform(SQLEvent.COMMIT, function() {
			__connection.commit();
			__inTransaction = false;

			if (!__async) {
				__savepoints = [];
			}
		});
	}

	/**
		On an asynchronous connection, forgets the savepoints as a commit or
		rollback is asked for, on the calling thread, which keeps them:
		`setSavepoint()` records each there as it is asked for, and the
		calls after it name them. The worker cleared them as it ran the
		commit, replacing the list the calling thread was adding to and
		reading.
	**/
	@:noCompletion private inline function __endSavepoints():Void {
		if (__async) {
			__savepoints = [];
		}
	}

	public function compact():Void {
		__perform(SQLEvent.COMPACT, () -> __connection.request("VACUUM;"));
	}

	/**
		Opens the database at `reference` -- a path or a `File`, or null for
		a new in-memory one -- on the calling thread, and dispatches
		`SQLEvent.OPEN`.

		@throws IllegalOperationError When this connection is open already,
		or an asynchronous close is not yet over: `close()` it first. A second
		open replaced the connection it had and left that open.
	**/
	public function open(reference:Object = null, openMode:SQLiteMode = CREATE, autoCompact:Bool = false, pageSize:Int = 1024):Void {
		__refuseIfOpen();
		__async = false;

		try {
			__open(reference, openMode, autoCompact, pageSize);
		} catch (e:Dynamic) {
			__abandon();
			throw e;
		}

		__opened = true;
		__dispatchSQLEvent(SQLEvent.OPEN);
	}

	/**
		Closes what an open that failed part way had opened -- its settings
		refused after the file was -- so it is neither left open nor taken for
		an open connection.
	**/
	@:noCompletion private function __abandon():Void {
		var connection:Connection = __connection;
		__connection = null;
		#if cpp
		__native = null;
		#end

		if (connection != null) {
			try {
				connection.close();
			} catch (_:Dynamic) {}
		}
	}

	/**
		`open()`, on a worker thread of the connection's own, which runs
		everything the connection is asked to do from then on, in order, and
		sends back its events.

		@throws IllegalOperationError As `open()`. After `close()`, wait for
		its `SQLEvent.CLOSE` before opening again: the worker still holds the
		connection until then.
	**/
	public function openAsync(reference:Object = null, openMode:SQLiteMode = CREATE, autoCompact:Bool = false, pageSize:Int = 1024):Void {
		__refuseIfOpen();
		__async = true;
		__opened = true;
		__initSQLWorker();
		__addToQueue(__openAsync(reference, openMode, autoCompact, pageSize), SQLEvent.OPEN, true);
	}

	/**
		Releases a savepoint, discarding it and any nested inside it.

		With no name, releases the innermost savepoint this connection still
		holds. That used to mint a brand new name and issue `RELEASE` for a
		savepoint that had never existed, which SQLite refuses outright -- so
		the no-argument form could not work at all, and neither could
		`setSavepoint()`, whose generated name was never returned to anyone.
	**/
	public function releaseSavepoint(name:String = null):Void {
		var resolved:String = __takeSavepoint(name, false);
		__perform(SQLEvent.RELEASE_SAVEPOINT, () -> __connection.request('RELEASE $resolved;'));
	}

	public function rollback():Void {
		__endSavepoints();
		__perform(SQLEvent.ROLLBACK, function() {
			// Over either way, as the other drivers have it: a ROLLBACK that
			// fails has no transaction left to end.
			__inTransaction = false;

			if (!__async) {
				__savepoints = [];
			}

			__connection.rollback();
		});
	}

	/**
		Rolls back to a savepoint, cancelling any nested inside it. The
		savepoint itself stays active, as SQLite leaves it.

		With no name, rolls back to the innermost savepoint this connection
		holds -- and only to a full `rollback()` when it holds none. It used to
		roll the whole transaction back whenever the name was omitted, so a
		caller asking to return to a savepoint lost everything before it
		instead.
	**/
	public function rollbackToSavepoint(name:String = null):Void {
		if (name == null && __savepoints.length == 0) {
			rollback();
			return;
		}

		var resolved:String = __takeSavepoint(name, true);
		__perform(SQLEvent.ROLLBACK_TO_SAVEPOINT, () -> __connection.request('ROLLBACK TO $resolved;'));
	}

	/**
		Creates a savepoint and returns its name, so one created without a name
		can still be released or rolled back to. It returned nothing, which
		left a generated name known only to the statement that used it.
	**/
	public function setSavepoint(name:String = null):String {
		var resolved:String = __sanitizeSavePoint(name);

		if (__async) {
			// Recorded now: the calls after this one, made before the worker
			// has run it, name it.
			__savepoints.push(resolved);
		}

		__perform(SQLEvent.SET_SAVEPOINT, function() {
			__connection.request('SAVEPOINT $resolved;');

			if (!__async) {
				// Recorded only once SQLite has it, as the other drivers do, so
				// a savepoint that failed is not the one a nameless release or
				// rollback reaches for next.
				__savepoints.push(resolved);
			}
		});

		return resolved;
	}

	/**
		Resolves the savepoint a release or rollback refers to and updates the
		stack to match what the statement will do to it.

		`RELEASE x` discards `x` and everything nested inside it; `ROLLBACK TO
		x` discards what is nested inside but leaves `x` active. `keep` picks
		between the two.
	**/
	@:noCompletion private function __takeSavepoint(name:String, keep:Bool):String {
		if (name == null || name == "") {
			if (__savepoints.length == 0) {
				throw new IllegalOperationError("No savepoint is open on this connection; name one, or use rollback() to undo the transaction.");
			}

			var innermost:String = __savepoints[__savepoints.length - 1];

			if (!keep) {
				__savepoints.pop();
			}

			return innermost;
		}

		var resolved:String = __sanitizeSavePoint(name);
		var index:Int = -1;

		for (i in 0...__savepoints.length) {
			if (__savepoints[i] == resolved) {
				index = i;
			}
		}

		if (index >= 0) {
			// Everything created after it is gone either way; the savepoint
			// itself survives a rollback and not a release.
			__savepoints.splice(keep ? index + 1 : index, __savepoints.length);
		}

		return resolved;
	}

	@:noCompletion private inline function __sanitizeSavePoint(name:String):String {
		// A counter, not a timestamp. This read haxe.Timer.stamp() in
		// microseconds through Std.int, which collides: 2000 names generated
		// back to back produced 47 duplicates, and two savepoints sharing a
		// name make RELEASE and ROLLBACK TO act on the wrong one. It also
		// overflows Int about 36 minutes into a process and wraps every 72,
		// so a long-lived connection reissues names it has already used. The
		// same allocation haxe.Timer already does for its own ids.
		var n:String = (name != null && name != "") ? name : ("sp_" + (++__savepointSeq));

		return ~/[^\w]/g.replace(n, "_");
	}

	private function __openAsync(reference:Object = null, openMode:SQLiteMode = CREATE, autoCompact:Bool = false, pageSize:Int = 1024):Void->Void {
		var worker:Worker = __sqlWorker;
		#if !php
		var queue:SQLiteQueue = __sqlQueue;
		#end
		return function() {
			var event:Event;

			try {
				__open(reference, openMode, autoCompact, pageSize);
				event = new SQLEvent(SQLEvent.OPEN);
			} catch (e:Dynamic) {
				__abandon();
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, __asSQLError(SQLEvent.OPEN, e));
				// Nothing is open for what was queued behind this to run on:
				// the worker stops, telling each it will not run, and the
				// runtime's thread marks the connection closed when this error
				// reaches it.
				#if !php
				queue.closing = true;
				#end
			}
			worker.sendProgress(event);
		}
	}

	private function __open(reference:Object = null, openMode:SQLiteMode = CREATE, autoCompact:Bool = false, pageSize:Int = 1024):Void {
		__initAutoCompact = autoCompact;
		__initPageSize = pageSize;

		if (reference == null || reference == ":memory:") {
			__openMode = CREATE;
			__reference = ":memory:";
			__createConnection(__reference);
		} else {
			var file:File;
			__openMode = openMode;

			if (Std.isOfType(reference, String)) {
				try {
					file = new File(reference);
				} catch (e:Dynamic) {
					throw new ArgumentError(Std.string(e));
				}
			} else if (Std.isOfType(reference, File)) {
				file = reference;
			} else {
				throw new ArgumentError("The reference argument is neither a String to a path or a File Object.");
			}

			__reference = file.nativePath;

			switch (openMode) {
				case CREATE:
					__createConnection(file.nativePath);
				case READ, UPDATE:
					if (file.exists) {
						__createConnection(file.nativePath);
					} else {
						throw new ArgumentError("Database does not exist.");
					}
			}

			if (openMode == READ) {
				// hxcpp's glue opens every file to read and write, so READ only
				// checked that the file existed: an INSERT through it
				// succeeded. Held to reading here instead, as AIR's READ is.
				__connection.request("PRAGMA query_only = 1;");
			}
		}

		if (__openMode == CREATE) {
			__connection.request('PRAGMA page_size = $pageSize;');

			if (autoCompact) {
				// FULL: freed pages go back to the file system at every
				// commit, which is what autoCompact is. This set 2,
				// INCREMENTAL, which gives nothing back until PRAGMA
				// incremental_vacuum runs, and nothing here ran it.
				__connection.request("PRAGMA auto_vacuum = 1;");
			}

			if (__reference != null && __reference != ":memory:" && autoCompact) {
				__connection.request("VACUUM;");
			}
		}

		// Not through the property: on an asynchronous connection this is the
		// worker opening, and the property would ask the worker.
		__setCacheSize(DEFAULT_CACHE_SIZE);
	}

	private function __onSQLWorkerComplete(e:ThreadEvent):Void {}

	private function __onSQLWorkerError(e:ThreadEvent):Void {}

	/**
		On the runtime's thread: what the worker sent, dispatched where it
		belongs -- a statement's page and event to the statement, the
		connection's own events here.

		Anything but an `SQLEvent` used to be taken for a statement's message,
		so every `SQLErrorEvent` of the connection's own -- a refused `BEGIN`,
		a failed open -- was read as one, its absent statement dereferenced,
		and the process died. A statement's failure died the same way, on its
		absent result set.
	**/
	private function __onSQLWorkerProgress(e:ThreadEvent):Void {
		var message:Dynamic = e.message;

		if (Std.isOfType(message, SQLiteStatementMessage)) {
			var answer:SQLiteStatementMessage = message;
			answer.statement.__receive(answer);
			return;
		}

		if (Std.isOfType(message, SQLErrorEvent)) {
			var failure:SQLErrorEvent = message;
			var operation:String = failure.error != null ? failure.error.operation : null;

			if (operation == SQLEvent.OPEN) {
				// The worker stopped: nothing was opened.
				__opened = false;
				__ready = false;
				__freeRuns();
			} else if (operation == SQLEvent.CLOSE) {
				__closing = false;
				__ready = false;
				__freeRuns();
			}
		} else if (Std.isOfType(message, SQLEvent)) {
			var type:String = (message : SQLEvent).type;

			if (type == SQLEvent.OPEN) {
				__ready = true;
			} else if (type == SQLEvent.CLOSE) {
				// The worker has let go of its connection: another may be
				// opened.
				__closing = false;
				__ready = false;
				__freeRuns();
			}
		}

		if (Std.isOfType(message, Event)) {
			__dispatchEvent(message);
		}
	}

	private function __initSQLWorker():Void {
		#if !php
		__sqlQueue = new SQLiteQueue();
		#end
		#if cpp
		// Here, on the runtime's thread, before the worker it is for: see
		// __sqlRuns.
		__sqlRuns = NativeSQLiteConnection.newRuns();
		#end
		__sqlWorker = new Worker();
		__sqlWorker.addEventListener(ThreadEvent.COMPLETE, __onSQLWorkerComplete);
		__sqlWorker.addEventListener(ThreadEvent.ERROR, __onSQLWorkerError);
		__sqlWorker.addEventListener(ThreadEvent.PROGRESS, __onSQLWorkerProgress);
		__sqlWorker.doWork = __sqlWork;
		__sqlWorker.run();
	}

	private function __sqlWork(m:Dynamic):Void {
		#if !php
		__sqlThread = Thread.current();
		// This worker's own, read once: a worker stopping as the next starts
		// took the next one's work from its queue, and told its Worker it was
		// complete.
		var queue:SQLiteQueue = __sqlQueue;
		var worker:Worker = __sqlWorker;
		#if cpp
		var runs:cpp.Pointer<cpp.Void> = __sqlRuns;
		#end
		// Numbers the runs this worker publishes; 0 is none.
		var run:Int = 0;

		while (!queue.closing) {
			// Blocks until there is work. The Array path this replaces spun:
			// an empty queue fell through to haxe.Timer.delay(fn, 0), which
			// schedules rather than waits, so an idle async connection burned
			// a core on every target that was not hl or neko.
			var job:SQLiteJob = queue.jobs.pop(true);

			if (job == null) {
				continue;
			}

			if (__pagedStatement != null) {
				__dropCancelledPage();
			}

			if (job.keep) {
				job.run();
				continue;
			}

			var statement:Null<SQLiteStatement> = job.statement;

			if (statement != null && job.fresh) {
				// An execute(): what a run of its own left unread is let go
				// of, and what another statement left unread is read now --
				// before this run is published, so that a stop asked for it
				// cannot reach those rows.
				__letGo(statement.__resultSet);
				statement.__resultSet = null;
				__settle();
			}

			if (++run == 0) {
				run = 1;
			}

			if (statement != null) {
				// Before the run is published, for its cancel() to read after
				// reading the run under way.
				statement.__runId = run;
			}

			#if cpp
			// Published, then the count of cancel()s read: the same as when
			// the job was queued, nothing has cancelled it -- and a cancel()
			// from now on sees this run, and stops it. Only otherwise is it
			// asked what was cancelled.
			var count:Int = runs != null ? NativeSQLiteConnection.publish(runs, run, cpp.Pointer.addressOf(__cancelGen)) : __cancelGen;
			var verdict:Int;

			if (count == -1 && runs != null) {
				// A cancel() is stopping a run: waited for, so that its
				// interrupt lands before this run starts, not inside it.
				__awaitStop(runs);
				verdict = __verdict(job);
			} else {
				verdict = count == job.gen ? JOB_RUNS : __verdict(job);
			}
			#else
			var verdict:Int = __verdict(job);
			#end

			if (verdict != JOB_RUNS) {
				#if cpp
				if (runs != null) {
					NativeSQLiteConnection.unpublish(runs);
				}
				#end

				if (verdict == JOB_CANCELLED) {
					__refuse(job, CANCELLED_REASON, false, worker);
				}

				continue;
			}

			if (statement != null) {
				statement.__work(job);
			} else {
				job.run();
			}

			#if cpp
			if (runs != null) {
				NativeSQLiteConnection.unpublish(runs);
			}
			#end
		}

		// Queued behind the close, or behind an open that failed: each is
		// told it will never run, where it waited for ever. A cancel's own
		// report still goes out. Marked gone first, so that what is asked for
		// from now on is refused where it is asked for, and a call waiting
		// stops waiting. Under `ending`, and `ended` after: work that joins
		// the queue as this pass finds it empty takes itself back out
		// (__enqueue), where it sat for ever, neither run nor refused.
		queue.gone = true;
		queue.ending.acquire();

		try {
			var left:SQLiteJob = queue.jobs.pop(false);

			while (left != null) {
				if (left.keep) {
					left.run();
				} else {
					__refuse(left, "The connection is closed.", true, worker);
				}

				left = queue.jobs.pop(false);
			}
		} catch (e:Dynamic) {
			queue.ended = true;
			queue.ending.release();
			throw e;
		}

		queue.ended = true;
		queue.ending.release();

		// sendComplete, not cancel. cancel() detaches the runtime listener and
		// frees the message queue immediately, on this thread -- so every
		// event queued here and not yet drained by the main thread was
		// destroyed, the CLOSE among them. A Complete message travels the
		// same queue in order, so everything sent before it is dispatched
		// first and the listener is detached when it is drained, on the main
		// thread, with nothing outstanding.
		worker.sendComplete();
		#end
	}

	/**
		On the worker: tells whoever queued `job` that it will not run, and
		why -- a caller waiting on it as a call made on a connection that is
		not open gets told, when the connection has `closed`.
	**/
	@:noCompletion private function __refuse(job:SQLiteJob, reason:String, closed:Bool, worker:Worker):Void {
		var error:SQLError = new SQLError(job.operation, reason, reason);

		#if !php
		if (job.call != null) {
			job.call.refuse(closed ? new IllegalOperationError("The SQLiteConnection is not open.") : error);
			return;
		}
		#end

		if (job.statement != null) {
			var answer:SQLiteStatementMessage = new SQLiteStatementMessage(job.statement, false, job.statementEpoch);
			answer.fail(error);
			worker.sendProgress(answer);
		} else {
			worker.sendProgress(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		}
	}

	/**
		Hands the connection's own work to the worker: `run`, which reports as
		`operation` to this connection, or to `call` -- dropped by a
		`cancel()` made after it was queued unless it `keep`s. A statement's
		work goes through `__queueStatement`, and both through `__enqueue`,
		rather than opening the queue themselves. The queue is a Deque, which
		locks for itself; this took the mutex around it as well, which nothing
		needed. Answers whether it was queued: work that `keep`s is dropped
		unqueued when the worker has stopped (see `__enqueue`).
	**/
	private function __addToQueue(run:Void->Void, operation:String, keep:Bool = false, ?call:SQLiteCall):Bool {
		#if !php
		return __enqueue(new SQLiteJob(run, operation, null, __cancelEpoch, keep, call, __cancelGen, false, null, 0));
		#else
		return true;
		#end
	}

	/**
		Queues `statement`'s work: its `execute()` of `sql` when `fresh`, and
		otherwise its `next()`; `prefetch` rows a page. The statement runs it
		on the worker, from the job itself, with no function made for it.
	**/
	@:noCompletion private function __queueStatement(statement:SQLiteStatement, fresh:Bool, sql:Null<String>, prefetch:Int,
			?parameters:haxe.ds.StringMap<Dynamic>):Void {
		#if !php
		__enqueue(new SQLiteJob(null, SQLEvent.RESULT, statement, __cancelEpoch, false, null, __cancelGen, fresh, sql, prefetch, parameters));
		#end
	}

	#if !php
	/**
		Queues `job` for the worker, and answers true. When the worker has
		stopped -- an open that failed, not yet heard of -- nothing would ever
		run it: what would have waited for ever is refused, as on a
		connection that is not open, and what keeps has nothing left to do,
		and answers false.
	**/
	@:noCompletion private function __enqueue(job:SQLiteJob):Bool {
		var queue:SQLiteQueue = __sqlQueue;

		if (!queue.gone) {
			queue.jobs.add(job);

			// Read again once queued: the worker marks its queue gone before
			// its last pass, so a job that finds it not gone here was queued
			// in time for that pass. One that read it not gone above and was
			// queued only after the pass had found the queue empty sat there
			// for ever, unanswered. A plain read, ordered by the queue's own
			// lock: the worker's mark comes before its last look at the
			// queue, and this read after the job joined it.
			if (!queue.gone || !__takeBack(queue, job)) {
				return true;
			}
		}

		if (job.keep) {
			return false;
		}

		throw new IllegalOperationError("The SQLiteConnection is not open.");
	}

	/**
		`job`, queued on `queue` as its worker made its last pass, taken back
		out when that pass may have missed it: answers whether it was. Before
		the pass is over (`ended`) it is still to come and finds the job.
		After, whatever is left joined the queue too late, and whoever queued
		it takes it back here in turn: what is not `job` is put back for them.
		Taken only once a worker has stopped, so nothing that runs the
		connection's work pays for it.
	**/
	@:noCompletion private static function __takeBack(queue:SQLiteQueue, job:SQLiteJob):Bool {
		queue.ending.acquire();

		if (!queue.ended) {
			queue.ending.release();
			return false;
		}

		var found:Bool = false;
		var others:Array<SQLiteJob> = [];
		var left:SQLiteJob = queue.jobs.pop(false);

		while (left != null) {
			if (left == job) {
				found = true;
			} else {
				others.push(left);
			}

			left = queue.jobs.pop(false);
		}

		for (other in others) {
			queue.jobs.add(other);
		}

		queue.ending.release();
		return found;
	}
	#end

	/**
		On the worker, for a job a `cancel()` may have overtaken -- the count of
		them has moved on since it was queued: `JOB_CANCELLED` when the
		connection's `cancel()` was called after it was queued, so it is
		dropped and told so; `JOB_WITHDRAWN` when its statement's was, so it is
		dropped unheard; and otherwise `JOB_RUNS`. Read after the run is
		published, and so after what any `cancel()` it has not seen changed.
	**/
	@:noCompletion private function __verdict(job:SQLiteJob):Int {
		if (job.epoch < __cancelEpoch) {
			return JOB_CANCELLED;
		}

		var statement:Null<SQLiteStatement> = job.statement;

		if (statement != null && statement.__cancels != job.statementEpoch) {
			return JOB_WITHDRAWN;
		}

		return JOB_RUNS;
	}

	/**
		Counts a `cancel()`, after what it changed and before it looks for the
		run under way: an atomic add on cpp, which the worker reads after
		publishing a run, so that one of the two always sees the other.
	**/
	@:noCompletion private inline function __countCancel():Void {
		#if cpp
		untyped __cpp__("_hx_atomic_add(&{0}, 1)", __cancelGen);
		#else
		__cancelGen++;
		#end
	}

	/**
		On an asynchronous connection on cpp: stops the run under way --
		`statement`'s last run, if that is the one, or whatever is under way
		for null -- and never another. SQLite is interrupted, which stops even
		a single step that runs long, such as counting a whole table; and the
		progress handler is asked to stop the same run within a thousand
		steps, which it does where the interrupt lands as the run starts and
		SQLite clears it. The worker starts no run while this is under way, so
		the interrupt lands in the run it was meant for or before the next one
		starts -- where SQLite clears it, unless the run it was meant for left
		its statement part way through its rows: what reads them next is
		stopped instead. Nothing to do anywhere else: off cpp nothing stops
		work under way.
	**/
	@:noCompletion private function __stopRun(statement:Null<SQLiteStatement>):Void {
		#if cpp
		var runs:cpp.Pointer<cpp.Void> = __sqlRuns;

		if (runs == null) {
			return;
		}

		var now:Int = NativeSQLiteConnection.beginStop(runs);

		// The statement's run number read after the run under way: the worker
		// writes it before publishing the run.
		if (now != 0 && (statement == null || now == statement.__runId)) {
			NativeSQLiteConnection.stop(runs, now);
			__interrupt();
		}

		NativeSQLiteConnection.endStop(runs);
		#end
	}

	#if cpp
	/**
		The worker, about to start a run while a `cancel()` is stopping one
		(`__stopRun`): waits for it to finish, letting the collector stop this
		thread between tries, and yielding after a while in case the thread
		cancelling is not running. A cancel() takes a few microseconds.
	**/
	@:noCompletion private function __awaitStop(runs:cpp.Pointer<cpp.Void>):Void {
		var tries:Int = 0;

		while (NativeSQLiteConnection.stopping(runs)) {
			cpp.vm.Gc.safePoint();

			if (++tries >= 64) {
				tries = 0;
				crossbyte._internal.system.Sleep.sleep(0);
			}
		}
	}
	#end

	/** Frees the record of the runs, once the connection has closed. **/
	@:noCompletion private inline function __freeRuns():Void {
		#if cpp
		var runs:cpp.Pointer<cpp.Void> = __sqlRuns;

		if (runs != null) {
			__sqlRuns = null;
			NativeSQLiteConnection.freeRuns(runs);
		}
		#end
	}

	/**
		On the thread about to run a statement: reads what another statement
		left unread into its own hands first, as the statement's request would
		-- outside the statement's run, so that its `cancel()` cannot stop
		that other statement's rows.
	**/
	@:noCompletion private inline function __settle():Void {
		#if cpp
		var native:NativeSQLiteConnection = __native;

		if (native != null) {
			native.settle();
		}
		#end
	}

	/**
		`statement.cancel()`'s part here, on an asynchronous connection: moves
		its cancel count on, so that the work asked of it before is dropped,
		and stops its run if that is the one under way -- only then, so no
		other statement's work is stopped.
	**/
	@:noCompletion private function __cancelStatement(statement:SQLiteStatement):Void {
		statement.__cancels++;
		__countCancel();
		__stopRun(statement);
	}

	/**
		A cancelled statement's part on an asynchronous connection: the
		worker lets go of the rows it left unread, after what it is running
		now. Kept by a connection's `cancel()`: it costs nothing to run.
	**/
	@:noCompletion private function __dropPage():Void {
		__addToQueue(() -> {
			if (__pagedStatement != null) {
				__dropCancelledPage();
			}
		}, SQLEvent.CANCEL, true);
	}

	/**
		On the worker: lets go of the result of the statement left with rows
		unread, when its `cancel()` has been called since -- finalized, so
		the read it holds ends now and its rows are never read.
	**/
	@:noCompletion private function __dropCancelledPage():Void {
		var paged:SQLiteStatement = __pagedStatement;

		// The count is moved on by the thread that called cancel(), and read
		// plainly: the job __dropPage() queues behind the cancel() is taken up
		// after it, through the queue's lock, and sees it.
		if (paged.__cancels != paged.__resultEpoch) {
			__pagedStatement = null;
			__letGo(paged.__resultSet);
			paged.__resultSet = null;
		}
	}

	/**
		On the thread running the connection's work: ends `result` when it is
		the statement SQLite is part way through -- finalized, its read
		ended, its rows unread -- rather than leaving it for the next request
		to read to its end first.
	**/
	@:noCompletion private function __letGo(result:ResultSet):Void {
		#if cpp
		var native:NativeSQLiteConnection = __native;

		if (result != null && native != null) {
			native.discard(result);
		}
		#end
	}

	private function __createConnection(path:String):Void {
		try {
			#if cpp
			// The progress handler its cancel()s stop work with reads the
			// asynchronous connection's record of its runs, and a
			// synchronous one's own record of its requests.
			__native = NativeSQLiteConnection.open(path, __async ? __sqlRuns : null);
			__connection = __native;
			#else
			__connection = Sqlite.open(path);
			#end
		} catch (e:Dynamic) {
			throw new IOError(Std.string(e));
		}
	}

	private function get_autoCompact():Bool {
		return __now("autoCompact", function():Bool {
			var result:ResultSet = __connection.request("PRAGMA auto_vacuum;");
			// FULL only. An INCREMENTAL database -- what autoCompact made
			// before -- keeps its free pages until PRAGMA incremental_vacuum
			// runs, so it does not compact by itself and is not reported as
			// doing so.
			return result.hasNext() && __wholeNumber(Reflect.field(result.next(), "auto_vacuum")) == 1;
		});
	}

	private function get_pageSize():UInt {
		return __now("pageSize", function():UInt {
			var result:ResultSet = __connection.request("PRAGMA page_size;");

			if (result.hasNext()) {
				var pageSize:UInt = result.next().page_size;
				return pageSize;
			}

			return 0;
		});
	}

	private function get_cacheSize():Int {
		return __now("cacheSize", function():Int {
			var result:ResultSet = __connection.request("PRAGMA cache_size;");
			return result.hasNext() ? Std.int(__wholeNumber(Reflect.field(result.next(), "cache_size"))) : 0;
		});
	}

	private function set_cacheSize(value:Int):Int {
		__now("cacheSize", () -> __setCacheSize(value));
		return value;
	}

	/** `PRAGMA cache_size`, on whichever thread runs the connection's work. **/
	@:noCompletion private function __setCacheSize(value:Int):Bool {
		__connection.request('PRAGMA cache_size = $value;');
		return true;
	}

	private function get_connected():Bool {
		if (__async) {
			return __opened && __ready;
		}

		if (__connection == null) {
			return false;
		}

		try {
			__connection.request("SELECT 1;");
			return true;
		} catch (e:Dynamic) {
			return false;
		}
	}

	private function get_inTransaction():Bool {
		if (!__async) {
			return __transactionOpen();
		}

		if (!__opened) {
			return false;
		}

		try {
			return __now("inTransaction", __transactionOpen);
		} catch (_:IllegalOperationError) {
			// Closed before the worker reached the call: nothing is open.
			return false;
		}
	}

	/** Whether a transaction is open, asked of SQLite where the target can. **/
	@:noCompletion private function __transactionOpen():Bool {
		#if cpp
		if (__native != null) {
			try {
				return !__native.autocommit;
			} catch (_:Dynamic) {
				// Closed: no transaction can be open on it.
				return false;
			}
		}
		#end

		return __inTransaction;
	}

	private function get_lastInsertRowID():Float {
		return __now("lastInsertRowID", __lastRowId);
	}

	/**
		The rowid of the last insert, whole. SQLite's are 64-bit, and
		`sys.db.Connection.lastInsertId` answers an Int: hxcpp's stops at
		2^31 - 1 and the other drivers wrap, so a Snowflake id or a
		millisecond timestamp used as a key read back as something else.
		Below that it is exact and nothing more is asked; at or past it, or
		negative, SQLite is asked in SQL, whose integer column every driver
		returns whole.
	**/
	@:noCompletion private function __lastRowId():Float {
		var connection:Connection = __live();
		var id:Int = connection.lastInsertId();
		if (id >= 0 && id < 0x7FFFFFFF) {
			return id;
		}
		var rows:ResultSet = connection.request("SELECT last_insert_rowid() AS id;");
		if (rows == null || !rows.hasNext()) {
			return id;
		}
		return __wholeNumber(Reflect.field(rows.next(), "id"));
	}

	/**
		An integer column as a Float, exact to 2^53: an Int, an Int64 --
		hxcpp's for a value past 32 bits -- a Float, or text.
	**/
	@:noCompletion private static function __wholeNumber(value:Dynamic):Float {
		if (value == null) {
			return 0;
		}
		if (Int64.isInt64(value)) {
			var wide:Int64 = value;
			var low:Float = wide.low < 0 ? wide.low + 4294967296.0 : wide.low;
			return wide.high * 4294967296.0 + low;
		}
		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			return value;
		}
		var parsed:Float = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? 0 : parsed;
	}

	/** `pages` of `pageSize` bytes, in bytes: multiplied as a Float, never in 32 bits. **/
	@:noCompletion private static inline function __bytesOf(pageSize:Float, pages:Float):Int64 {
		return Int64.fromFloat(pageSize * pages);
	}

	private function get_totalChanges():Float {
		return __now("totalChanges", function():Float {
			var result:ResultSet = __connection.request("SELECT total_changes() AS total_changes;");
			return (result != null && result.hasNext()) ? __wholeNumber(Reflect.field(result.next(), "total_changes")) : 0;
		});
	}

	private function __dispatchSQLEvent(type:String):Void {
		__dispatchEvent(new SQLEvent(type));
	}

	private function __getTables():Array<String> {
		return __now("tableList", function():Array<String> {
			var result:ResultSet = __connection.request("SELECT name AS `table` FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';");
			var out:Array<String> = [];

			while (result.hasNext()) {
				out.push(Std.string(Reflect.field(result.next(), "table")));
			}

			return out;
		});
	}

	/**
		`PRAGMA body`, through `__now`. It took the connection's mutex on an
		asynchronous connection, which the worker never took, and ran on the
		calling thread.
	**/
	private function __pragma(body:String):ResultSet {
		return __now("pragma", () -> __rows(__connection.request('PRAGMA ' + body + ';')));
	}

	private inline function __pragmaFirstRow(body:String):Dynamic {
		var result:ResultSet = __pragma(body);
		var ret = null;

		if (result.hasNext()) {
			ret = result.next();
		}

		return ret;
	}

	private function get_journalMode():JournalMode {
		var row:Dynamic = __pragmaFirstRow('journal_mode');

		return row != null ? JournalMode.fromString(Std.string(Reflect.field(row, "journal_mode"))) : JournalMode.DELETE;
	}

	private function set_journalMode(value:JournalMode):JournalMode {
		var row:Dynamic = __pragmaFirstRow('journal_mode=' + value);

		return row != null ? JournalMode.fromString(Std.string(Reflect.field(row, "journal_mode"))) : value;
	}

	private function get_synchronous():SynchronousMode {
		var row:Dynamic = __pragmaFirstRow('synchronous');

		return row != null ? Std.parseInt(Std.string(Reflect.field(row, "synchronous"))) : SynchronousMode.NORMAL;
	}

	private function set_synchronous(value:SynchronousMode):SynchronousMode {
		__pragma('synchronous=' + value);

		return value;
	}

	private function get_foreignKeys():Bool {
		var row:Dynamic = __pragmaFirstRow('foreign_keys');

		return row != null && Std.parseInt(Std.string(Reflect.field(row, "foreign_keys"))) == 1;
	}

	private function set_foreignKeys(value:Bool):Bool {
		__pragma('foreign_keys=' + (value ? 1 : 0));

		return value;
	}

	private function get_walAutoCheckpoint():Int {
		var row:Dynamic = __pragmaFirstRow('wal_autocheckpoint');

		return row != null ? Std.parseInt(Std.string(Reflect.field(row, "wal_autocheckpoint"))) : 0;
	}

	private function set_walAutoCheckpoint(value:Int):Int {
		__pragma('wal_autocheckpoint=' + value);

		return value;
	}

	private function get_busyTimeout():Int {
		var row:Dynamic = __pragmaFirstRow("busy_timeout");

		if (row == null) {
			return 0;
		}

		var value = Reflect.field(row, "busy_timeout");
		if (value == null) {
			value = Reflect.field(row, "timeout");
		}

		var parsed = value != null ? Std.parseInt(Std.string(value)) : null;
		return parsed != null ? parsed : 0;
	}

	private function set_busyTimeout(v:Int):Int {
		__pragma("busy_timeout=" + v);

		return v;
	}

	private function get_mmapSize():Int64 {
		var row:Dynamic = __pragmaFirstRow("mmap_size");

		return row != null ? Int64.parseString(Std.string(Reflect.field(row, "mmap_size"))) : Int64.make(0, 0);
	}

	private function set_mmapSize(v:Int64):Int64 {
		__pragma("mmap_size=" + v);

		return v;
	}

	private function get_tempStore():TempStoreMode {
		var row:Dynamic = __pragmaFirstRow("temp_store");

		if (row != null) {
			var n:Null<Int> = Std.parseInt(Std.string(Reflect.field(row, "temp_store")));
			return n;
		}

		return TempStoreMode.DEFAULT;
	}

	private function set_tempStore(v:TempStoreMode):TempStoreMode {
		__pragma("temp_store=" + v);

		return v;
	}

	private function get_secureDelete():Bool {
		var row:Dynamic = __pragmaFirstRow("secure_delete");

		return row != null && Std.parseInt(Std.string(Reflect.field(row, "secure_delete"))) == 1;
	}

	private function set_secureDelete(v:Bool):Bool {
		__pragma("secure_delete=" + (v ? 1 : 0));

		return v;
	}

	private function get_readUncommitted():Bool {
		var row:Dynamic = __pragmaFirstRow("read_uncommitted");

		return row != null && Std.parseInt(Std.string(Reflect.field(row, "read_uncommitted"))) == 1;
	}

	private function set_readUncommitted(v:Bool):Bool {
		__pragma("read_uncommitted=" + (v ? 1 : 0));

		return v;
	}
}

/*
	What the connection's own reads answer. Classes, where they were
	anonymous structures: each field is read directly rather than looked up
	by name, and an object literal with the same fields still makes one.
*/

/** What a WAL checkpoint did (`walCheckpoint`): SQLite's three counts. **/
@:structInit
final class WalCheckpointResult {
	public final busy:Int;
	public final log:Int;
	public final checkpointed:Int;
}

/** A row that breaks a foreign key (`foreignKeyCheck`). **/
@:structInit
final class FKViolation {
	public final table:String;

	/** Exact to 2^53; null for a row of a `WITHOUT ROWID` table, which has none. **/
	public final rowid:Null<Float>;

	public final parent:String;
	public final fkid:Int;
}

/** What `SQLiteConnection.loadSchema` read: a database's tables, views, indices and triggers. **/
@:structInit
final class SQLSchemaResult {
	public final tables:Array<SQLTableSchema>;
	public final views:Array<SQLViewSchema>;
	public final indices:Array<SQLIndexSchema>;
	public final triggers:Array<SQLTriggerSchema>;
}

@:structInit
final class SQLTableSchema {
	public final name:String;

	/** The `CREATE TABLE` statement, as SQLite keeps it. **/
	public final sql:Null<String>;

	public final columns:Array<SQLColumnSchema>;
}

@:structInit
final class SQLColumnSchema {
	public final name:String;

	/** The declared type, as written; SQLite's affinity follows from it. **/
	public final dataType:String;

	public final allowNull:Bool;
	public final primaryKey:Bool;

	/** The default, as the SQL text of its expression, or null for none. **/
	public final defaultValue:Null<String>;
}

@:structInit
final class SQLViewSchema {
	public final name:String;
	public final sql:Null<String>;
}

@:structInit
final class SQLIndexSchema {
	public final name:String;
	public final table:String;

	/** Null for an index SQLite made itself, for a UNIQUE or PRIMARY KEY constraint. **/
	public final sql:Null<String>;
}

@:structInit
final class SQLTriggerSchema {
	public final name:String;
	public final table:String;
	public final sql:Null<String>;
}

/** The database's size (`stats`). **/
@:structInit
final class DBStats {
	public final pageSize:Int;

	// Floats, exact to 2^53: SQLite counts pages in 32 bits unsigned.
	public final pageCount:Float;
	public final freeListCount:Float;
	public final dbSizeBytes:Int64;
	public final freeBytes:Int64;
}
#end
