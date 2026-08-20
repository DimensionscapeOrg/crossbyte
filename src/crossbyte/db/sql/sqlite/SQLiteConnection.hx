package crossbyte.db.sql.sqlite;

import sys.db.Sqlite;
import crossbyte.Function;
import crossbyte.Object;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.IOError;
import crossbyte.errors.SQLError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.io.File;
import crossbyte.sys.Worker;
import sys.db.Connection;
import sys.db.ResultSet;
#if !php
import sys.thread.Deque;
import sys.thread.Mutex;
#end
import haxe.Int64;

/**
 * SQLite-specific connection with convenience properties and helpers
 * around common PRAGMAs and maintenance operations.
 */
@:access(crossbyte.db.sql.sqlite.SQLiteStatement)
class SQLiteConnection extends EventDispatcher {
	public static inline var isSupported:Bool = #if cpp true; #else false; #end

	@:noCompletion private static inline var DEFAULT_CACHE_SIZE:UInt = 2000;

	public var autoCompact(get, null):Bool;
	public var cacheSize(get, set):UInt;
	// public var columnNameStyle(get, set):String;
	public var connected(get, null):Bool;
	public var inTransaction(get, null):Bool;
	public var lastInsertRowID(get, null):Int;
	public var pageSize(get, null):UInt;
	public var totalChanges(get, null):Int;

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
	@:noCompletion private var __savepoints:Array<String> = [];
	@:noCompletion private var __savepointSeq:Int = 0;
	@:noCompletion private var __inTransaction:Bool = false;
	@:noCompletion private var __reference:String;
	@:noCompletion private var __initAutoCompact:Bool;
	@:noCompletion private var __initPageSize:UInt;

	@:noCompletion private var __openMode:SQLiteMode;
	@:noCompletion private var __connection:Connection;
	@:noCompletion private var __sqlWorker:Worker;

	// Gated the same way the imports above are, not on cpp alone. The queue is
	// written by whichever thread calls the connection and read by the worker,
	// so it needs a structure built for that -- and neko, hl, java and jvm all
	// have real threads and both of these types. They were getting a plain
	// Array instead, pushed and popped with no lock at all.
	#if !php
	@:noCompletion private var __sqlQueue:Deque<Function>;
	@:noCompletion private var __sqlMutex:Mutex;
	#end

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

	public function foreignKeyCheck():Array<FKViolation> {
		var rs:ResultSet = __pragma("foreign_key_check");
		var out:Array<FKViolation> = [];

		if (rs != null) {
			while (rs.hasNext()) {
				var row:Dynamic = rs.next();

				out.push({
					table: Std.string(Reflect.field(row, "table")),
					rowid: Std.parseInt(Std.string(Reflect.field(row, "rowid"))),
					parent: Std.string(Reflect.field(row, "parent")),
					fkid: Std.parseInt(Std.string(Reflect.field(row, "fkid")))
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

		var pageSize:Null<Int> = pageSizeRow != null ? Std.parseInt(Std.string(Reflect.field(pageSizeRow, "page_size"))) : 0;
		var pageCount:Null<Int> = pageCountRow != null ? Std.parseInt(Std.string(Reflect.field(pageCountRow, "page_count"))) : 0;
		var freeList:Null<Int> = freeListRow != null ? Std.parseInt(Std.string(Reflect.field(freeListRow, "freelist_count"))) : 0;

		return {
			pageSize: pageSize,
			pageCount: pageCount,
			freeListCount: freeList,
			dbSizeBytes: Int64.make(0, pageSize * pageCount),
			freeBytes: Int64.make(0, pageSize * freeList)
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

	public function analyze():Void {
		if (__async) {
			__addToQueue(__analyzeAsync);
		} else {
			__connection.request("ANALYZE;");
			__dispatchSQLEvent(SQLEvent.ANALYZE);
		}
	}

	public function begin(options:String = null):Void {
		if (__async) {
			__addToQueue(__beginAsync(options));
		} else {
			switch (options) {
				case "IMMEDIATE":
					__connection.request("BEGIN IMMEDIATE;");
				case "EXCLUSIVE":
					__connection.request("BEGIN EXCLUSIVE;");
				default:
					__connection.startTransaction();
			}
			__inTransaction = true;
			__dispatchSQLEvent(SQLEvent.BEGIN);
		}
	}

	public function deanalyze():Void {
		if (__async) {
			__addToQueue(deanalyzeAsync);
		} else {
			__connection.close();
			open(__reference, __openMode, __initAutoCompact, __initPageSize);
		}

		__dispatchSQLEvent(SQLEvent.DEANALYZE);
	}

	public function cancel():Void {
		if (__async) {
			__sqlWorker.cancel();

			#if !php
			// Drained rather than replaced. The worker is parked inside
			// pop(true) holding a reference to this queue, so swapping in a
			// fresh one left it waiting on a queue nobody would ever add to
			// again -- a thread parked for the life of the process, while
			// every later job went to a queue with no consumer and silently
			// never ran. Draining keeps the one the worker is waiting on, and
			// the null wakes it so it can see it has been cancelled.
			__sqlMutex.acquire();
			while (__sqlQueue.pop(false) != null) {}
			__sqlMutex.release();
			__sqlQueue.add(null);
			#end
		}

		__dispatchSQLEvent(SQLEvent.CANCEL);
	}

	public function close():Void {
		if (__async) {
			__addToQueue(function() {
				var event:Event;
				try {
					__connection.close();
					event = new SQLEvent(SQLEvent.CLOSE);
				} catch (e:Dynamic) {
					event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.CLOSE, "Execution failed"));
				}
				__sqlWorker.sendProgress(event);
				__sqlWorker.cancel();
			});
		} else {
			__connection.close();
			__dispatchSQLEvent(SQLEvent.CLOSE);
		}
	}

	public inline function request(sql:String):ResultSet {
		return __connection.request(sql);
	}

	public inline function escape(value:String):String {
		return __connection.escape(value);
	}

	public inline function quote(value:String):String {
		return __connection.quote(value);
	}

	public function commit():Void {
		if (__async) {
			__addToQueue(__commitAsync);
		} else {
			__connection.commit();
			__inTransaction = false;
			__savepoints = [];
			__dispatchSQLEvent(SQLEvent.COMMIT);
		}
	}

	public function compact():Void {
		if (__async) {
			__addToQueue(__compactAsync);
		} else {
			__connection.request("VACUUM;");
			__dispatchSQLEvent(SQLEvent.COMPACT);
		}
	}

	public function open(reference:Object = null, openMode:SQLiteMode = CREATE, autoCompact:Bool = false, pageSize:Int = 1024):Void {
		__async = false;
		__open(reference, openMode, autoCompact, pageSize);

		__dispatchSQLEvent(SQLEvent.OPEN);
	}

	public function openAsync(reference:Object = null, openMode:SQLiteMode = CREATE, autoCompact:Bool = false, pageSize:Int = 1024):Void {
		__async = true;
		__initSQLWorker();
		__addToQueue(__openAsync(reference, openMode, autoCompact, pageSize));
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

		if (__async) {
			__addToQueue(__releaseSavePointAsync(resolved));
		} else {
			__connection.request('RELEASE $resolved;');
			__dispatchSQLEvent(SQLEvent.RELEASE_SAVEPOINT);
		}
	}

	public function rollback():Void {
		if (__async) {
			__addToQueue(__rollbackAsync);
		} else {
			__connection.rollback();
			__inTransaction = false;
			__savepoints = [];
			__dispatchSQLEvent(SQLEvent.ROLLBACK);
		}
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

		if (__async) {
			__addToQueue(rollbackToSavepointAsync(resolved));
		} else {
			__connection.request('ROLLBACK TO $resolved;');
			__dispatchSQLEvent(SQLEvent.ROLLBACK_TO_SAVEPOINT);
		}
	}

	/**
		Creates a savepoint and returns its name, so one created without a name
		can still be released or rolled back to. It returned nothing, which
		left a generated name known only to the statement that used it.
	**/
	public function setSavepoint(name:String = null):String {
		var resolved:String = __sanitizeSavePoint(name);
		__savepoints.push(resolved);

		if (__async) {
			__addToQueue(__setSavepointAsync(resolved));
		} else {
			__connection.request('SAVEPOINT $resolved;');
			__dispatchSQLEvent(SQLEvent.SET_SAVEPOINT);
		}

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

	private function __setSavepointAsync(name:String):Function {
		return function() {
			var event:Event;

			try {
				__connection.request('SAVEPOINT $name;');
				event = new SQLEvent(SQLEvent.SET_SAVEPOINT);
			} catch (e:Dynamic) {
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.SET_SAVEPOINT, "Execution failed"));
			}
			__sqlWorker.sendProgress(event);
		}
	}

	private function rollbackToSavepointAsync(name:String):Function {
		return function() {
			var event:Event;

			try {
				__connection.request('ROLLBACK TO $name;');
				event = new SQLEvent(SQLEvent.ROLLBACK_TO_SAVEPOINT);
			} catch (e:Dynamic) {
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.ROLLBACK_TO_SAVEPOINT, "Execution failed"));
			}
			__sqlWorker.sendProgress(event);
		}
	}

	private function __rollbackAsync():Void {
		var event:Event;

		try {
			__connection.rollback();
			__inTransaction = false;
			__savepoints = [];
			event = new SQLEvent(SQLEvent.ROLLBACK);
		} catch (e:Dynamic) {
			event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.ROLLBACK, "Execution failed"));
		}
		__sqlWorker.sendProgress(event);
	}

	private function __releaseSavePointAsync(name:String):Function {
		return function() {
			var event:Event;

			try {
				__connection.request('RELEASE $name;');
				event = new SQLEvent(SQLEvent.RELEASE_SAVEPOINT);
			} catch (e:Dynamic) {
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RELEASE_SAVEPOINT, "Execution failed"));
			}
			__sqlWorker.sendProgress(event);
		}
	}

	private function __openAsync(reference:Object = null, openMode:SQLiteMode = CREATE, autoCompact:Bool = false, pageSize:Int = 1024):Function {
		return function() {
			var event:Event;

			try {
				__open(reference, openMode, autoCompact, pageSize);
				event = new SQLEvent(SQLEvent.OPEN);
			} catch (e:Dynamic) {
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.OPEN, "Execution failed"));
			}
			__sqlWorker.sendProgress(event);
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
					throw new ArgumentError(e);
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
		}

		if (__openMode == CREATE) {
			__connection.request('PRAGMA page_size = $pageSize;');

			if (autoCompact) {
				__connection.request("PRAGMA auto_vacuum = 2;");
			}

			if (__reference != null && __reference != ":memory:" && autoCompact) {
				__connection.request("VACUUM;");
			}
		}

		cacheSize = DEFAULT_CACHE_SIZE;
	}

	private function __compactAsync():Void {
		var event:Event;

		try {
			__connection.request("VACUUM;");
			event = new SQLEvent(SQLEvent.COMPACT);
		} catch (e:Dynamic) {
			event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.COMPACT, "Execution failed"));
		}

		__sqlWorker.sendProgress(event);
	}

	private function __commitAsync():Void {
		var event:Event;

		try {
			__connection.commit();
			__inTransaction = false;
			__savepoints = [];
			event = new SQLEvent(SQLEvent.COMMIT);
		} catch (e:Dynamic) {
			event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.COMMIT, "Execution failed"));
		}

		__sqlWorker.sendProgress(event);
	}

	private function __closeAsync():Void {
		var event:Event;

		try {
			__connection.close();
			event = new SQLEvent(SQLEvent.CLOSE);
		} catch (e:Dynamic) {
			event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.CLOSE, "Execution failed"));
		}

		__sqlWorker.sendProgress(event);
	}

	private function deanalyzeAsync():Void {
		var event:Event;

		try {
			__connection.close();
			openAsync(__reference, __openMode, __initAutoCompact, __initPageSize);
			event = new SQLEvent(SQLEvent.DEANALYZE);
		} catch (e:Dynamic) {
			event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.DEANALYZE, "Execution failed"));
		}

		__sqlWorker.sendProgress(event);
	}

	private function __beginAsync(options:String):Function {
		return function() {
			var event:Event;

			try {
				__connection.startTransaction();
				__inTransaction = true;
				event = new SQLEvent(SQLEvent.BEGIN);
			} catch (e:Dynamic) {
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.BEGIN, e, "Execution failed"));
			}

			__sqlWorker.sendProgress(event);
		}
	}

	private function __analyzeAsync():Void {
		var event:Event;

		try {
			__connection.request("ANALYZE;");
			event = new SQLEvent(SQLEvent.ANALYZE);
		} catch (e:Dynamic) {
			event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.ANALYZE, e, "Execution failed"));
		}

		__sqlWorker.sendProgress(event);
	}

	private function __onSQLWorkerComplete(e:ThreadEvent):Void {}

	private function __onSQLWorkerError(e:ThreadEvent):Void {}

	private function __onSQLWorkerProgress(e:ThreadEvent):Void {
		if (Std.isOfType(e.message, SQLEvent)) {
			var evt:SQLEvent = e.message;
			__dispatchEvent(evt);
		} else {
			var obj:Object = e.message;

			var type:Int = obj.type;
			var statement:SQLiteStatement = obj.statement;
			var event:Event = obj.event;
			var prefetch:Int = obj.prefetch;
			statement.__prefetch = prefetch;

			if (type == 0) {
				var results:ResultSet = obj.results;

				statement.__resultSet = results;

				statement.__queueResult();
			} else {
				var executing:Bool = obj.executing;
				if (executing) {
					statement.__queueResult();
				}
			}

			statement.__dispatchEvent(event);
		}
	}

	private function __initSQLWorker():Void {
		#if !php
		__sqlMutex = new Mutex();
		__sqlQueue = new Deque();
		#end
		__sqlWorker = new Worker();
		__sqlWorker.addEventListener(ThreadEvent.COMPLETE, __onSQLWorkerComplete);
		__sqlWorker.addEventListener(ThreadEvent.ERROR, __onSQLWorkerError);
		__sqlWorker.addEventListener(ThreadEvent.PROGRESS, __onSQLWorkerProgress);
		__sqlWorker.doWork = __sqlWork;
		__sqlWorker.run();
	}

	private function __sqlWork(m:Dynamic):Void {
		while (!__sqlWorker.canceled) {
			#if !php
			// Blocks until there is work. The Array path this replaces spun:
			// an empty queue fell through to haxe.Timer.delay(fn, 0), which
			// schedules rather than waits, so an idle async connection burned
			// a core on every target that was not hl or neko.
			var job:Function = __sqlQueue.pop(true);

			if (job == null) {
				continue;
			}

			job();
			#end
		}
	}

	/**
		The one place a job is handed to the worker.

		Every caller routes through here rather than opening the queue itself,
		which is what makes the locking a single decision instead of eleven
		copies of one -- and eleven copies is how the non-cpp half came to have
		no locking at all.
	**/
	private function __addToQueue(job:Function):Void {
		#if !php
		__sqlMutex.acquire();
		__sqlQueue.add(job);
		__sqlMutex.release();
		#end
	}

	private function __createConnection(path:String):Void {
		try {
			__connection = Sqlite.open(path);
		} catch (e:Dynamic) {
			throw new IOError(e);
		}
	}

	private function get_autoCompact():Bool {
		var result:ResultSet;

		if (__async) {
			#if cpp
			__sqlMutex.acquire();
			result = __connection.request("PRAGMA auto_vacuum;");
			__sqlMutex.release();
			#else
			result = __connection.request("PRAGMA auto_vacuum;");
			#end
		} else {
			result = __connection.request("PRAGMA auto_vacuum;");
		}

		if (result.hasNext()) {
			var autoVacuum:Int = result.next().auto_vacuum;

			if (autoVacuum == 0) {
				return false;
			} else if (autoVacuum == 1) {
				return true;
			} else if (autoVacuum == 2) {
				return true;
			}
		}

		return false;
	}

	private function get_pageSize():UInt {
		var result:ResultSet = __connection.request("PRAGMA page_size;");

		if (result.hasNext()) {
			var pageSize:UInt = result.next().page_size;

			return pageSize;
		}

		return 0;
	}

	private function get_cacheSize():UInt {
		var result:ResultSet = __connection.request("PRAGMA cache_size;");

		if (result.hasNext()) {
			var cacheSize:UInt = result.next().cache_size;
			return cacheSize;
		}

		return 0;
	}

	private function set_cacheSize(value:UInt):UInt {
		__connection.request('PRAGMA cache_size = $value;');

		return value;
	}

	private function get_connected():Bool {
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
		return __inTransaction;
	}

	private function get_lastInsertRowID():Int {
		return __connection.lastInsertId();
	}

	private function get_totalChanges():Int {
		var result:ResultSet = __connection.request("SELECT total_changes() AS total_changes;");

		return (result != null && result.hasNext()) ? Std.parseInt(Std.string(Reflect.field(result.next(), "total_changes"))) : 0;
	}

	private function __dispatchSQLEvent(type:String):Void {
		__dispatchEvent(new SQLEvent(type));
	}

	private function __getTables():Array<String> {
		var result:ResultSet = __connection.request("SELECT name AS `table` FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';");
		var out:Array<String> = [];

		while (result.hasNext()) {
			out.push(Std.string(Reflect.field(result.next(), "table")));
		}

		return out;
	}

	private inline function __pragma(body:String):ResultSet {
		var ret:ResultSet = null;
		if (__async) {
			#if cpp
			__sqlMutex.acquire();
			ret = __connection.request('PRAGMA ' + body + ';');
			__sqlMutex.release();
			#else
			ret = __connection.request('PRAGMA ' + body + ';');
			#end
		} else {
			ret = __connection.request('PRAGMA ' + body + ';');
		}

		return ret;
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

typedef WalCheckpointResult = {
	var busy:Int;
	var log:Int;
	var checkpointed:Int;
}

typedef FKViolation = {
	var table:String;
	var rowid:Int;
	var parent:String;
	var fkid:Int;
}

typedef DBStats = {
	var pageSize:Int;
	var pageCount:Int;
	var freeListCount:Int;
	var dbSizeBytes:Int64;
	var freeBytes:Int64;
}
