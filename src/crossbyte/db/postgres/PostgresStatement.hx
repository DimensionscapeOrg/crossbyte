package crossbyte.db.postgres;

import crossbyte.db.postgres._internal.PostgresWire;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql._internal.ParamBinder;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.errors.SQLError;
import crossbyte.FieldStruct;
#if cpp
import sys.thread.Deque;
#end

/** Statement helper for executing PostgreSQL queries and paging result rows. */
typedef PostgresResultSet = Dynamic;

@:access(crossbyte.db.postgres.PostgresConnection)
class PostgresStatement extends EventDispatcher {
	public var executing(get, null):Bool;
	public var itemClass:Class<Dynamic>;
	/**
		Named values substituted into `text` by `execute()`.

		Substituted, not bound: the value becomes part of the statement, so it
		is only ever as safe as `quote()` makes it, and no quoting can carry a
		NUL byte — a blob written this way is truncated at its first zero with
		nothing reported. Use `executeParams()` for anything carrying data that
		did not come from your own source code.
	**/
	public var parameters(default, null):FieldStruct<String>;
	public var sqlConnection(get, set):PostgresConnection;
	public var text:String;

	@:noCompletion private var __sqlConnection:PostgresConnection;
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
			throw "PostgresStatement: no connection set.";
		}
		__executing = true;
		#if cpp
		__resultQueue = new Deque();
		#else
		__resultQueue = [];
		#end

		var query = __applyParameters(text);
		__prefetch = prefetch;

		try {
			__resultSet = __connection.request(query);
			__queueResult();
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, e, "Execution failed")));
		}
	}

	/**
		Runs `text` with bound positional parameters, referenced as `$1`, `$2`
		and so on, and reports results exactly as `execute()` does.

		This is the path for values carrying data. `execute()` substitutes its
		named `parameters` into the statement text, which cannot express a NUL
		byte and leaves correctness resting on quoting; bound values never enter
		the statement at all.

		Text results keep the same contract as `execute()`: values arrive as
		strings. A `bytea` column therefore arrives as its exact `\x` hex
		rendering, which `PostgresWire.decodeByteaHex` turns back into bytes.

		```haxe
		statement.text = "INSERT INTO events (id, payload) VALUES ($1, $2)";
		statement.executeParams([Text(Std.string(id)), Binary(ciphertext)]);
		```
	**/
	public function executeParams(params:Array<PostgresParameter>, prefetch:Int = -1):Void {
		if (__connection == null) {
			throw "PostgresStatement: no connection set.";
		}

		__executing = true;
		#if cpp
		__resultQueue = new Deque();
		#else
		__resultQueue = [];
		#end

		__prefetch = prefetch;

		try {
			__resultSet = __toResultSet(__sqlConnection.requestParams(text, params));
			__queueResult();
			__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(SQLEvent.RESULT, e, "Execution failed")));
		}
	}

	// Bound results arrive as fields and rows of bytes; the statement API hands
	// back row objects, so they are rebuilt here rather than in the connection,
	// which has no opinion about shape.
	@:noCompletion private function __toResultSet(result:crossbyte.db.postgres._internal.PostgresWire.PostgresRawResult):Dynamic {
		var rows:Array<Dynamic> = [];

		for (row in result.rows) {
			var object:Dynamic = {};

			for (i in 0...result.fields.length) {
				var value = row[i];
				Reflect.setField(object, result.fields[i], value == null ? null : value.toString());
			}

			rows.push(object);
		}

		return new BoundResultSet(rows);
	}

	public function next(prefetch:Int = -1):Void {
		if (__resultSet == null) {
			throw "PostgreSQL Error - invalid result set";
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

	private function __applyParameters(query:String):String {
		var params:FieldStruct<String> = parameters;
		return ParamBinder.substitute(query, function(name:String):Null<Dynamic> {
			return FieldStruct.exists(params, name) ? FieldStruct.get(params, name) : null;
		}, __quoteValue);
	}

	private function __quoteValue(value:Dynamic):String {
		if (value == null) {
			return "NULL";
		}

		if (Std.isOfType(value, Bool)) {
			return value ? "TRUE" : "FALSE";
		}

		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			return Std.string(value);
		}

		return __sqlConnection != null ? __sqlConnection.quote(Std.string(value)) : ("'" + Std.string(value).split("'").join("''") + "'");
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

	private function set_sqlConnection(v:PostgresConnection):PostgresConnection {
		__sqlConnection = v;
		if (v != null) {
			__connection = v;
		} else {
			__connection = null;
		}
		return v;
	}

	private function get_sqlConnection():PostgresConnection {
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
