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
 * Through the same pointer, on an asynchronous connection, it registers a
 * progress handler, which SQLite calls every thousand steps of its virtual
 * machine: it stops the run a `cancel()` has asked to stop while that run is
 * the one under way (`publish`, `beginStop`, `stop`). `sqlite3_interrupt`
 * alone is lost when it lands as a statement starts -- SQLite clears it
 * there when no other statement is running -- and a `cancel()` can land
 * just then, as the worker takes the work up. The interrupt is still made:
 * it stops a single step that runs long, such as counting a whole table,
 * inside which SQLite calls no handler. A synchronous connection has the
 * handler too, over a record of its own: each request is its run, from
 * before it is prepared until its first step returns, and `interrupt()`,
 * called from another thread, stops the one starting as well.
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

// What a cancel() and the work it would stop decide between them, one per
// connection: for an asynchronous connection made and freed by the
// connection on the thread that runs it, for a synchronous one by its
// native connection. runner is the run under way -- the work of the worker,
// or a synchronous request -- 0 for none; stopFor, the run a cancel() has
// asked the progress handler to stop; stopping, how many cancel()s are
// between reading the run under way and having interrupted it, while the
// worker starts no run; cancels, on a synchronous connection, how many
// interrupt()s there have been. Padded onto cache lines of their own: the
// runner writes runner twice for each piece of work, and nothing else
// touches them but a cancel().
struct crossbyte_sqlite_runs {
	char before[64];
	std::atomic<int> runner;
	std::atomic<int> stopFor;
	std::atomic<int> stopping;
	std::atomic<int> cancels;
	char after[64];
};

static void *crossbyte_sqlite_runs_new() {
	crossbyte_sqlite_runs *runs = new crossbyte_sqlite_runs();
	runs->runner.store(0);
	runs->stopFor.store(0);
	runs->stopping.store(0);
	runs->cancels.store(0);
	return runs;
}

static void crossbyte_sqlite_runs_free(void *runs) {
	delete (crossbyte_sqlite_runs *)runs;
}

// Called by SQLite every thousand steps of a statement, on the thread
// stepping it: stops it when a cancel() has asked for the run under way,
// failing it with SQLITE_INTERRUPT as sqlite3_interrupt does.
static int crossbyte_sqlite_progress(void *p) {
	crossbyte_sqlite_runs *runs = (crossbyte_sqlite_runs *)p;
	int stop = runs->stopFor.load(std::memory_order_relaxed);
	return stop != 0 && stop == runs->runner.load(std::memory_order_relaxed);
}

// Registering and removing the handler takes the mutex of the connection,
// which a statement stepping on another thread holds: in a GC-free zone, as
// the blocking calls of the glue are, touching nothing of the GC inside.
static void crossbyte_sqlite_watch(void *db, void *runs) {
	hx::EnterGCFreeZone();
	sqlite3_progress_handler((struct sqlite3 *)db, 1000, crossbyte_sqlite_progress, runs);
	hx::ExitGCFreeZone();
}

// Before the connection closes: nothing calls the handler after this.
static void crossbyte_sqlite_unwatch(void *db) {
	hx::EnterGCFreeZone();
	sqlite3_progress_handler((struct sqlite3 *)db, 0, 0, 0);
	hx::ExitGCFreeZone();
}

// The worker, as a run starts: publishes it, then reads the count of
// cancel()s -- in that order, as a cancel() counts itself and then reads
// the run under way, so that one of the two always sees the other. -1
// instead while a cancel() is stopping a run: the worker waits for it to
// finish before it starts this one. A stop asked for before this run was
// published is for a run that has ended: it is cleared, so that a run
// number met again is not stopped by it.
static int crossbyte_sqlite_publish(void *p, int run, int *cancels) {
	crossbyte_sqlite_runs *runs = (crossbyte_sqlite_runs *)p;

	if (runs->stopFor.load(std::memory_order_relaxed) != 0) {
		runs->stopFor.store(0, std::memory_order_relaxed);
	}

	runs->runner.store(run, std::memory_order_seq_cst);
	int count;
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
	// The store above is an xchg here, a full barrier: a plain read after it
	// is ordered after it.
	count = *(volatile int *)cancels;
#elif defined(_MSC_VER)
	std::atomic_thread_fence(std::memory_order_seq_cst);
	count = *(volatile int *)cancels;
#else
	count = __atomic_load_n(cancels, __ATOMIC_SEQ_CST);
#endif

	if (runs->stopping.load(std::memory_order_seq_cst) != 0) {
		return -1;
	}

	return count;
}

static void crossbyte_sqlite_unpublish(void *p) {
	((crossbyte_sqlite_runs *)p)->runner.store(0, std::memory_order_release);
}

// A cancel(), after counting itself: holds the worker back from starting a
// run until crossbyte_sqlite_end_stop, then reads the run under way, 0 for
// none -- in that order, as the worker publishes its run and then reads
// whether a cancel() is stopping one, so that one of the two always sees
// the other. An interrupt made in between lands in the run it was read
// for, or before the next one starts: never inside the next one.
static int crossbyte_sqlite_begin_stop(void *p) {
	crossbyte_sqlite_runs *runs = (crossbyte_sqlite_runs *)p;
	runs->stopping.fetch_add(1, std::memory_order_seq_cst);
	return runs->runner.load(std::memory_order_seq_cst);
}

static void crossbyte_sqlite_end_stop(void *p) {
	((crossbyte_sqlite_runs *)p)->stopping.fetch_sub(1, std::memory_order_seq_cst);
}

// The worker, waiting to start a run: whether a cancel() is still stopping
// one.
static bool crossbyte_sqlite_stopping(void *p) {
	return ((crossbyte_sqlite_runs *)p)->stopping.load(std::memory_order_acquire) != 0;
}

static void crossbyte_sqlite_stop(void *p, int run) {
	((crossbyte_sqlite_runs *)p)->stopFor.store(run, std::memory_order_seq_cst);
}

// A synchronous connection runs a request on the thread that asks for it,
// and a cancel() comes from another: the same record, with the request as
// the run. The count of interrupt()s, read as the request is asked for.
static int crossbyte_sqlite_sync_cancels(void *p) {
	return ((crossbyte_sqlite_runs *)p)->cancels.load(std::memory_order_seq_cst);
}

// As the request starts, before it is prepared: published, after clearing a
// stop asked for a run that has ended, and then the count of interrupt()s
// read again -- in that order, as an interrupt() counts itself and then
// reads the run under way, so that one of the two always sees the other.
// True when one has come since `since` was read: the request is not run.
static bool crossbyte_sqlite_sync_begin(void *p, int run, int since) {
	crossbyte_sqlite_runs *runs = (crossbyte_sqlite_runs *)p;

	if (runs->stopFor.load(std::memory_order_relaxed) != 0) {
		runs->stopFor.store(0, std::memory_order_relaxed);
	}

	runs->runner.store(run, std::memory_order_seq_cst);
	return runs->cancels.load(std::memory_order_seq_cst) != since;
}

// Once its first step has returned: no longer starting, and whether an
// interrupt() asked to stop it meanwhile -- one that read it as under way
// and asks only after this interrupts it as well, which by then lands.
static bool crossbyte_sqlite_sync_end(void *p, int run) {
	crossbyte_sqlite_runs *runs = (crossbyte_sqlite_runs *)p;
	runs->runner.store(0, std::memory_order_seq_cst);
	return runs->stopFor.load(std::memory_order_seq_cst) == run;
}

// An interrupt() of a synchronous connection, before the one of SQLite:
// counts itself, then has the progress handler stop the request starting
// now, if one is. Fenced after: the interrupt SQLite then makes is a plain
// store, which on an ARM processor may be seen before a store-release made
// ahead of it. Seen first, and cleared by the request as its statement
// starts, it would leave that request reading no stop when its first step
// returns, and running on.
static void crossbyte_sqlite_sync_stop(void *p) {
	crossbyte_sqlite_runs *runs = (crossbyte_sqlite_runs *)p;
	runs->cancels.fetch_add(1, std::memory_order_seq_cst);
	int now = runs->runner.load(std::memory_order_seq_cst);

	if (now != 0) {
		runs->stopFor.store(now, std::memory_order_seq_cst);
	}

	std::atomic_thread_fence(std::memory_order_seq_cst);
}
')
class NativeSQLiteConnection implements Connection {
	@:noCompletion private var __handle:Dynamic;

	// The sqlite3 pointer behind __handle, or null once closed. Guarded by
	// __dbLock: interrupt() may run on any thread, and must never reach a
	// connection close() has freed.
	@:noCompletion private var __db:cpp.Pointer<cpp.Void>;
	@:noCompletion private var __dbLock:sys.thread.Mutex;
	// Whether the progress handler is registered: from open() to close().
	@:noCompletion private var __watched:Bool = false;
	// A synchronous connection's record of its requests, its own: each
	// request is published there as it starts, and an interrupt() asks the
	// progress handler to stop the one starting. Null on an asynchronous
	// connection, whose worker publishes its runs in the record it was
	// opened with. Freed by close(), under __dbLock, as interrupt() reads it.
	@:noCompletion private var __syncRuns:cpp.Pointer<cpp.Void> = null;
	// Numbers the requests published there; 0 is none.
	@:noCompletion private var __syncRun:Int = 0;

	/**
		Opens `path`. `runs`, from `newRuns()`, is an asynchronous
		connection's: its progress handler reads it, and stops the run a
		`cancel()` asks to stop there. Null for a synchronous connection,
		which makes a record of its own: its requests are its runs, and an
		`interrupt()` from another thread stops the one starting as well.
	**/
	public static function open(path:String, runs:cpp.Pointer<cpp.Void>):NativeSQLiteConnection {
		__watchOpens();
		// Cleared first, so what is taken below can only be this open's.
		__takeOpened();
		var connection:NativeSQLiteConnection = new NativeSQLiteConnection(__connect(path));
		connection.__db = __takeOpened();

		if (connection.__db != null) {
			if (runs == null) {
				runs = __runsNew();
				connection.__syncRuns = runs;
			}

			__watch(connection.__db, runs);
			connection.__watched = true;
		}

		return connection;
	}

	/**
		A new record of an asynchronous connection's runs, for `open`, the
		worker (`publish`, `unpublish`) and a `cancel()` (`running`, `stop`).
		Freed with `freeRuns`, once nothing can use it.
	**/
	public static function newRuns():cpp.Pointer<cpp.Void> {
		return __runsNew();
	}

	public static function freeRuns(runs:cpp.Pointer<cpp.Void>):Void {
		__runsFree(runs);
	}

	/**
		The worker, as a run starts: publishes `run` as the one under way,
		then reads `cancels`, the connection's count of `cancel()`s, and
		answers it -- in that order, as a `cancel()` counts itself and then
		reads the run under way, so that one of the two always sees the other.
		Answers -1 instead while a `cancel()` is stopping a run, between
		`beginStop` and `endStop`: the worker waits for `stopping` to clear
		before it starts this one.
	**/
	public static function publish(runs:cpp.Pointer<cpp.Void>, run:Int, cancels:cpp.Pointer<Int>):Int {
		return __publish(runs, run, cancels);
	}

	/** The worker, as a run ends: nothing is under way. **/
	public static function unpublish(runs:cpp.Pointer<cpp.Void>):Void {
		__unpublish(runs);
	}

	/**
		A `cancel()`, after counting itself: holds the worker back from
		starting a run until `endStop`, and answers the run under way, 0 for
		none. What it interrupts in between is that run, or nothing: the
		interrupt lands before the next run starts, never inside it.
	**/
	public static function beginStop(runs:cpp.Pointer<cpp.Void>):Int {
		return __beginStop(runs);
	}

	public static function endStop(runs:cpp.Pointer<cpp.Void>):Void {
		__endStop(runs);
	}

	/** The worker, waiting to start a run: whether a `cancel()` is still between `beginStop` and `endStop`. **/
	public static function stopping(runs:cpp.Pointer<cpp.Void>):Bool {
		return __stopping(runs);
	}

	/**
		A `cancel()`: has the progress handler stop `run` while it is the one
		under way -- within a thousand steps, failing it with "interrupted" --
		and never another.
	**/
	public static function stop(runs:cpp.Pointer<cpp.Void>, run:Int):Void {
		__stop(runs, run);
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

		On a synchronous connection a request that is only starting is
		stopped too (see `requestSince`): SQLite clears an interrupt that
		lands while a statement is prepared.
	**/
	public function interrupt():Void {
		__dbLock.acquire();

		if (__db != null) {
			var runs:cpp.Pointer<cpp.Void> = __syncRuns;

			if (runs != null) {
				__syncStop(runs);
			}

			__interruptDb(__db);
		}

		__dbLock.release();
	}

	/**
		On a synchronous connection, how many `interrupt()`s there have been:
		read as work is asked for, before anything else, and handed to
		`requestSince`. 0 on an asynchronous connection, whose worker keeps
		its own count.
	**/
	public function cancels():Int {
		var runs:cpp.Pointer<cpp.Void> = __syncRuns;
		return runs != null ? __syncCancels(runs) : 0;
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
		return requestSince(s, cancels());
	}

	/**
		How many prepared statements the connection keeps, by their text. A
		statement prepared past this takes the place of the oldest kept.
	**/
	public static inline var PREPARED_LIMIT:Int = 64;

	// The statements prepared on this connection, by their text, idle or
	// running, and their texts in the order they were prepared; see
	// __prepared.
	@:noCompletion private var __prepared:haxe.ds.StringMap<NativeSQLiteStatement> = new haxe.ds.StringMap();
	@:noCompletion private var __preparedOrder:Array<String> = [];

	/**
		`s`'s statement, prepared on this connection: the one kept for its
		text when it is idle, or a new one, kept for the text when it is not
		already. Given back with `__give` once its run is over.
	**/
	@:noCompletion private function __take(s:String):NativeSQLiteStatement {
		var kept:NativeSQLiteStatement = __prepared.get(s);

		if (kept != null && !kept.busy) {
			kept.busy = true;
			return kept;
		}

		var statement:NativeSQLiteStatement = NativeSQLiteStatement.prepare(__db, s);
		statement.busy = true;

		if (kept == null) {
			__prepared.set(s, statement);
			__preparedOrder.push(s);

			if (__preparedOrder.length > PREPARED_LIMIT) {
				var oldest:String = __preparedOrder.shift();
				var old:NativeSQLiteStatement = __prepared.get(oldest);
				__prepared.remove(oldest);

				if (old != null) {
					if (old.busy) {
						// Running: freed when it is given back.
						old.kept = false;
					} else {
						old.free();
					}
				}
			}
		} else {
			// Its text's kept one is running -- a statement read a page at a
			// time, another run of the same text meanwhile -- so this one is
			// used once and freed.
			statement.kept = false;
		}

		return statement;
	}

	/** `statement`'s run is over: reset and kept for its next, or freed. **/
	@:noCompletion private function __give(statement:NativeSQLiteStatement):Void {
		statement.busy = false;

		if (!statement.kept) {
			statement.free();
			return;
		}

		try {
			statement.reset();
		} catch (e:Dynamic) {
			// Reset reports the run's own failure again; it is reset regardless.
		}
	}

	/**
		`s` run with `parameters` bound to its `:name`s, prepared once and
		kept: `request`, for a statement with values to bind. Asked for when
		`cancels()` read `since`, and stopped by an `interrupt()` as
		`requestSince` is.
	**/
	public function requestBound(s:String, parameters:Null<haxe.ds.StringMap<Dynamic>>, since:Int):ResultSet {
		return __requestWith(s, parameters, since, true);
	}

	/**
		`s` run with `parameters` bound, its rows given to `each` one at a
		time, as a row `SQLRow` reads by column, with nothing made for a row:
		`SQLiteStatement.executeEach`. Answers the rows the statement
		changed, for one that returns none. Stopped by an `interrupt()` as
		`requestSince` is; a failure in `each` ends the run and is thrown
		as it is.
	**/
	public function eachRow(s:String, parameters:Null<haxe.ds.StringMap<Dynamic>>, since:Int, each:crossbyte.db.sql.SQLRow->Void):Int {
		if (__db == null) {
			throw new crossbyte.errors.IllegalOperationError("The connection's sqlite3 was not reached, so there is no statement to read by column.");
		}

		settle();
		var statement:NativeSQLiteStatement = __take(s);
		var row:SQLiteRow = new SQLiteRow(statement);
		var more:Bool;

		try {
			statement.bind(parameters);
			more = __firstStep(statement, since);

			while (more) {
				each(row);
				more = statement.step();
			}
		} catch (e:Dynamic) {
			__give(statement);
			throw e;
		}

		var changed:Int = statement.columns == 0 ? statement.changes() : 0;
		__give(statement);
		return changed;
	}

	/**
		The first step of `statement`, which is what runs a write, under the
		same watch as `requestSince`: an `interrupt()` made since `since`
		was read stops it.
	**/
	@:noCompletion private function __firstStep(statement:NativeSQLiteStatement, since:Int):Bool {
		var runs:cpp.Pointer<cpp.Void> = __syncRuns;

		if (runs == null) {
			return statement.step();
		}

		var run:Int = ++__syncRun;

		if (run == 0) {
			run = __syncRun = 1;
		}

		if (__syncBegin(runs, run, since)) {
			__syncEnd(runs, run);
			throw "Sqlite error : interrupted";
		}

		var more:Bool;

		try {
			more = statement.step();
		} catch (e:Dynamic) {
			__syncEnd(runs, run);
			throw e;
		}

		if (__syncEnd(runs, run) && more) {
			__dbLock.acquire();

			if (__db != null) {
				__interruptDb(__db);
			}

			__dbLock.release();
		}

		return more;
	}

	/**
		`request(s)`, asked for when `cancels()` read `since`.

		On a synchronous connection an `interrupt()` made since then stops it,
		however far it has got. One made before it is published here fails it
		with "interrupted" before it is prepared. From then until its first
		step returns it is the run under way, which the progress handler stops
		within a thousand steps -- and one whose first step returned sooner is
		interrupted again, so its next step fails. SQLite clears an interrupt
		that lands while a statement is prepared, and on its own such a
		request ran on, for as long as it took: an aggregate for its hours,
		a SELECT through every row.
	**/
	public function requestSince(s:String, since:Int):ResultSet {
		return __requestWith(s, null, since, false);
	}

	/**
		`requestSince`, with `parameters` bound when `bound`. Natively the
		statement is prepared once and kept (`__take`), its rows made with
		fixed slots; the glue prepares it again for every run, and is used
		only when the connection's `sqlite3` was not reached.
	**/
	@:noCompletion private function __requestWith(s:String, parameters:Null<haxe.ds.StringMap<Dynamic>>, since:Int, bound:Bool):ResultSet {
		settle();
		var runs:cpp.Pointer<cpp.Void> = __syncRuns;
		var result:NativeSQLiteResultSet;

		if (__db == null && bound) {
			// No sqlite3 reached to prepare on: the values written into the
			// text, through the glue, as before.
			s = @:privateAccess crossbyte.db.sql.sqlite.SQLiteConnection.__substitute(s, parameters);
		}

		if (runs == null) {
			result = __start(s, parameters);
		} else {
			var run:Int = ++__syncRun;

			if (run == 0) {
				run = __syncRun = 1;
			}

			if (__syncBegin(runs, run, since)) {
				__syncEnd(runs, run);
				// As the glue reports one SQLite stopped.
				throw "Sqlite error : interrupted";
			}

			try {
				result = __start(s, parameters);
			} catch (e:Dynamic) {
				__syncEnd(runs, run);
				throw e;
			}

			if (__syncEnd(runs, run) && !result.__exhausted) {
				// Asked to stop as it started, and its first step was over
				// before the handler was called: interrupted now, while it is
				// running, its next step fails.
				__dbLock.acquire();

				if (__db != null) {
					__interruptDb(__db);
				}

				__dbLock.release();
			}
		}

		if (!result.__exhausted) {
			__live = result;
		}

		return result;
	}

	/**
		Starts `s`: prepared once and kept, `parameters` bound, its first step
		taken, which is what runs a write. Through the glue when the
		connection's `sqlite3` was not reached.
	**/
	@:noCompletion private function __start(s:String, parameters:Null<haxe.ds.StringMap<Dynamic>>):NativeSQLiteResultSet {
		if (__db == null) {
			return new NativeSQLiteResultSet(__request(__handle, s), null, null);
		}

		var statement:NativeSQLiteStatement = __take(s);

		try {
			statement.bind(parameters);
		} catch (e:Dynamic) {
			__give(statement);
			throw e;
		}

		// Its first step, taken by the result as it is made, gives the
		// statement back itself should it fail.
		return new NativeSQLiteResultSet(null, statement, this);
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

		if (live.__statement != null) {
			// Reset, which ends its read, and kept for its next run.
			live.__release();
			return;
		}

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
		__db = null;
		__dbLock.release();

		// Outside the lock, which interrupt() waits on: this can wait for a
		// statement another thread is stepping.
		if (__watched && db != null) {
			__watched = false;
			__unwatch(db);
		}

		// Read by the handler, gone above, and by an interrupt() under the
		// lock, which finds no connection now.
		var runs:cpp.Pointer<cpp.Void> = __syncRuns;

		if (runs != null) {
			__syncRuns = null;
			__runsFree(runs);
		}

		// Every statement prepared here, finalized: SQLite will not close a
		// connection that still has one.
		var live:NativeSQLiteResultSet = __live;
		__live = null;

		if (live != null && live.__statement != null) {
			live.__exhausted = true;
			live.__cache.clear();
			live.__release();
		}

		for (statement in __prepared) {
			if (statement.busy) {
				statement.kept = false;
			} else {
				statement.free();
			}
		}

		__prepared = new haxe.ds.StringMap();
		__preparedOrder = [];
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

	@:native("crossbyte_sqlite_runs_new")
	extern private static function __runsNew():cpp.Pointer<cpp.Void>;

	@:native("crossbyte_sqlite_runs_free")
	extern private static function __runsFree(runs:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_watch")
	extern private static function __watch(db:cpp.Pointer<cpp.Void>, runs:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_unwatch")
	extern private static function __unwatch(db:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_publish")
	extern private static function __publish(runs:cpp.Pointer<cpp.Void>, run:Int, cancels:cpp.Pointer<Int>):Int;

	@:native("crossbyte_sqlite_unpublish")
	extern private static function __unpublish(runs:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_begin_stop")
	extern private static function __beginStop(runs:cpp.Pointer<cpp.Void>):Int;

	@:native("crossbyte_sqlite_end_stop")
	extern private static function __endStop(runs:cpp.Pointer<cpp.Void>):Void;

	@:native("crossbyte_sqlite_stopping")
	extern private static function __stopping(runs:cpp.Pointer<cpp.Void>):Bool;

	@:native("crossbyte_sqlite_stop")
	extern private static function __stop(runs:cpp.Pointer<cpp.Void>, run:Int):Void;

	@:native("crossbyte_sqlite_sync_cancels")
	extern private static function __syncCancels(runs:cpp.Pointer<cpp.Void>):Int;

	@:native("crossbyte_sqlite_sync_begin")
	extern private static function __syncBegin(runs:cpp.Pointer<cpp.Void>, run:Int, since:Int):Bool;

	@:native("crossbyte_sqlite_sync_end")
	extern private static function __syncEnd(runs:cpp.Pointer<cpp.Void>, run:Int):Bool;

	@:native("crossbyte_sqlite_sync_stop")
	extern private static function __syncStop(runs:cpp.Pointer<cpp.Void>):Void;
}

@:noCompletion
@:allow(crossbyte.db.sql.sqlite._internal.NativeSQLiteConnection)
@:access(crossbyte.db.sql.sqlite._internal.NativeSQLiteConnection)
private class NativeSQLiteResultSet implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	// The glue's result, or null for a statement of the connection's own.
	@:noCompletion private var __result:Dynamic;
	// The prepared statement being read, until its run is over; then null,
	// and given back to the connection.
	@:noCompletion private var __statement:NativeSQLiteStatement;
	@:noCompletion private var __owner:NativeSQLiteConnection;
	@:noCompletion private var __columns:Int = 0;
	@:noCompletion private var __stepped:Bool = false;
	// What a write changed, read as its run ended.
	@:noCompletion private var __changed:Int = 0;
	@:noCompletion private var __cache:List<Dynamic>;
	// Whether the statement has no row left to give: stepped to its end.
	@:noCompletion private var __exhausted:Bool = false;
	// A failure __keepRest met reading ahead, thrown once the rows before it
	// have been taken, where reading them in turn would have met it.
	@:noCompletion private var __failed:Bool = false;
	@:noCompletion private var __failure:Dynamic = null;

	public function new(result:Dynamic, statement:NativeSQLiteStatement, owner:NativeSQLiteConnection) {
		__cache = new List();
		__result = result;
		__statement = statement;
		__owner = owner;

		if (statement != null) {
			__columns = statement.columns;
		}

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

		return __result == null ? __changed : __length(__result);
	}

	/** The next row from the statement itself, or null once it has none. **/
	@:noCompletion private function __step():Dynamic {
		if (__exhausted) {
			return null;
		}

		if (__result == null) {
			return __stepPrepared();
		}

		var row:Dynamic = __next(__result);

		if (row == null) {
			__exhausted = true;
		}

		return row;
	}

	/**
		`__step` for a prepared statement: its run is over at its last row or
		its failure, and the statement is then given back to be run again.
	**/
	@:noCompletion private function __stepPrepared():Dynamic {
		var statement:NativeSQLiteStatement = __statement;

		if (statement == null) {
			__exhausted = true;
			return null;
		}

		var more:Bool;

		try {
			more = statement.step();
		} catch (e:Dynamic) {
			__exhausted = true;
			__release();
			throw e;
		}

		if (!__stepped) {
			// Its columns as they are once it has run: SQLite prepares it again
			// at its first step when the schema has changed.
			__stepped = true;
			__columns = statement.columns;
		}

		if (more) {
			return statement.row();
		}

		__exhausted = true;

		if (__columns == 0) {
			__changed = statement.changes();
		}

		__release();
		return null;
	}

	/** Gives the prepared statement back, its run over. **/
	@:noCompletion private function __release():Void {
		var statement:NativeSQLiteStatement = __statement;

		if (statement != null) {
			__statement = null;
			__owner.__give(statement);
		}
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
		return __result == null ? __columns : __nfields(__result);
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
		if (__result == null) {
			return __current(n).columnText(n);
		}

		return new String(__get(__result, n));
	}

	public function getIntResult(n:Int):Int {
		if (__result == null) {
			return __current(n).columnInt(n);
		}

		return __getInt(__result, n);
	}

	public function getFloatResult(n:Int):Float {
		if (__result == null) {
			return __current(n).columnFloat(n);
		}

		return __getFloat(__result, n);
	}

	/**
		The prepared statement standing on the row last read, for reading
		column `n` of it by position, as the glue's result reads its current
		row; refused as the glue refuses once there is none.
	**/
	@:noCompletion private function __current(n:Int):NativeSQLiteStatement {
		var statement:NativeSQLiteStatement = __statement;

		if (statement == null) {
			throw "Sqlite: no more results";
		}

		if (n < 0 || n >= __columns) {
			throw "Sqlite: Invalid index";
		}

		return statement;
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
