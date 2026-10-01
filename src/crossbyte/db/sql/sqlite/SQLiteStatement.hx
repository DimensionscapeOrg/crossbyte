package crossbyte.db.sql.sqlite;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.FieldStruct;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.SQLError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql._internal.ItemRows;
import crossbyte.db.sql._internal.ParamBinder;
import crossbyte.db.sql.sqlite._internal.SQLiteJob;
import sys.db.Connection;
import sys.db.ResultSet;

/**
 * ...
 * @author Christopher Speciale
 */
@:access(crossbyte.db.sql.sqlite.SQLiteConnection)
class SQLiteStatement extends EventDispatcher {
	public var executing(get, null):Bool;

	/**
		A class each row is made an instance of, as AIR's `itemClass`: made
		with no arguments, and each field set from the column of its name. A
		column the class has no field for fails the statement with an
		`SQLError`. Null, the default, leaves rows anonymous objects.
	**/
	public var itemClass:Class<Dynamic>;
	public var parameters(default, null):FieldStruct<String>;
	public var sqlConnection(get, set):SQLiteConnection;
	public var text:String;

	private var __sqlConnection:SQLiteConnection;
	private var __executing:Bool = false;
	// The result being read. On an asynchronous connection it is the
	// worker's alone: made, read and dropped there.
	private var __resultSet:ResultSet;
	// Pages read and not yet taken by getResult(), oldest first. Only the
	// thread that called the statement touches it, the worker sends its
	// pages there, so a plain Array serves every target. It was a Deque on
	// cpp and, elsewhere, an Array read with pop(), which hands back the
	// newest page first.
	private var __resultQueue:Array<Array<Dynamic>> = [];
	// The connection's last rowid as this statement finished, read on the
	// thread that ran it once its rows were all read. It was read by
	// getResult(), on the caller's thread while the worker might be running
	// the next statement, and so reported whichever insert had happened last.
	@:noCompletion private var __rowId:Float = 0;
	// What the statement changed, from where it ran; see __affectedOf.
	@:noCompletion private var __affected:Float = 0;
	// Whether the page __readRows last read took the last row.
	@:noCompletion private var __pageDone:Bool = false;
	// How many times cancel() has been called. Work asked of the statement
	// before the latest is dropped where it waits, and what it sent back is
	// not dispatched. Moved on under the connection's __lockRuns().
	@:noCompletion private var __cancels:Int = 0;
	// Where the statement runs, the worker, on an asynchronous connection,
	// the cancel count __resultSet was made under.
	@:noCompletion private var __resultEpoch:Int = 0;

	public function new() {
		super();
		parameters = new FieldStruct();
	}

	/**
		Stops this statement, and only it, as AIR's `cancel()` does: its work
		that has not run is dropped, its work running now is interrupted,
		SQLite stops it at its next step, and the rows it had left unread
		are let go of, which ends the read it held open. `executing` is
		`false` from the call on, and nothing more is dispatched for what was
		asked of it before; the connection's other work carries on. Does
		nothing when the statement is not executing. `text` and `parameters`
		are cleared.

		On a synchronous connection a statement runs on the thread that
		executes it, so it is another thread that cancels one running: it
		is interrupted, and its `execute()` or `next()` fails there with
		"interrupted", dispatching its `SQLErrorEvent` and throwing the
		`SQLError`, as any failure does. On targets other than cpp work
		already running is not interrupted, and finishes first.

		It reset only the statement's own fields: the work queued for it
		still ran, an INSERT cancelled before its turn inserted, a
		statement running ran on to its end, and the rows of one read a page
		at a time stayed open on the worker, holding SQLite's read, until the
		next statement there read them all.
	**/
	public function cancel():Void {
		if (!__executing) {
			return;
		}

		var connection:SQLiteConnection = __sqlConnection;
		var running:Bool = connection != null && connection.__cancelStatement(this);

		if (running && !connection.__async) {
			// On another thread, which puts the statement right as its
			// execute() or next() fails there.
			return;
		}

		__executing = false;
		__resultQueue = [];

		if (connection != null) {
			if (connection.__async) {
				// The result is the worker's: let go of there.
				connection.__dropPage();
			} else {
				connection.__letGo(__resultSet);
				__resultSet = null;
			}
		} else {
			__resultSet = null;
		}

		text = "";
		clearParameters();
	}

	public function clearParameters():Void {
		parameters = new FieldStruct();
	}

	/**
		Runs `text`, with `parameters` substituted, and queues the first
		`prefetch` rows (all of them for `-1`) for `getResult()`, then
		dispatches `SQLEvent.RESULT`. A statement SQLite refuses is dispatched
		as an `SQLErrorEvent` and thrown as its `SQLError`, as MySQL's and
		Postgres's statements do; on an asynchronous connection it is only
		dispatched, since the caller has returned by then.

		A synchronous statement dispatched no `RESULT` at all, and a failed
		one let the driver's raw `String` escape with no `SQLErrorEvent`.

		@throws IllegalOperationError When `sqlConnection` is not set, or not
		open.
	**/
	public function execute(prefetch:Int = -1):Void {
		if (__sqlConnection == null || !__sqlConnection.__isOpen()) {
			// Dereferenced: a statement with no open connection crashed.
			throw new IllegalOperationError("SQLiteStatement: sqlConnection is not set, or is not open.");
		}

		var sql:String = __applyParameters(text);

		__executing = true;
		__resultQueue = [];

		var connection:SQLiteConnection = __sqlConnection;

		if (connection.__async) {
			connection.__addToQueue(__executeAsync(sql, prefetch, __cancels, connection.__cancelEpoch), SQLEvent.RESULT, this);
			return;
		}

		__rowId = 0;
		// What a run before left unread is let go of, not read first.
		connection.__letGo(__resultSet);
		__resultSet = null;
		connection.__settle();
		connection.__enter(this, __cancels, connection.__cancelEpoch);

		try {
			__resultSet = connection.__connection.request(sql);
			__affected = __affectedOf(__resultSet);
			var rows:Array<Dynamic> = __readRows(__resultSet, prefetch);

			if (prefetch != 0) {
				__resultQueue.push(rows);
			}

			if (__pageDone) {
				__executing = false;
			}

			__noteRowId();
		} catch (e:Dynamic) {
			connection.__leave();
			__executing = false;
			__resultSet = null;
			__fail(e);
		}

		connection.__leave();
		// Outside the try: a RESULT listener that throws has not made the
		// statement fail, and must not be reported as though it had.
		__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
	}

	/**
		Reports a failed statement both ways: as an `SQLErrorEvent`, and as
		the `SQLError` it throws. What the driver threw is carried as text,
		never as itself.
	**/
	@:noCompletion private function __fail(e:Dynamic):Void {
		var error:SQLError = SQLiteConnection.__asSQLError(SQLEvent.RESULT, e);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
	}

	/**
		`query` with `parameters` substituted. A parameter set to null is
		written as `NULL`, as MySQL's statements write it. It was taken for one
		never set and left as `:name`, which SQLite read as an unbound
		parameter, NULL as well, by luck rather than by design.
	**/
	@:noCompletion private function __applyParameters(query:String):String {
		var params:FieldStruct<String> = parameters;
		return ParamBinder.substituteWith(query, name -> FieldStruct.exists(params, name), name -> FieldStruct.get(params, name), __escapeValue,
			false);
	}

	@:noCompletion private function __escapeValue(value:Dynamic):String {
		return SQLiteConnection.__literal(value);
	}

	/**
		The work `execute()` queues on an asynchronous connection: runs the
		statement and reads its first page on the worker, then sends both to
		the runtime's thread.
	**/
	private function __executeAsync(sql:String, prefetch:Int, epoch:Int, connectionEpoch:Int):Void->Void {
		return function() {
			// Read here, on the worker, when the job runs: the connection the
			// worker opened.
			var connection:SQLiteConnection = __sqlConnection;
			connection.__letGo(__resultSet);
			__resultSet = null;
			connection.__settle();

			if (!__start(connection, epoch, connectionEpoch)) {
				return;
			}

			var message:SQLiteStatementMessage = new SQLiteStatementMessage(this, true, epoch);

			try {
				__resultSet = connection.__connection.request(sql);
				__resultEpoch = epoch;
				message.affected = __affectedOf(__resultSet);
				var rows:Array<Dynamic> = __readRows(__resultSet, prefetch);
				message.rows = prefetch != 0 ? rows : null;
				__finishPage(message);
				message.event = new SQLEvent(SQLEvent.RESULT);
			} catch (e:Dynamic) {
				__resultSet = null;
				message.fail(SQLiteConnection.__asSQLError(SQLEvent.RESULT, e));
			}

			connection.__leave();
			__notePaged(message);
			connection.__sqlWorker.sendProgress(message);
		}
	}

	/**
		On the worker, as work asked of the statement under its cancel count
		`epoch` and the connection's `connectionEpoch` is taken up: whether it
		runs. Dropped unheard when the statement's `cancel()` has been called
		since, and told it will not run, as the rest of the connection's work
		queued then is, when the connection's has.
	**/
	@:noCompletion private function __start(connection:SQLiteConnection, epoch:Int, connectionEpoch:Int):Bool {
		var verdict:Int = connection.__enter(this, epoch, connectionEpoch);

		if (verdict == SQLiteConnection.ENTER_CANCELLED) {
			connection.__refuseStatement(this, epoch);
		}

		return verdict == SQLiteConnection.ENTER_RUN;
	}

	/**
		On the worker: has the connection keep this statement in mind while
		rows of its result are unread, so that a `cancel()` lets go of them.
	**/
	@:noCompletion private function __notePaged(message:SQLiteStatementMessage):Void {
		if (!message.done) {
			__sqlConnection.__pagedStatement = this;
		} else if (__sqlConnection.__pagedStatement == this) {
			__sqlConnection.__pagedStatement = null;
		}
	}

	/** The connection's last rowid now, whole; see SQLiteConnection.__lastRowId. **/
	@:noCompletion private function __rowIdNow():Float {
		return __sqlConnection != null ? __sqlConnection.__lastRowId() : 0;
	}

	/**
		Takes the rowid for this statement's results, once its rows are all
		read, never while some remain. Past 2^31 the rowid is a query of its
		own, and hxcpp's glue starts one by finalizing the statement before
		it: read as soon as a SELECT had started, it cut the SELECT to the one
		row already stepped. A write has no rows, so its rowid is taken at
		once.
	**/
	@:noCompletion private function __noteRowId():Void {
		if (!__executing) {
			__rowId = __rowIdNow();
		}
	}

	/** On the worker: whether the page just read ended the rows, and the rowid then. **/
	@:noCompletion private function __finishPage(message:SQLiteStatementMessage):Void {
		message.done = __pageDone;

		if (__pageDone) {
			message.rowId = __rowIdNow();
		}
	}

	/**
		The rows a write changed: SQLite's own count for a statement with no
		result columns, and 0 for one that returns rows, as AIR's
		`SQLResult.rowsAffected` has it. Taken where the statement ran, before
		its rows are read. `getResult()` asked the result set its length,
		which for a SELECT stepped through the rest of its rows, on the
		caller's thread even on an asynchronous connection, and reported
		however many were left.
	**/
	@:noCompletion private static function __affectedOf(result:ResultSet):Float {
		return result.nfields == 0 ? result.length : 0;
	}

	/**
		Up to `prefetch` rows of `result`, all of them for `-1`, read on the
		thread running the statement, and made instances of `itemClass` when
		it is set. Sets `__pageDone` when none remain.
	**/
	@:noCompletion private function __readRows(result:ResultSet, prefetch:Int):Array<Dynamic> {
		var rows:Array<Dynamic> = [];

		if (prefetch == -1) {
			while (result.hasNext()) {
				rows.push(result.next());
			}

			__pageDone = true;
		} else if (prefetch > 0) {
			__pageDone = false;

			for (i in 0...prefetch) {
				if (!result.hasNext()) {
					__pageDone = true;
					break;
				}

				rows.push(result.next());
			}
		} else {
			__pageDone = !result.hasNext();
		}

		return ItemRows.make(rows, itemClass);
	}

	/**
		On the runtime's thread: what the worker read and ran, queued and
		reported here as a synchronous statement reports it.
	**/
	@:noCompletion private function __receive(message:SQLiteStatementMessage):Void {
		if (message.epoch != __cancels) {
			// Sent for work cancel() has stopped since: not heard, as AIR's
			// cancel() has it.
			return;
		}

		if (message.rows != null) {
			__resultQueue.push(message.rows);
		}

		if (message.executed) {
			__affected = message.affected;
			__rowId = 0;
		}

		if (message.done) {
			__executing = false;
			__rowId = message.rowId;
		}

		__dispatchEvent(message.event);
	}

	/**
		The oldest page not yet taken, or `null` when none is waiting. Pages
		come back in the order they were read, and only the last is
		`complete`.
	**/
	public function getResult():SQLResult {
		var results:Array<Dynamic> = __resultQueue.shift();
		// The last page is the one read as the rows ran out, with none behind
		// it. This was !__executing alone, which called every page still
		// waiting complete once the last had been read.
		var complete:Bool = !__executing && __resultQueue.length == 0;

		if (results != null) {
			return new SQLResult(results, __affected, complete, __rowId);
		}
		return null;
	}

	/**
		Queues the next `prefetch` rows, or all that remain with `-1`, then
		dispatches `SQLEvent.RESULT`, an empty page once none remain. A read
		that fails is reported as `execute()` reports one.
	**/
	public function next(prefetch:Int = -1):Void {
		var connection:SQLiteConnection = __sqlConnection;

		if (connection != null && connection.__async) {
			connection.__addToQueue(__nextAsync(prefetch, __cancels, connection.__cancelEpoch), SQLEvent.RESULT, this);
			return;
		}

		if (__resultSet == null) {
			// Thrown: it was made and dropped, so next() on a statement that
			// had not run did nothing at all, and said nothing.
			throw new SQLError(SQLEvent.RESULT, "Invalid result set", "Invalid result set: execute() the statement first");
		}

		if (connection != null) {
			connection.__enter(this, __cancels, connection.__cancelEpoch);
		}

		try {
			var rows:Array<Dynamic> = __readRows(__resultSet, prefetch);

			if (rows.length > 0) {
				__resultQueue.push(rows);
			}

			if (__pageDone) {
				__executing = false;
			}

			__noteRowId();
		} catch (e:Dynamic) {
			if (connection != null) {
				connection.__leave();
			}

			__executing = false;
			__fail(e);
		}

		if (connection != null) {
			connection.__leave();
		}

		__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
	}

	/** The work `next()` queues on an asynchronous connection: the next page, read on the worker. **/
	private function __nextAsync(prefetch:Int, epoch:Int, connectionEpoch:Int):Void->Void {
		return function() {
			var connection:SQLiteConnection = __sqlConnection;

			if (!__start(connection, epoch, connectionEpoch)) {
				return;
			}

			var message:SQLiteStatementMessage = new SQLiteStatementMessage(this, false, epoch);

			try {
				if (__resultSet == null) {
					throw new SQLError(SQLEvent.RESULT, "Invalid result set", "Invalid result set: execute() the statement first");
				}

				var rows:Array<Dynamic> = __readRows(__resultSet, prefetch);
				message.rows = rows.length > 0 ? rows : null;
				__finishPage(message);
				message.event = new SQLEvent(SQLEvent.RESULT);
			} catch (e:Dynamic) {
				message.fail(SQLiteConnection.__asSQLError(SQLEvent.RESULT, e));
			}

			connection.__leave();
			__notePaged(message);
			connection.__sqlWorker.sendProgress(message);
		}
	}

	private function get_executing():Bool {
		return __executing;
	}

	/**
		Only kept: whether the connection is open, and which way, is asked of
		it each time the statement runs. Both were copied here when this was
		set, so a statement given its connection before `open()`, or before
		an asynchronous open had finished, held no connection at all, and one
		kept across a `close()` and `open()` held the closed one.
	**/
	private function set_sqlConnection(value:SQLiteConnection):SQLiteConnection {
		return __sqlConnection = value;
	}

	private function get_sqlConnection():SQLiteConnection {
		return __sqlConnection;
	}
}
#end
