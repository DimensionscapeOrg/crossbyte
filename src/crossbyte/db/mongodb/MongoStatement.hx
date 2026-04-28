package crossbyte.db.mongodb;

import crossbyte.FieldStruct;
import crossbyte.db.sql.SQLResult;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.errors.SQLError;
#if cpp
import sys.thread.Deque;
#end

typedef MongoResultSet = Dynamic;

@:access(crossbyte.db.mongodb.MongoConnection)
class MongoStatement extends EventDispatcher {
	public var executing(get, null):Bool;
	public var itemClass:Class<Dynamic>;
	public var parameters(default, null):FieldStruct<String>;
	public var sqlConnection(get, set):MongoConnection;
	public var text:String;

	@:noCompletion private var __sqlConnection:MongoConnection;
	@:noCompletion private var __connection:Dynamic;
	@:noCompletion private var __resultSet:Dynamic;
	@:noCompletion private var __prefetch:Int = 0;
	@:noCompletion private var __executing:Bool = false;

	#if cpp
	@:noCompletion private var __resultQueue:Deque<Array<Dynamic>>;
	#else
	@:noCompletion private var __resultQueue:Array<Array<Dynamic>>;
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
			throw "MongoStatement: no connection set.";
		}
		__executing = true;

		#if cpp
		__resultQueue = new Deque();
		#else
		__resultQueue = [];
		#end

		var payload = __resolvePayload(text);
		__prefetch = prefetch;

		try {
			__resultSet = __connection.request(payload);
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
			throw "MongoDB Error - invalid result set";
		}
		__prefetch = prefetch;

		if (__resultSet.hasNext()) {
			__queueResult();
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
		} else {
			__executing = false;
			__prefetch = 0;
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
		}
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
			var lastId:Int = (__sqlConnection != null) ? __sqlConnection.lastInsertRowID : 0;

			return new SQLResult(results, len, complete, lastId);
		}
		return null;
	}

	private function __resolvePayload(source:String):String {
		var payload:String = source == null ? "" : source;

		for (parameter in FieldStruct.iterator(parameters)) {
			payload = StringTools.replace(payload, ":" + parameter.key, __quoteValue(parameter.value));
		}

		return payload;
	}

	private function __quoteValue(value:Dynamic):String {
		if (value == null) {
			return "null";
		}
		if (Std.isOfType(value, Bool)) {
			return value ? "true" : "false";
		}
		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			return Std.string(value);
		}
		var s:String = Std.string(value);
		s = s.split("\\").join("\\\\");
		s = s.split("\"").join("\\\"");
		return "\"" + s + "\"";
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
				if (__resultSet.hasNext()) {
					rows.push(__resultSet.next());
				} else {
					__executing = false;
					break;
				}
			}
			__push(rows);
		}

		__prefetch = 0;
	}

	private function get_executing():Bool {
		return __executing;
	}

	private function set_sqlConnection(v:MongoConnection):MongoConnection {
		__sqlConnection = v;
		if (v != null) {
			__connection = v;
		} else {
			__connection = null;
		}
		return v;
	}

	private function get_sqlConnection():MongoConnection {
		return __sqlConnection;
	}

	@:noCompletion private inline function __push<T>(a:Array<T>):Void {
		#if cpp
		__resultQueue.add(a);
		#else
		__resultQueue.push(a);
		#end
	}
}
