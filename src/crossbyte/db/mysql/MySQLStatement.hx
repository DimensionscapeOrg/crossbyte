package crossbyte.db.mysql;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.errors.SQLError;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql._internal.ParamBinder;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import sys.db.Connection;
import sys.db.ResultSet;

#if cpp
import sys.thread.Deque;
#end

/** Statement helper for executing MySQL queries and paging result rows. */
@:access(crossbyte.db.mysql.MySQLConnection)
class MySQLStatement extends EventDispatcher {
	public var executing(get, null):Bool;
	public var itemClass:Class<Dynamic>;
	/**
		Named values substituted into `text` by `execute()`.

		Substituted, not bound: the value becomes part of the statement, so it is
		only as safe as `quote()` makes it and cannot carry a NUL byte — a blob
		written this way is truncated at its first zero with nothing reported.

		Unlike `PostgresStatement`, there is no bound alternative here: this driver
		runs on Haxe's `sys.db.Mysql`, whose `Connection` exposes `request`,
		`escape` and `quote` and no parameter binding at all. Binding would need a
		native libmysqlclient bridge of the kind the Postgres driver has.
	**/
	public var parameters(default, null):FieldStruct<String>;
	public var sqlConnection(get, set):MySQLConnection;
	public var text:String;

	private var __sqlConnection:MySQLConnection;
	private var __executing:Bool = false;
	private var __connection:Connection;
	private var __resultSet:ResultSet;
	private var __prefetch:Int = 0;

	#if cpp
	private var __resultQueue:Deque<Array<Dynamic>>;
	#else
	private var __resultQueue:Array<Array<Dynamic>>;
	#end

	public function new() {
		super();
		parameters = new FieldStruct();
	}

	public function clearParameters():Void {
		parameters = new FieldStruct();
	}

	public function cancel():Void {
		if (__executing) {
			__executing = false;
			__prefetch = 0;
			#if cpp
			__resultQueue = new Deque();
			#else
			__resultQueue = [];
			#end
			__resultSet = null;
			text = "";
			clearParameters();
		}
	}

	public function execute(prefetch:Int = -1):Void {
		if (__connection == null) {
			throw "MySQLStatement: no connection set.";
		}
		__executing = true;
		#if cpp
		__resultQueue = new Deque();
		#else
		__resultQueue = [];
		#end

		var sql:String = __applyParameters(text);

		__prefetch = prefetch;

		try {
			__resultSet = __connection.request(sql);
			__queueResult();
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, e, "Execution failed")));
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

	public function next(prefetch:Int = -1):Void {
		if (__resultSet == null) {
			throw "MySQL Error - invalid result set";
		}
		__prefetch = prefetch;

		if (__resultSet.hasNext()) {
			__queueResult();
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
		} else {
			__executing = false;
			__prefetch = 0;
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT)); // final empty tick
		}
	}

	public function getResult():SQLResult { // re-use your SQLiteResult container
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

	private function __queueResult():Void {
		var rows:Array<Dynamic> = [];
		if (__prefetch == -1) {
			while (__resultSet.hasNext()) {
				rows.push(__resultSet.next());
			}
			__push(rows);
			__executing = false;
		} else if (__prefetch > 0) {
			for (i in 0...__prefetch) {
				if (__resultSet.hasNext())
					rows.push(__resultSet.next());
				else {
					__executing = false;
					break;
				}
			}
			__push(rows);
		}

		__prefetch = 0;
	}

	@:noCompletion private inline function __push<T>(a:Array<T>):Void {
		#if cpp
		__resultQueue.add(a);
		#else
		__resultQueue.push(a);
		#end
	}

	private function get_executing():Bool {
		return __executing;
	}

	private function set_sqlConnection(v:MySQLConnection):MySQLConnection {
		__sqlConnection = v;
		if (v != null) {
			__connection = v.__connection;
		} else {
			__connection = null;
		}

		return v;
	}

	private function get_sqlConnection():MySQLConnection {
		return __sqlConnection;
	}
}
#end
