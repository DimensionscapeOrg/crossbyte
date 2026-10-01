package crossbyte.db.postgres;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.db.postgres._internal.PostgresWire;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql._internal.ItemRows;
import crossbyte.db.sql._internal.ParamBinder;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.errors.SQLError;
import crossbyte.FieldStruct;

/** Statement helper for executing PostgreSQL queries and paging result rows. */
typedef PostgresResultSet = Dynamic;

@:access(crossbyte.db.postgres.PostgresConnection)
class PostgresStatement extends EventDispatcher {
	public var executing(get, null):Bool;

	/**
		A class each row is made an instance of, as AIR's `itemClass`: made
		with no arguments, and each field set from the column of its name. A
		column the class has no field for fails the statement with an
		`SQLError`. Null, the default, leaves rows anonymous objects.
	**/
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
	// What the connection said of this statement as it ran: the rows it
	// changed or returned, and the OID of a row it inserted.
	@:noCompletion private var __affected:Float = 0;
	@:noCompletion private var __rowId:Float = 0;

	// Pages read and not yet taken by getResult(), oldest first. A statement
	// runs on the thread that calls it, so a plain Array serves every
	// target. It was a Deque on cpp and, elsewhere, an Array read with pop(),
	// which hands back the newest page first.
	@:noCompletion private var __resultQueue:Array<Array<Dynamic>> = [];

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
			__resultQueue = [];
			__resultSet = null;
			text = "";
			clearParameters();
		}
	}

	/**
		Runs `text`, with `parameters` substituted, and queues the first
		`prefetch` rows (all of them for `-1`) for `getResult()`, then
		dispatches `SQLEvent.RESULT`. A statement the server refuses is
		dispatched as an `SQLErrorEvent` and then thrown as its `SQLError`.
	**/
	public function execute(prefetch:Int = -1):Void {
		if (__connection == null) {
			throw "PostgresStatement: no connection set.";
		}
		__executing = true;
		__resultQueue = [];

		var query = __applyParameters(text);
		__prefetch = prefetch;

		try {
			__resultSet = __connection.request(query);
			__noteCounts();
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
		Reports a failed statement both ways, as MySQL's does: as the
		`SQLErrorEvent` it always was, and as the `SQLError` it now throws. It
		dispatched the event and returned, so to a caller not listening -- an
		`AsyncDatabase` task among them -- a failed statement read as one that
		had run. The detail is made a string here, where it is whatever the
		driver threw.
	**/
	@:noCompletion private function __fail(e:Dynamic):Void {
		var error:SQLError;
		if (Std.isOfType(e, SQLError)) {
			error = e;
		} else {
			var detail:String = Std.string(e);
			error = new SQLError(SQLEvent.RESULT, detail, "Execution failed: " + detail);
		}
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
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
		__resultQueue = [];

		__prefetch = prefetch;

		try {
			__resultSet = __toResultSet(__sqlConnection.requestParams(text, params));
			__noteCounts();
			__queueResult();
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__resultSet = null;
			__fail(e);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.RESULT));
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
		Takes the statement's counts from the connection as it runs, before
		another statement there replaces them. `rowsAffected` was the rows the
		result held -- 0 for every write -- and the connection's last OID was
		read as each page was taken.
	**/
	@:noCompletion private function __noteCounts():Void {
		var connection:PostgresConnection = __sqlConnection;
		__affected = connection != null ? connection.affectedRows : 0;
		__rowId = connection != null ? connection.lastInsertRowID : 0;
	}

	/**
		`query` with `parameters` substituted. A parameter set to null is
		written as `NULL`, as MySQL's statements write it; it was taken for one
		never set and left in the SQL as `:name`, which the server refused.
		Backslashes are not escapes in a PostgreSQL literal, with
		`standard_conforming_strings` on as it has been by default since 9.1,
		except in an `E'...'` string; and nothing inside a dollar-quoted
		string, `$$ ... $$`, is substituted.
	**/
	private function __applyParameters(query:String):String {
		var params:FieldStruct<String> = parameters;
		return ParamBinder.substituteWith(query, name -> FieldStruct.exists(params, name), name -> FieldStruct.get(params, name), __quoteValue,
			false, true);
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
					break;
				}
			}
			// Asked after the page as well as during it. The rows are all in
			// hand, so the page that takes the last of them can say so; asked
			// only when a page came up short, a result that divided evenly
			// into pages had none that was complete.
			if (!__resultSet.hasNext()) {
				__executing = false;
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

	/** Queues a page, its rows made instances of `itemClass` when it is set. **/
	@:noCompletion private inline function __push(rows:Array<Dynamic>):Void {
		__resultQueue.push(ItemRows.make(rows, itemClass));
	}
}

/**
 * The shape the statement result machinery expects, built from a bound result.
 * Kept here rather than reaching into the connection's own private one, which
 * exists for a different call path and is not this file's to depend on.
 */
private class BoundResultSet {
	public var length(default, null):Int;

	private var __rows:Array<Dynamic>;
	private var __index:Int = 0;

	public function new(rows:Array<Dynamic>) {
		__rows = rows == null ? [] : rows;
		length = __rows.length;
	}

	public function hasNext():Bool {
		return __index < __rows.length;
	}

	public function next():Dynamic {
		var out = __rows[__index];
		__index++;
		return out;
	}
}
#end
