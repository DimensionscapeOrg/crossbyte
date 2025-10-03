package crossbyte.db.sql.sqlite;

import crossbyte.errors.SQLError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.db.sql.SQLResult;
import sys.db.Connection;
import sys.db.ResultSet;
#if cpp
import sys.thread.Deque;
#end

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
	#if cpp
	private var __resultQueue:Deque<Array<Dynamic>>;
	#else
	private var __resultQueue:Array<Array<Dynamic>>;
	#end
	private var __async:Bool = false;

	public function new() {
		super();
		parameters = new FieldStruct();
	}

	public function cancel():Void {
		if (executing) {
			__executing = false;
			__prefetch = 0;
			#if cpp
			__resultQueue = new Deque();
			#else
			__resultQueue = new Array();
			#end
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
		#if cpp
		__resultQueue = new Deque();
		#else
		__resultQueue = new Array();
		#end

		for (parameter in FieldStruct.iterator(parameters)) {
			var sb:StringBuf = new StringBuf();
			sb.add(parameter.key);
			__connection.addValue(sb, parameter.value);
		}
		if (__async) {
			__sqlConnection.__addToQueue(__executeAsync(text, this, prefetch));
		} else {
			__prefetch = prefetch;
			__resultSet = __connection.request(text);
			__queueResult();
		}
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
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, "Execution failed"));
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

	public function getResult():SQLResult {
		#if cpp
		var results = __resultQueue.pop(false);
		#else
		var results = __resultQueue.pop();
		#end

		var complete:Bool = !__executing;

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
				new SQLError(SQLEvent.RESULT, "Invalid result set");
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
				event = new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, "Execution failed"));
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

	@:noCompletion private inline function __resultQueuePush<T>(a:Array<T>):Void {
		#if cpp
		__resultQueue.add(a);
		#else
		__resultQueue.push(a);
		#end
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
