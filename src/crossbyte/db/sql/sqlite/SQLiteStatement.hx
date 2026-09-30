package crossbyte.db.sql.sqlite;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.FieldStruct;
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
	private var __connection:Connection;
	private var __resultSet:ResultSet;
	private var __prefetch:Int = 0;
	// Pages read and not yet taken by getResult(), oldest first. The
	// asynchronous worker hands its result set back to the runtime thread,
	// which reads the rows and queues them, so only one thread touches it
	// and a plain Array serves every target. It was a Deque on cpp and,
	// elsewhere, an Array read with pop(), which hands back the newest page
	// first.
	private var __resultQueue:Array<Array<Dynamic>> = [];
	private var __async:Bool = false;

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

	public function execute(prefetch:Int = -1):Void {
		__executing = true;
		__resultQueue = [];

		var sql:String = __applyParameters(text);
		if (__async) {
			__sqlConnection.__addToQueue(__executeAsync(sql, this, prefetch));
		} else {
			__prefetch = prefetch;
			__resultSet = __connection.request(sql);
			__queueResult();
		}
	}

	@:noCompletion private function __applyParameters(query:String):String {
		var params:FieldStruct<String> = parameters;
		return ParamBinder.substitute(query, function(name:String):Null<Dynamic> {
			return FieldStruct.exists(params, name) ? FieldStruct.get(params, name) : null;
		}, __escapeValue);
	}

	@:noCompletion private function __escapeValue(value:Dynamic):String {
		var sb:StringBuf = new StringBuf();
		__connection.addValue(sb, value);
		return sb.toString();
	}

	private function __executeAsync(sql:String, statement:SQLiteStatement, prefetch:Int):Function {
		return function() {
			var event:Event;
			var results:ResultSet;
			try {
				results = __connection.request(sql);
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
			message.prefetch = prefetch;

			__sqlConnection.__sqlWorker.sendProgress(message);
		}
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
			var lastId:Int = (__connection != null) ? __connection.lastInsertId() : 0;
			return new SQLResult(results, len, complete, lastId);
		}
		return null;
	}

	public function next(prefetch:Int = -1):Void {
		if (__async) {
			__sqlConnection.__addToQueue(__nextAsync(this, prefetch));
		} else {
			if (__resultSet != null) {
				__prefetch = prefetch;

				if (__resultSet.hasNext()) {
					__queueResult();
				} else {
					__executing = false;
					__prefetch = 0;
				}
			} else {
				// Thrown: it was made and dropped, so next() on a statement that
				// had not run did nothing at all, and said nothing.
				throw new SQLError(SQLEvent.RESULT, "Invalid result set", "Invalid result set: execute() the statement first");
			}
		}
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

	private function set_sqlConnection(value:SQLiteConnection):SQLiteConnection {
		if (value != null) {
			__async = value.__async;
			__connection = value.__connection;
		} else {
			__connection = null;
			__async = false;
		}
		return __sqlConnection = value;
	}

	private function get_sqlConnection():SQLiteConnection {
		return __sqlConnection;
	}
}
#end
