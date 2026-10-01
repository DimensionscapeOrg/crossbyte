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

	public function new() {
		super();
		parameters = new FieldStruct();
	}

	public function cancel():Void {
		if (executing) {
			__executing = false;
			__resultQueue = [];

			// The worker's, on an asynchronous connection: left for the next
			// execute() to replace there.
			if (__sqlConnection == null || !__sqlConnection.__async) {
				__resultSet = null;
			}

			text = "";
			clearParameters();
		}
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

		if (__sqlConnection.__async) {
			__sqlConnection.__addToQueue(__executeAsync(sql, prefetch), SQLEvent.RESULT, this);
			return;
		}

		__rowId = 0;

		try {
			__resultSet = __sqlConnection.__connection.request(sql);
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
			__executing = false;
			__resultSet = null;
			__fail(e);
		}

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
	private function __executeAsync(sql:String, prefetch:Int):Void->Void {
		return function() {
			var message:SQLiteStatementMessage = new SQLiteStatementMessage(this, true);

			try {
				__resultSet = null;
				// Read here, on the worker, when the job runs: the connection
				// the worker opened.
				__resultSet = __sqlConnection.__connection.request(sql);
				message.affected = __affectedOf(__resultSet);
				var rows:Array<Dynamic> = __readRows(__resultSet, prefetch);
				message.rows = prefetch != 0 ? rows : null;
				__finishPage(message);
				message.event = new SQLEvent(SQLEvent.RESULT);
			} catch (e:Dynamic) {
				__resultSet = null;
				message.fail(SQLiteConnection.__asSQLError(SQLEvent.RESULT, e));
			}

			__sqlConnection.__sqlWorker.sendProgress(message);
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
		if (__sqlConnection != null && __sqlConnection.__async) {
			__sqlConnection.__addToQueue(__nextAsync(prefetch), SQLEvent.RESULT, this);
			return;
		}

		if (__resultSet == null) {
			// Thrown: it was made and dropped, so next() on a statement that
			// had not run did nothing at all, and said nothing.
			throw new SQLError(SQLEvent.RESULT, "Invalid result set", "Invalid result set: execute() the statement first");
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
			__executing = false;
			__fail(e);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
	}

	/** The work `next()` queues on an asynchronous connection: the next page, read on the worker. **/
	private function __nextAsync(prefetch:Int):Void->Void {
		return function() {
			var message:SQLiteStatementMessage = new SQLiteStatementMessage(this, false);

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

			__sqlConnection.__sqlWorker.sendProgress(message);
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
