package crossbyte.db.sql.sqlite._internal;

#if !js
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.errors.SQLError;
import crossbyte.events.Event;
import crossbyte.events.SQLErrorEvent;
import sys.db.ResultSet;
#if !php
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
#end

/**
	One piece of work queued for an asynchronous `SQLiteConnection`'s worker.

	`run` does the work on the worker's thread and reports how it went.
	`operation` -- the `SQLEvent` type it reports -- and `statement`, the
	statement it reports to or `null` for the connection's own work, say whom
	to tell when it never runs: queued behind a `close()`, behind an open
	that failed, or before a `cancel()`. `call`, when set, is the caller
	waiting on it, told instead.

	`epoch` is the connection's count of `cancel()` calls when the job was
	queued: one queued before the latest is dropped. A job that `keep`s --
	an open, a close, a cancel's own report -- is never dropped.
	`statementEpoch` is the statement's own count, which its `cancel()`
	moves on: what was asked of it before is dropped, and unheard.
**/
@:noCompletion
class SQLiteJob {
	public var run(default, null):Void->Void;
	public var operation(default, null):String;
	public var statement(default, null):Null<SQLiteStatement>;
	public var epoch(default, null):Int;
	public var keep(default, null):Bool;
	public var call(default, null):Null<SQLiteCall>;
	public var statementEpoch(default, null):Int;

	public function new(run:Void->Void, operation:String, statement:Null<SQLiteStatement>, epoch:Int, keep:Bool, ?call:SQLiteCall) {
		this.run = run;
		this.operation = operation;
		this.statement = statement;
		this.epoch = epoch;
		this.keep = keep;
		this.call = call;
		// Read on the thread that queued it, which is the one cancel() is
		// called on.
		statementEpoch = statement != null ? @:privateAccess statement.__cancels : 0;
	}
}

#if !php
/**
	One worker's queue, and whether that worker has stopped taking work from
	it: set before its last pass over what is left there, so that work asked
	for afterwards is refused where it is asked for, and a call waiting on it
	stops waiting. One per worker, so one stopping as the next starts cannot
	mark the next stopped, nor take its work.
**/
@:noCompletion
class SQLiteQueue {
	public var jobs(default, null):Deque<SQLiteJob> = new Deque();
	public var gone:Bool = false;

	public function new() {}
}
#end

/**
	A call the calling thread makes of an asynchronous connection and waits
	for -- `request()`, a property that asks SQLite -- run by the worker in
	its turn, behind the work queued before it, so that nothing but the
	worker ever touches the connection. hxcpp's glue keeps one live result
	per connection and finalizes it as the next request starts: a read made
	on the calling thread while the worker stepped a statement finalized it
	under the worker, which then read freed memory.

	The caller waits on a `Lock`, which parks a thread where hxcpp's
	collector can still run. `state` is guarded by the connection's mutex:
	the worker moves it from `WAITING` to `RUNNING` as it takes the call
	up, and a caller whose wait ran out moves it from `WAITING` to
	`WITHDRAWN` -- so a call either runs or does not, and never after its
	caller has given up on it. Without threads (php) nothing waits: the
	connection runs every call at once.
**/
@:noCompletion
class SQLiteCall {
	public static inline var WAITING:Int = 0;
	public static inline var RUNNING:Int = 1;
	public static inline var DONE:Int = 2;
	public static inline var WITHDRAWN:Int = 3;

	public var result(default, null):Dynamic = null;
	public var failure(default, null):Dynamic = null;
	public var failed(default, null):Bool = false;

	@:noCompletion private var __work:Void->Dynamic;
	@:noCompletion private var __state:Int = WAITING;
	#if !php
	@:noCompletion private var __guard:Mutex;
	@:noCompletion private var __done:Lock = new Lock();
	#end

	public function new(work:Void->Dynamic, guard:#if !php Mutex #else Dynamic #end) {
		__work = work;
		#if !php
		__guard = guard;
		#end
	}

	/** On the worker: runs the work, unless its caller has gone, and wakes the caller. **/
	public function run():Void {
		if (!__take(RUNNING)) {
			return;
		}

		try {
			result = __work();
		} catch (e:Dynamic) {
			failure = e;
			failed = true;
		}

		__finish();
	}

	/** On the worker: tells the caller its call will not run, and why: `error` is thrown to it. **/
	public function refuse(error:Dynamic):Void {
		if (!__take(DONE)) {
			return;
		}

		failure = error;
		failed = true;
		__finish();
	}

	/**
		On the caller: waits up to `seconds` for the call to be done, or
		without limit for a negative number, and answers whether it is. Whole
		milliseconds: hxcpp spins out the fraction of one.
	**/
	public function waitDone(seconds:Float):Bool {
		#if !php
		if (seconds < 0) {
			__done.wait();
			return true;
		}

		return __done.wait(Math.max(0.001, Math.ffloor(seconds * 1000) / 1000));
		#else
		return true;
		#end
	}

	/**
		On the caller: withdraws the call when the worker has not taken it
		up -- it will not run -- and answers whether it did. A call that has
		started is the caller's own work, and is waited for to its end, as on
		a synchronous connection.
	**/
	public function withdraw():Bool {
		return __take(WITHDRAWN);
	}

	/** Moves a waiting call to `state`; false when its caller withdrew it. **/
	@:noCompletion private function __take(state:Int):Bool {
		#if !php
		__guard.acquire();
		#end
		var waiting:Bool = __state == WAITING;

		if (waiting) {
			__state = state;
		}

		#if !php
		__guard.release();
		#end
		return waiting;
	}

	@:noCompletion private function __finish():Void {
		#if !php
		__guard.acquire();
		__state = DONE;
		__guard.release();
		__done.release();
		#else
		__state = DONE;
		#end
	}
}

/**
	What a connection's `cancel()`s and the work they would stop decide
	between them: the lock, which work is running, and whether it has been
	stopped. Kept apart from the connection, padded onto cache lines of its
	own: the thread running the work writes here twice for every statement,
	and the runtime's thread reads the connection's own fields for every
	statement it queues. Held on the connection itself, the line went back
	and forth between the two cores at each write, which cost 20% of an
	asynchronous statement.
**/
@:noCompletion
class SQLiteRuns {
	@:noCompletion private var __before0:Float = 0;
	@:noCompletion private var __before1:Float = 0;
	@:noCompletion private var __before2:Float = 0;
	@:noCompletion private var __before3:Float = 0;
	@:noCompletion private var __before4:Float = 0;
	@:noCompletion private var __before5:Float = 0;
	@:noCompletion private var __before6:Float = 0;
	@:noCompletion private var __before7:Float = 0;

	/** On cpp, 0 free and 1 held, taken by an atomic compare-and-swap. **/
	public var lock:Int = 0;

	/** The statement whose work is running, if it is a statement's. **/
	public var runner:Null<SQLiteStatement> = null;

	/** Whether work a `cancel()` stops is running. **/
	public var running:Bool = false;

	/** Whether that work has been stopped, so what runs next is let run. **/
	public var stopping:Bool = false;

	@:noCompletion private var __after0:Float = 0;
	@:noCompletion private var __after1:Float = 0;
	@:noCompletion private var __after2:Float = 0;
	@:noCompletion private var __after3:Float = 0;
	@:noCompletion private var __after4:Float = 0;
	@:noCompletion private var __after5:Float = 0;
	@:noCompletion private var __after6:Float = 0;
	@:noCompletion private var __after7:Float = 0;

	public function new() {}
}

/**
	A result read whole where it ran, so that whoever it is handed to reads
	it without touching the connection: what `request()` answers on an
	asynchronous connection, whose worker read it. `length` is the rows read,
	or for a statement that returns none, the rows it changed. A row is read
	by name: `getResult()`, `getIntResult()` and `getFloatResult()` read the
	row the statement stands on, and this has no statement.
**/
@:noCompletion
class SQLiteReadRows implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	@:noCompletion private var __rows:Array<Dynamic> = [];
	@:noCompletion private var __index:Int = 0;
	@:noCompletion private var __length:Int;
	@:noCompletion private var __nfields:Int;

	public function new(result:ResultSet) {
		__nfields = result.nfields;

		if (__nfields == 0) {
			__length = result.length;
			return;
		}

		while (result.hasNext()) {
			__rows.push(result.next());
		}

		__length = __rows.length;
	}

	private function get_length():Int {
		return __length;
	}

	private function get_nfields():Int {
		return __nfields;
	}

	public function hasNext():Bool {
		return __index < __rows.length;
	}

	public function next():Dynamic {
		return __index < __rows.length ? __rows[__index++] : null;
	}

	public function results():List<Dynamic> {
		var out:List<Dynamic> = new List();

		while (__index < __rows.length) {
			out.add(__rows[__index++]);
		}

		return out;
	}

	public function getResult(n:Int):String {
		return __byPosition();
	}

	public function getIntResult(n:Int):Int {
		return __byPosition();
	}

	public function getFloatResult(n:Int):Float {
		return __byPosition();
	}

	public function getFieldsNames():Null<Array<String>> {
		return null;
	}

	@:noCompletion private function __byPosition():Dynamic {
		throw new SQLError("request", "No statement to read by position",
			"This result was read whole on the connection's worker: read its rows by name, with next().");
	}
}

/**
	What a statement's work on the worker sends back to the runtime's thread:
	the page it read, there, and the event to dispatch with it.

	The rows are read on the worker. They were read on the runtime's thread
	from the result set the worker handed over, while the worker had already
	gone on to the next statement -- and hxcpp's glue starts a statement by
	finalizing the one before it, so a statement queued behind another took
	all but the first of its rows.
**/
@:noCompletion
class SQLiteStatementMessage {
	public var statement(default, null):SQLiteStatement;
	public var event:Event;

	/** The page read, or `null` when there is none to queue. **/
	public var rows:Null<Array<Dynamic>> = null;

	/** Whether no rows remain: the statement has finished. **/
	public var done:Bool = false;

	/** Whether this answers `execute()`, which sets the rows affected; `next()` leaves them. **/
	public var executed:Bool;

	public var affected:Float = 0;

	/** The statement's rowid, read once its rows were all read; meaningful when `done`. **/
	public var rowId:Float = 0;

	/**
		The statement's count of `cancel()` calls when the work this answers
		was asked for: one its `cancel()` has stopped since is not dispatched.
	**/
	public var epoch(default, null):Int;

	public function new(statement:SQLiteStatement, executed:Bool, epoch:Int) {
		this.statement = statement;
		this.executed = executed;
		this.epoch = epoch;
	}

	/** Turns this into the report of a failure. **/
	public function fail(error:SQLError):Void {
		rows = null;
		done = true;
		event = new SQLErrorEvent(SQLErrorEvent.ERROR, error);
	}
}
#end
