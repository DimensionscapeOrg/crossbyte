package crossbyte.db.mysql;

import crossbyte.errors.SQLError;
import crossbyte.db.sql.SQLResult;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import sys.db.Connection;
import sys.db.ResultSet;

#if cpp
import sys.thread.Deque;
#end

@:access(crossbyte.db.mysql.MySQLConnection)
class MySQLStatement extends EventDispatcher {
	public var executing(get, null):Bool;
	public var itemClass:Class<Dynamic>;
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

		for (p in FieldStruct.iterator(parameters)) {
			var sb:StringBuf = new StringBuf();
			sb.add(p.key);
			__connection.addValue(sb, p.value);
		}

		__prefetch = prefetch;

		try {
			__resultSet = __connection.request(text);
			__queueResult();
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, e, "Execution failed")));
		}
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
