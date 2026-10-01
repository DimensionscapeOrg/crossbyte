package crossbyte.db.sql.sqlite;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.FieldStruct;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.SQLError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql._internal.ParamBinder;
import sys.db.Connection;
import sys.db.ResultSet;

/**
 * ...
 * @author Christopher Speciale
 */
@:access(crossbyte.db.sql.sqlite.SQLiteConnection)
class SQLiteStatement extends EventDispatcher {
	public var executing(get, null):Bool;
	public var itemClass:Class<Dynamic>;
	public var parameters(default, null):FieldStruct<String>;
	public var sqlConnection(get, set):SQLiteConnection;
	public var text:String;

	private var __sqlConnection:SQLiteConnection;
	private var __executing:Bool = false;
	private var __resultSet:ResultSet;
	private var __prefetch:Int = 0;
	// Pages read and not yet taken by getResult(), oldest first. The
	// asynchronous worker hands its result set back to the runtime thread,
	// which reads the rows and queues them, so only one thread touches it
	// and a plain Array serves every target. It was a Deque on cpp and,
	// elsewhere, an Array read with pop(), which hands back the newest page
	// first.
	private var __resultQueue:Array<Array<Dynamic>> = [];
	// The connection's last rowid as this statement finished executing,
	// read on the thread that executed it. It was read by getResult(), on
	// the caller's thread while the worker might be running the next
	// statement, and so reported whichever insert had happened last.
	@:noCompletion private var __rowId:Float = 0;

	public function new() {
		super();
		parameters = new FieldStruct();
	}

	public function cancel():Void {
		if (executing) {
			__executing = false;
			__prefetch = 0;
			__resultQueue = [];
			__resultSet = null;
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
			__sqlConnection.__addToQueue(__executeAsync(sql, this, prefetch));
			return;
		}

		__prefetch = prefetch;

		try {
			__resultSet = __sqlConnection.__connection.request(sql);
			__rowId = __rowIdNow();
			__queueResult();
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
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

	@:noCompletion private function __applyParameters(query:String):String {
		var params:FieldStruct<String> = parameters;
		return ParamBinder.substitute(query, function(name:String):Null<Dynamic> {
			return FieldStruct.exists(params, name) ? FieldStruct.get(params, name) : null;
		}, __escapeValue);
	}

	@:noCompletion private function __escapeValue(value:Dynamic):String {
		return SQLiteConnection.__literal(value);
	}

	private function __executeAsync(sql:String, statement:SQLiteStatement, prefetch:Int):Function {
		return function() {
			var event:Event;
			var results:ResultSet;
			var rowId:Float = 0;
			try {
				// Read here, on the worker, when the job runs: the connection
				// the worker opened. It was read once, when sqlConnection was
				// set, so a statement given its connection before the worker
				// had opened it held null.
				results = __sqlConnection.__connection.request(sql);
				rowId = __rowIdNow();
				event = new SQLEvent(SQLEvent.RESULT);
			} catch (e:Dynamic) {
				results = null;
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, Std.string(e), "Execution failed: " + Std.string(e)));
			}

			var message:Object = new Object();
			message.type = 0;
			message.statement = statement;
			message.event = event;
			message.results = results;
			message.rowId = rowId;
			message.prefetch = prefetch;

			__sqlConnection.__sqlWorker.sendProgress(message);
		}
	}

	/** The connection's last rowid now, whole; see SQLiteConnection.__lastRowId. **/
	@:noCompletion private function __rowIdNow():Float {
		return __sqlConnection != null ? __sqlConnection.__lastRowId() : 0;
	}

	private function __queueResult():Void {
		var results:Array<Dynamic> = [];

		if (__prefetch == -1) {
			while (__resultSet.hasNext()) {
				results.push(__resultSet.next());
			}
			__resultQueuePush(results);
			__executing = false;
		} else if (__prefetch > 0) {
			for (i in 0...__prefetch) {
				if (__resultSet.hasNext()) {
					results.push(__resultSet.next());
				} else {
					__executing = false;
					break;
				}
			}
			__resultQueuePush(results);
		}
		__prefetch = 0;
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
			var len:Int = (__resultSet != null) ? __resultSet.length : 0;
			return new SQLResult(results, len, complete, __rowId);
		}
		return null;
	}

	/**
		Queues the next `prefetch` rows, or all that remain with `-1`, then
		dispatches `SQLEvent.RESULT` -- an empty page once none remain. A read
		that fails is reported as `execute()` reports one.
	**/
	public function next(prefetch:Int = -1):Void {
		if (__sqlConnection != null && __sqlConnection.__async) {
			__sqlConnection.__addToQueue(__nextAsync(this, prefetch));
			return;
		}

		if (__resultSet == null) {
			// Thrown: it was made and dropped, so next() on a statement that
			// had not run did nothing at all, and said nothing.
			throw new SQLError(SQLEvent.RESULT, "Invalid result set", "Invalid result set: execute() the statement first");
		}

		__prefetch = prefetch;

		try {
			if (__resultSet.hasNext()) {
				__queueResult();
			} else {
				__executing = false;
				__prefetch = 0;
			}
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__fail(e);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
	}

	private function __nextAsync(statement:SQLiteStatement, prefetch:Int):Function {
		return function() {
			var event:Event;
			var results:ResultSet;
			var isExecuting:Bool = false;

			try {
				if (__resultSet != null) {
					var hasNext:Bool = __resultSet.hasNext();

					if (hasNext) {
						isExecuting = true;
					} else {
						prefetch = 0;
					}
				}
				event = new SQLEvent(SQLEvent.RESULT);
			} catch (e:Dynamic) {
				isExecuting = false;
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, Std.string(e), "Execution failed: " + Std.string(e)));
			}

			var message:Object = new Object();
			message.type = 1;
			message.statement = statement;
			message.event = event;
			message.prefetch = prefetch;
			message.executing = isExecuting;

			__sqlConnection.__sqlWorker.sendProgress(message);
		}
	}

	@:noCompletion private inline function __resultQueuePush(rows:Array<Dynamic>):Void {
		__resultQueue.push(rows);
	}

	private function get_executing():Bool {
		return __executing;
	}

	/**
		Only kept: whether the connection is open, and which way, is asked of
		it each time the statement runs. Both were copied here when this was
		set -- so a statement given its connection before `open()`, or before
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
