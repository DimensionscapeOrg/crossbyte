package crossbyte.db.postgres;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.db.postgres._internal.PostgresWire;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql._internal.ItemRows;
import crossbyte.db.sql._internal.ParamBinder;
import crossbyte.db.sql._internal.ParamBinder.ParamTemplate;
import crossbyte.db.sql.SQLRow;
import crossbyte.db.sql.SQLValue;
import sys.db.ResultSet;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.errors.SQLError;
import crossbyte.FieldStruct;

/** Statement helper for executing PostgreSQL queries and paging result rows. */
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
		Named values substituted into `text` by `execute()`, as `:name`, each
		written as the PostgreSQL literal for its type (see `SQLValue`): `NULL`,
		`TRUE`/`FALSE`, a number, a `bytea` hex literal for `Bytes`, an ISO
		8601 UTC timestamp for a `Date`, and a `String` quoted.

		Substituted, not bound: the value becomes part of the statement, so it
		is only ever as safe as `quote()` makes it, and no quoting can carry a
		NUL byte: a blob written this way is truncated at its first zero with
		nothing reported. Use `executeParams()` for anything carrying data that
		did not come from your own source code.
	**/
	public var parameters(default, null):FieldStruct<SQLValue>;
	public var sqlConnection(get, set):PostgresConnection;
	public var text:String;

	@:noCompletion private var __sqlConnection:PostgresConnection;
	@:noCompletion private var __connection:Dynamic;
	// Any object with request() serves, as tests script one; the rows it
	// answers are read through ResultSet, not by name.
	@:noCompletion private var __resultSet:ResultSet;
	// `text` split at its placeholders, kept while it stays the same.
	@:noCompletion private var __template:ParamTemplate;
	@:noCompletion private var __prefetch:Int = 0;
	@:noCompletion private var __executing:Bool = false;
	// What the connection said of this statement as it ran: the rows it
	// changed or returned, and the OID of a row it inserted.
	@:noCompletion private var __affected:Float = 0;
	@:noCompletion private var __rowId:Float = 0;

	// Pages read and not yet taken by getResult(), oldest first. A statement
	// runs on the thread that calls it, so a plain Array serves every
	// target.
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
		`SQLErrorEvent`, and as the `SQLError` it throws, so to a caller not
		listening (an `AsyncDatabase` task among them) a failed statement
		does not read as one that had run. The detail is made a string here,
		where it is whatever the driver threw.
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
	@:noCompletion private function __toResultSet(result:PostgresRawResult):PostgresResultSet {
		var rows:Array<Dynamic> = [];
		var fieldCount:Int = result.fields.length;
		// Made with fixed slots, as request()'s rows are.
		var shape:crossbyte._internal.AnonBuilder = crossbyte._internal.AnonBuilder.recent(__shapes, result.fields);

		for (row in result.rows) {
			var object:Dynamic = shape.begin();

			for (i in 0...fieldCount) {
				var value = row[i];

				if (value == null) {
					shape.set(object, i, null);
				} else {
					shape.setString(object, i, value.toString());
				}
			}

			rows.push(object);
		}

		return new PostgresResultSet(rows, result.fields);
	}

	// The row shapes executeParams() has met lately.
	@:noCompletion private var __shapes:Array<crossbyte._internal.AnonBuilder> = [];

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
		// it.
		var complete:Bool = !__executing && __resultQueue.length == 0;

		if (results != null) {
			return new SQLResult(results, __affected, complete, __rowId);
		}
		return null;
	}

	/**
		Takes the statement's counts from the connection as it runs, before
		another statement there replaces them.
	**/
	@:noCompletion private function __noteCounts():Void {
		var connection:PostgresConnection = __sqlConnection;
		__affected = connection != null ? connection.affectedRows : 0;
		__rowId = connection != null ? connection.lastInsertRowID : 0;
	}

	/**
		`query` with `parameters` substituted. A parameter set to null is
		written as `NULL`, as MySQL's statements write it.
		Backslashes are not escapes in a PostgreSQL literal, with
		`standard_conforming_strings` on as it has been by default since 9.1,
		except in an `E'...'` string; and nothing inside a dollar-quoted
		string, `$$ ... $$`, is substituted.
	**/
	private function __applyParameters(query:String):String {
		var template:ParamTemplate = __template;

		if (template == null || !template.matches(query, false, true)) {
			template = __template = ParamTemplate.parse(query, false, true);
		}

		return template.renderMap(cast parameters, __quoteValue);
	}

	private function __quoteValue(value:Dynamic):String {
		if (value == null) {
			return "NULL";
		}

		if (Std.isOfType(value, Bool)) {
			return value ? "TRUE" : "FALSE";
		}

		// Before Int: an Int64 held in a Dynamic passes for one on cpp and the
		// jvm, and printed as a Float loses what is past 2^53.
		if (__isInt64(value)) {
			return haxe.Int64.toStr(value);
		}

		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			var number:Float = value;

			if (Math.isNaN(number) || !Math.isFinite(number)) {
				// PostgreSQL spells these as quoted words.
				return Math.isNaN(number) ? "'NaN'" : (number > 0 ? "'Infinity'" : "'-Infinity'");
			}

			return Std.string(value);
		}

		if (Std.isOfType(value, haxe.io.Bytes)) {
			// A bytea's hex input, exact for any byte, NUL included.
			return "'" + PostgresWire.encodeByteaHex(value) + "'";
		}

		if (Std.isOfType(value, Date)) {
			return "'" + __utc(value) + "'";
		}

		return __sqlConnection != null ? __sqlConnection.quote(Std.string(value)) : ("'" + Std.string(value).split("'").join("''") + "'");
	}

	/** Whether `value` is an `Int64`, and not an `Int` that converts to one. **/
	@:noCompletion private static inline function __isInt64(value:Dynamic):Bool {
		#if cpp
		return value != null && (untyped __cpp__("{0}->__GetType() == vtInt64", value) : Bool);
		#else
		return !Std.isOfType(value, Int) && haxe.Int64.isInt64(value);
		#end
	}

	/** `YYYY-MM-DDThh:mm:ss.mmmZ`: a `Date` as an ISO 8601 UTC timestamp. **/
	@:noCompletion private static function __utc(date:Date):String {
		var time:Float = date.getTime();
		var millis:Int = Std.int(((time % 1000.0) + 1000.0) % 1000.0);
		return date.getUTCFullYear() + "-" + __pad(date.getUTCMonth() + 1, 2) + "-" + __pad(date.getUTCDate(), 2) + "T" + __pad(date.getUTCHours(), 2)
			+ ":" + __pad(date.getUTCMinutes(), 2) + ":" + __pad(date.getUTCSeconds(), 2) + "." + __pad(millis, 3) + "Z";
	}

	@:noCompletion private static inline function __pad(value:Int, width:Int):String {
		return StringTools.lpad(Std.string(value), "0", width);
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
			// hand, so the page that takes the last of them can say so, even
			// when a result divides evenly into pages.
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
		__resultQueue.push(ItemRows.make(rows, itemClass, true));
	}

	/**
		Runs `text`, with `parameters` substituted, and hands each row of its
		result to `each`, as an `SQLRow` that reads the row by column from what
		the server sent: one object for the whole result, moved on to each row
		in turn, none made for a row, and no text made for a value until it is
		asked for. A row is valid inside the call only. Answers the rows the
		statement changed, 0 for one that returns rows; nothing is queued,
		and no `SQLEvent.RESULT` is dispatched.

		Values are the text PostgreSQL sends: `getInt` and `getFloat` parse it,
		`getBool` reads `t` as true, and `getBytes` decodes a `bytea`'s `\x`
		hex.

		Needs the native driver.

		@throws SQLError When the server refuses the statement, as `execute()`
		throws, after dispatching it as an `SQLErrorEvent`. What `each`
		throws ends the run and is thrown as it is.
	**/
	public function executeEach(each:SQLRow->Void):Float {
		if (__sqlConnection == null) {
			throw "PostgresStatement: no connection set.";
		}

		#if cpp
		var query:String = __applyParameters(text);
		var block:haxe.io.Bytes = null;

		try {
			__sqlConnection.__requireConnected();

			if (!__sqlConnection.__autocommit && !__sqlConnection.__inTransaction) {
				__sqlConnection.__beginImplicitly();
			}

			block = __sqlConnection.__requestBlock(query);
		} catch (e:Dynamic) {
			__fail(e);
		}

		try {
			// The server's refusal, raised before any row is read.
			PostgresWire.check(block);
		} catch (e:Dynamic) {
			__fail(e);
		}

		return PostgresWire.eachRow(block, each);
		#else
		throw new crossbyte.errors.IllegalOperationError("PostgresStatement.executeEach needs the native driver.");
		#end
	}
}
#end
