package crossbyte.db.sqlite;

import haxe.Int64;

/**
 * SQLite-specific connection with convenience properties and helpers
 * around common PRAGMAs and maintenance operations.
 *
 * Extends {@link crossbyte.db.SQLConnection}.
 */
class SQLiteConnection extends SQLConnection {
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

	/**
	 * Create a new SQLiteConnection.
	 *
	 * Most configuration is done via the public properties (e.g., {@link #journalMode}).
	 */
	public function new() {
		super();
	}

	/**
	 * Run a WAL checkpoint and return its result counters.
	 *
	 * Wraps `PRAGMA wal_checkpoint(<mode>)`.
	 *
	 * @param mode The checkpoint mode (default {@link CheckpointMode#PASSIVE}).
	 * @return A {@link WalCheckpointResult} with `busy`, `log`, and `checkpointed` frame counts.
	 * @see #walTruncate
	 */
	public function walCheckpoint(mode:CheckpointMode = CheckpointMode.PASSIVE):WalCheckpointResult {
		final rs = __pragma('wal_checkpoint(' + mode + ')');
		if (rs != null && rs.hasNext()) {
			final row = rs.next();
			return {
				busy: Std.parseInt(Std.string(Reflect.field(row, "busy"))),
				log: Std.parseInt(Std.string(Reflect.field(row, "log"))),
				checkpointed: Std.parseInt(Std.string(Reflect.field(row, "checkpointed")))
			};
		}
		return {busy: 0, log: 0, checkpointed: 0};
	}

	/**
	 * Convenience for `walCheckpoint(TRUNCATE)`, attempting to shrink the WAL file.
	 *
	 * @return A {@link WalCheckpointResult} with `busy`, `log`, and `checkpointed` frame counts.
	 * @see #walCheckpoint
	 */
	public inline function walTruncate():WalCheckpointResult
		return walCheckpoint(CheckpointMode.TRUNCATE);

	/**
	 * Run a full integrity check on the database.
	 *
	 * Wraps `PRAGMA integrity_check`; returns `"ok"` if no issues are found,
	 * otherwise returns the first reported issue line.
	 *
	 * @return The integrity result string.
	 */
	public function integrityCheck():String {
		final rs = __pragma("integrity_check");
		return (rs != null && rs.hasNext()) ? Std.string(Reflect.field(rs.next(), "integrity_check")) : "";
	}

	/**
	 * Report rows that violate foreign-key constraints.
	 *
	 * Wraps `PRAGMA foreign_key_check`.
	 *
	 * @return An array of {@link FKViolation} entries; empty when no violations exist.
	 */
	public function foreignKeyCheck():Array<FKViolation> {
		final rs = __pragma("foreign_key_check");
		var out:Array<FKViolation> = [];
		if (rs != null) {
			while (rs.hasNext()) {
				final row = rs.next();
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

	/**
	 * List compile-time options built into the linked SQLite library.
	 *
	 * Wraps `PRAGMA compile_options`.
	 *
	 * @return Array of option strings (e.g., `SQLITE_ENABLE_FTS5`).
	 */
	public function compileOptions():Array<String> {
		final rs = __pragma("compile_options");
		var out:Array<String> = [];
		if (rs != null)
			while (rs.hasNext())
				out.push(Std.string(Reflect.field(rs.next(), "compile_options")));
		return out;
	}

	/**
	 * List supported PRAGMA names in the current SQLite build.
	 *
	 * Wraps `PRAGMA pragma_list`.
	 *
	 * @return Array of PRAGMA names.
	 */
	public function pragmaList():Array<String> {
		final rs = __pragma("pragma_list");
		var out:Array<String> = [];
		if (rs != null)
			while (rs.hasNext())
				out.push(Std.string(Reflect.field(rs.next(), "name")));
		return out;
	}

	/**
	 * Quick database size/fragmentation snapshot.
	 *
	 * Internally reads `page_size`, `page_count`, and `freelist_count`
	 * to compute allocated size and free space.
	 *
	 * @return {@link DBStats} including page size/count, freelist count, and byte estimates.
	 */
	public function stats():DBStats {
		final pageSizeRow = __pragmaFirstRow("page_size");
		final pageCountRow = __pragmaFirstRow("page_count");
		final freeListRow = __pragmaFirstRow("freelist_count");

		final pageSize = pageSizeRow != null ? Std.parseInt(Std.string(Reflect.field(pageSizeRow, "page_size"))) : 0;
		final pageCount = pageCountRow != null ? Std.parseInt(Std.string(Reflect.field(pageCountRow, "page_count"))) : 0;
		final freeList = freeListRow != null ? Std.parseInt(Std.string(Reflect.field(freeListRow, "freelist_count"))) : 0;

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
		return row != null ? SynchronousMode.fromInt(Std.parseInt(Std.string(Reflect.field(row, "synchronous")))) : SynchronousMode.NORMAL;
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
		final row = __pragmaFirstRow("busy_timeout");
		return row != null ? Std.parseInt(Std.string(Reflect.field(row, "busy_timeout"))) : 0;
	}

	private function set_busyTimeout(v:Int):Int {
		__pragma("busy_timeout=" + v);
		return v;
	}

	private function get_mmapSize():Int64 {
		final row = __pragmaFirstRow("mmap_size");
		return row != null ? Int64.parseString(Std.string(Reflect.field(row, "mmap_size"))) : Int64.make(0, 0);
	}

	private function set_mmapSize(v:Int64):Int64 {
		__pragma("mmap_size=" + v);
		return v;
	}

	private function get_tempStore():TempStoreMode {
		final row = __pragmaFirstRow("temp_store");
		if (row != null) {
			final n = Std.parseInt(Std.string(Reflect.field(row, "temp_store")));
			return TempStoreMode.fromInt(n);
		}
		return TempStoreMode.DEFAULT;
	}

	private function set_tempStore(v:TempStoreMode):TempStoreMode {
		__pragma("temp_store=" + v);
		return v;
	}

	private function get_secureDelete():Bool {
		final row = __pragmaFirstRow("secure_delete");
		return row != null && Std.parseInt(Std.string(Reflect.field(row, "secure_delete"))) == 1;
	}

	private function set_secureDelete(v:Bool):Bool {
		__pragma("secure_delete=" + (v ? 1 : 0));
		return v;
	}

	private function get_readUncommitted():Bool {
		final row = __pragmaFirstRow("read_uncommitted");
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
