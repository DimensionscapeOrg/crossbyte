package crossbyte.db.sql.sqlite._internal;

#if cpp
import sys.db.Connection;
import sys.db.ResultSet;

/**
 * A `sys.db.Connection` over the SQLite hxcpp bundles, as Haxe's
 * `sys.db.Sqlite` builds one, with the database handle kept in reach so the
 * driver can ask SQLite itself whether a transaction is open.
 *
 * `sqlite3_get_autocommit` answers from the connection's own state, so a
 * transaction begun or ended as SQL text -- `request("BEGIN")` -- or rolled
 * back by SQLite after an error is reflected, at no cost.
 *
 * It also keeps the `sqlite3` pointer itself, for `sqlite3_interrupt`, which
 * hxcpp's glue has no call for and keeps out of reach. SQLite hands every
 * connection it opens to each automatic extension registered with
 * `sqlite3_auto_extension`, on the thread opening it; the one registered
 * here notes it, and `open` takes it straight after the glue's own open
 * returns, on the same thread -- no change to hxcpp needed.
 *
 * Through the same pointer it registers a progress handler, which SQLite
 * calls every thousand steps of its virtual machine: it stops the statement
 * running when `stopRunning(true)` asks. `sqlite3_interrupt` alone is lost
 * when it lands as a statement starts -- SQLite clears it there when no
 * other statement is running -- and a statement's `cancel()` can land just
 * then, as its work is taken up.
 */
@:noCompletion
@:buildXml('<include name="${HXCPP}/src/hx/libs/sqlite/Build.xml"/>')
@:cppFileCode('
HXCPP_EXTERN_CLASS_ATTRIBUTES bool _hx_sqlite_get_autocommit(Dynamic handle);

#include <atomic>

// Calls of the SQLite C API that the glue above has no wrapper for,
// declared rather than included: sqlite3.h is on the include path of the
// hxcpp sqlite files only.
extern "C" {
	struct sqlite3;
	int sqlite3_auto_extension(void (*xEntryPoint)(void));
	void sqlite3_interrupt(struct sqlite3 *db);
	void sqlite3_progress_handler(struct sqlite3 *db, int steps, int (*handler)(void *), void *argument);
}

// The connection sqlite3_open made last on this thread, as SQLite reports it
// to every automatic extension. Per thread, so opens on several threads at
// once cannot take each other.
static thread_local struct sqlite3 *crossbyte_sqlite_opened = 0;

// Runs inside sqlite3_open, in the GC-free zone the glue opens it in: it
// touches nothing but the pointer.
static int crossbyte_sqlite_note_open(struct sqlite3 *db, char **error, const void *api) {
	crossbyte_sqlite_opened = db;
	return 0;
}

static void crossbyte_sqlite_watch_opens() {
	// SQLite registers an entry point once, however often it is asked.
	sqlite3_auto_extension((void (*)(void))crossbyte_sqlite_note_open);
}

static void *crossbyte_sqlite_take_opened() {
	struct sqlite3 *db = crossbyte_sqlite_opened;
	crossbyte_sqlite_opened = 0;
	return db;
}

static void crossbyte_sqlite_interrupt(void *db) {
	sqlite3_interrupt((struct sqlite3 *)db);
}

// Whether the statement running on a connection is to stop: what its
// progress handler answers SQLite, which then fails the statement with
// SQLITE_INTERRUPT, as sqlite3_interrupt does.
struct crossbyte_sqlite_stop {
	std::atomic<int> requested;
};

static int crossbyte_sqlite_progress(void *stop) {
	return ((crossbyte_sqlite_stop *)stop)->requested.load(std::memory_order_relaxed);
}

// Registering and removing the handler takes the mutex of the connection,
// which a statement stepping on another thread holds: in a GC-free zone, as
// the blocking calls of the glue are, touching nothing of the GC inside.
static void *crossbyte_sqlite_watch_progress(void *db) {
	crossbyte_sqlite_stop *stop = new crossbyte_sqlite_stop();
	stop->requested.store(0);
	// Every thousand steps: an atomic read each time, against the tens of
	// steps a row takes.
	hx::EnterGCFreeZone();
	sqlite3_progress_handler((struct sqlite3 *)db, 1000, crossbyte_sqlite_progress, stop);
	hx::ExitGCFreeZone();
	return stop;
}

static void crossbyte_sqlite_set_stop(void *stop, bool on) {
	((crossbyte_sqlite_stop *)stop)->requested.store(on ? 1 : 0);
}

// Before the connection closes: nothing calls the handler after this.
static void crossbyte_sqlite_unwatch_progress(void *db, void *stop) {
	hx::EnterGCFreeZone();
	sqlite3_progress_handler((struct sqlite3 *)db, 0, 0, 0);
	hx::ExitGCFreeZone();
	delete (crossbyte_sqlite_stop *)stop;
}
')
class NativeSQLiteConnection implements Connection {
	@:noCompletion private var __handle:Dynamic;

	// The sqlite3 pointer behind __handle, or null once closed. Guarded by
	// __dbLock: interrupt() may run on any thread, and must never reach a
	// connection close() has freed.
	@:noCompletion private var __db:cpp.Pointer<cpp.Void>;
	@:noCompletion private var __dbLock:sys.thread.Mutex;
	// What the progress handler reads, for stopRunning(); null once closed,
	// and guarded by __dbLock as __db is.
	@:noCompletion private var __stop:cpp.Pointer<cpp.Void>;

	public static function open(path:String):NativeSQLiteConnection {
		__watchOpens();
		// Cleared first, so what is taken below can only be this open's.
		__takeOpened();
		var connection:NativeSQLiteConnection = new NativeSQLiteConnection(__connect(path));
		connection.__db = __takeOpened();

		if (connection.__db != null) {
			connection.__stop = __watchProgress(connection.__db);
		}

		return connection;
	}

	public function new(handle:Dynamic) {
		__handle = handle;
		__dbLock = new sys.thread.Mutex();
	}

	/**
		Stops the statement running on this connection at its next step --
		it fails with "interrupted" -- from any thread. Does nothing when none
		is running, or once closed. A write interrupted inside a transaction
		takes the whole transaction back with it, as SQLite has it.
	**/
	public function interrupt():Void {
		__dbLock.acquire();

		if (__db != null) {
			__interruptDb(__db);
		}

		__dbLock.release();
	}

	/**
		Has SQLite stop the statement running on this connection, and any
		started on it, while `on` -- it fails with "interrupted" -- until
		called again with `false`. From any thread. Unlike `interrupt()` it is
		not lost when it lands as a statement starts.
	**/
	public function stopRunning(on:Bool):Void {
		__dbLock.acquire();

		if (__stop != null) {
			__setStop(__stop, on);
		}

		__dbLock.release();
	}

	/**
		Reads the rows the result still live has left into its own hands
		now, as the next request would first: so that they are read before
		whatever is about to run, and not as part of it.
	**/
	public function settle():Void {
		var previous:NativeSQLiteResultSet = __live;

		if (previous != null) {
			__live = null;
			previous.__keepRest();
		}
	}

	/** Whether no transaction is open. **/
	public var autocommit(get, never):Bool;

	/**
		Runs `s` and answers its result.

		hxcpp's glue keeps one live result per connection, and starts a
		request by finalizing the one before it: a statement read a page at a
		time while others ran on the connection -- a cursor whose rows are
		each written elsewhere -- lost every row after the page in hand, and
		its next page read as the empty last one. So the result still live
		reads the rest of its rows into its own hands first, and gives them
		as asked; only a result interleaved that way pays for it.
	**/
	public function request(s:String):ResultSet {
		settle();
		var result:NativeSQLiteResultSet = new NativeSQLiteResultSet(__request(__handle, s));

		if (!result.__exhausted) {
			__live = result;
		}

		return result;
	}

	// The result of the last request while it may still have rows to give.
	@:noCompletion private var __live:NativeSQLiteResultSet;

	/**
		Ends `result`, when it is the statement still part way through its
		rows: finalized now, its read ended, and the rows it had left never
		read -- where the next request would first have read them all into
		its hands. A cancelled statement's. Reading it again finds no rows.
	**/
	public function discard(result:ResultSet):Void {
		var live:NativeSQLiteResultSet = __live;

		if (result == null || result != live) {
			return;
		}

		__live = null;

		if (live.__exhausted) {
			// Read to its end, so the glue has finalized it already.
			return;
		}

		live.__exhausted = true;
		live.__cache.clear();
		// The glue finalizes the statement before it as it prepares one, and
		// has no call to finalize one otherwise. This one is never stepped,
		// so it holds nothing, and the next request finalizes it in turn.
		__request(__handle, "SELECT 1");
	}

	public function close():Void {
		// Let go of under the lock first: an interrupt() already running
		// finishes with the pointer before SQLite frees it, and one arriving
		// later finds nothing.
		__dbLock.acquire();
		var db:cpp.Pointer<cpp.Void> = __db;
		var stop:cpp.Pointer<cpp.Void> = __stop;
		__db = null;
		__stop = null;
		__dbLock.release();

		// Outside the lock, which interrupt() and stopRunning() wait on: this
		// can wait for a statement another thread is stepping. Neither can
		// reach either pointer now.
		if (stop != null) {
			__unwatchProgress(db, stop);
		}

		__live = null;
		__close(__handle);
	}

	public function escape(s:String):String {
		return s.split("'").join("''");
	}

	public function quote(s:String):String {
		if (s.indexOf(String.fromCharCode(0)) >= 0) {
			var hexChars:Array<String> = [];

			for (i in 0...s.length) {
				hexChars.push(StringTools.hex(StringTools.fastCodeAt(s, i), 2));
			}

			return "x'" + hexChars.join("") + "'";
		}

		return "'" + s.split("'").join("''") + "'";
	}

	public function addValue(s:StringBuf, v:Dynamic):Void {
		if (v == null) {
			s.add("NULL");
		} else if (Std.isOfType(v, Bool)) {
			s.add(v ? 1 : 0);
		} else if (Std.isOfType(v, Int) || Std.isOfType(v, Float)) {
			s.add(v);
		} else {
			s.add(quote(Std.string(v)));
		}
	}

	public function lastInsertId():Int {
		return __lastInsertId(__handle);
	}

	public function dbName():String {
		return "SQLite";
	}

	public function startTransaction():Void {
		request("BEGIN TRANSACTION");
	}

	public function commit():Void {
		request("COMMIT");
	}

	public function rollback():Void {
		request("ROLLBACK");
	}

	private function get_autocommit():Bool {
		return __getAutocommit(__handle);
	}

	@:native("_hx_sqlite_connect")
	extern private static function __connect(filename:String):Dynamic;

	@:native("_hx_sqlite_request")
	extern private static function __request(handle:Dynamic, req:String):Dynamic;

	@:native("_hx_sqlite_close")
	extern private static function __close(handle:Dynamic):Void;

	@:native("_hx_sqlite_last_insert_id")
	extern private static function __lastInsertId(handle:Dynamic):Int;

	@:native("_hx_sqlite_get_autocommit")
	extern private static function __getAutocommit(handle:Dynamic):Bool;

	@:native("crossbyte_sqlite_watch_opens")
	extern private static function __watchOpens():Void;

	@:native("crossbyte_sqlite_take_opened")
	extern private static function __takeOpened():cpp.Pointer<cpp.Void>;

	@:native("crossbyte_sqlite_interrupt")
	extern private static function __interruptDb(db:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_watch_progress")
	extern private static function __watchProgress(db:cpp.Pointer<cpp.Void>):cpp.Pointer<cpp.Void>;

	@:native("crossbyte_sqlite_set_stop")
	extern private static function __setStop(stop:cpp.Pointer<cpp.Void>, on:Bool):Void;

	@:native("crossbyte_sqlite_unwatch_progress")
	extern private static function __unwatchProgress(db:cpp.Pointer<cpp.Void>, stop:cpp.Pointer<cpp.Void>):Void;
}

@:noCompletion
@:allow(crossbyte.db.sql.sqlite._internal.NativeSQLiteConnection)
private class NativeSQLiteResultSet implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	@:noCompletion private var __result:Dynamic;
	@:noCompletion private var __cache:List<Dynamic>;
	// Whether the statement has no row left to give: stepped to its end.
	@:noCompletion private var __exhausted:Bool = false;
	// A failure __keepRest met reading ahead, thrown once the rows before it
	// have been taken, where reading them in turn would have met it.
	@:noCompletion private var __failed:Bool = false;
	@:noCompletion private var __failure:Dynamic = null;

	public function new(result:Dynamic) {
		__cache = new List();
		__result = result;
		// Steps the statement once, which is what runs a write.
		hasNext();
	}

	private function get_length():Int {
		if (nfields != 0) {
			var row:Dynamic = __step();

			while (row != null) {
				__cache.add(row);
				row = __step();
			}

			return __cache.length;
		}

		return __length(__result);
	}

	/** The next row from the statement itself, or null once it has none. **/
	@:noCompletion private function __step():Dynamic {
		if (__exhausted) {
			return null;
		}

		var row:Dynamic = __next(__result);

		if (row == null) {
			__exhausted = true;
		}

		return row;
	}

	/**
		Reads the rows the statement has left into this result's own hands,
		before the connection's next request has the glue finalize it.
	**/
	@:noCompletion private function __keepRest():Void {
		try {
			var row:Dynamic = __step();

			while (row != null) {
				__cache.add(row);
				row = __step();
			}
		} catch (e:Dynamic) {
			__exhausted = true;
			__failed = true;
			__failure = e;
		}
	}

	private function get_nfields():Int {
		return __nfields(__result);
	}

	public function hasNext():Bool {
		var row:Dynamic = next();

		if (row == null) {
			return false;
		}

		__cache.push(row);
		return true;
	}

	public function next():Dynamic {
		var cached:Dynamic = __cache.pop();

		if (cached != null) {
			return cached;
		}

		if (__failed) {
			__failed = false;
			var failure:Dynamic = __failure;
			__failure = null;
			throw failure;
		}

		return __step();
	}

	public function results():List<Dynamic> {
		var out:List<Dynamic> = new List();

		while (true) {
			var row:Dynamic = next();

			if (row == null) {
				break;
			}

			out.add(row);
		}

		return out;
	}

	public function getResult(n:Int):String {
		return new String(__get(__result, n));
	}

	public function getIntResult(n:Int):Int {
		return __getInt(__result, n);
	}

	public function getFloatResult(n:Int):Float {
		return __getFloat(__result, n);
	}

	public function getFieldsNames():Null<Array<String>> {
		return null;
	}

	@:native("_hx_sqlite_result_next")
	extern private static function __next(handle:Dynamic):Dynamic;

	@:native("_hx_sqlite_result_get_length")
	extern private static function __length(handle:Dynamic):Int;

	@:native("_hx_sqlite_result_get_nfields")
	extern private static function __nfields(handle:Dynamic):Int;

	@:native("_hx_sqlite_result_get")
	extern private static function __get(handle:Dynamic, i:Int):String;

	@:native("_hx_sqlite_result_get_int")
	extern private static function __getInt(handle:Dynamic, i:Int):Int;

	@:native("_hx_sqlite_result_get_float")
	extern private static function __getFloat(handle:Dynamic, i:Int):Float;
}
#end
