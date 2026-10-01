package crossbyte.db.mysql;

// Not built for any JavaScript target (Node included, which has no threads): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.errors.ArgumentError;
import crossbyte.errors.SQLError;
import crossbyte.db.sql.SQLResult;
import crossbyte.db.sql._internal.ItemRows;
import crossbyte.db.sql._internal.ParamBinder;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import sys.db.Connection;
import sys.db.ResultSet;

/** Statement helper for executing MySQL queries and paging result rows. */
@:access(crossbyte.db.mysql.MySQLConnection)
class MySQLStatement extends EventDispatcher {
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
		written as the MySQL literal for its type:

		- `null` as `NULL`, where the placeholder used to stay in the SQL;
		- `Int`, `Float` and `haxe.Int64` as numbers, so `LIMIT :n` works,
		  a number went out quoted, and MySQL refuses `LIMIT '50'`; a `Float`
		  that is NaN or infinite has no literal and throws `ArgumentError`;
		- `Bool` as `TRUE` or `FALSE`;
		- `haxe.io.Bytes` as a hex literal, `X'00ff...'`, which carries a NUL
		  byte, where a string is cut at its first one;
		- `Date` as its UTC fields, on every target. Natively the client reads
		  `DATETIME` columns back as UTC too, so a `Date` makes the round
		  trip. Haxe's drivers elsewhere do not: on hl and neko a `DATETIME`
		  comes back in local time, shifted by the local offset from UTC
		  unless the process runs in UTC, and on the jvm Haxe's JDBC binding
		  makes a `Date` of `DATE` and `TIME` columns only, leaving a
		  `DATETIME` the JDBC driver's own value;
		- anything else as a string, quoted by the connection's `quote()`,
		  which follows the session's `NO_BACKSLASH_ESCAPES`.

		Substituted, not bound: the text is scanned for placeholders outside
		literals, identifiers and comments, with backslash escapes read as
		the session reads them, and the value spliced in. There is no bound
		alternative: the client speaks the text protocol only.
	**/
	public var parameters(default, null):FieldStruct<Dynamic>;
	public var sqlConnection(get, set):MySQLConnection;
	public var text:String;

	private var __sqlConnection:MySQLConnection;
	private var __executing:Bool = false;
	private var __connection:Connection;
	private var __resultSet:ResultSet;
	private var __prefetch:Int = 0;

	// Pages read and not yet taken by getResult(), oldest first. Only the
	// thread running the statement touches it, so a plain Array serves every
	// target. It was a Deque on cpp and, elsewhere, an Array read with pop(),
	// which hands back the newest page first.
	private var __resultQueue:Array<Array<Dynamic>> = [];

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
		Runs `text` and queues the first `prefetch` rows (all of them for
		`-1`) for `getResult()`, then dispatches `SQLEvent.RESULT`.

		A statement the server refuses throws an `SQLError`, after dispatching
		it as an `SQLErrorEvent` too. It used to dispatch the event and return,
		so to a caller not listening, an `AsyncDatabase` task among them, a
		failed INSERT read as one that had run.
	**/
	public function execute(prefetch:Int = -1):Void {
		if (__live() == null) {
			throw "MySQLStatement: no connection set.";
		}

		// Before anything changes: a parameter with no literal (a NaN) throws
		// an ArgumentError, and the statement is then simply not run.
		var sql:String = __applyParameters(text);

		__executing = true;
		__resultQueue = [];
		__prefetch = prefetch;

		try {
			// Read as the rows are asked for: a page of a million-row result
			// no longer waits for, and holds, all million.
			__resultSet = __sqlConnection != null ? __sqlConnection.__requestStream(sql) : __live().request(sql);
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
		Reports a failed statement both ways: as the `SQLErrorEvent` it always
		was, and as the `SQLError` it now throws. The detail is made a string
		here, where it is known to be whatever the driver threw, on the jvm a
		`java.sql.SQLException`, which `SQLError` took where it expects a
		`String` and turned into a `ClassCastException`.
	**/
	@:noCompletion private function __fail(e:Dynamic):Void {
		var detail:String = Std.string(e);
		var code:Int = 0;
		var state:String = "HY000";

		if (Std.isOfType(e, MySQLError)) {
			var cause:MySQLError = e;
			detail = cause.details();
			code = cause.code;
			state = cause.sqlState;
		}

		var error:MySQLError = new MySQLError(SQLEvent.RESULT, detail, "Execution failed: " + detail, code, state);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
	}

	@:noCompletion private function __applyParameters(query:String):String {
		var params:FieldStruct<Dynamic> = parameters;
		// MySQL's default is backslash escapes on, and the scan is safe that
		// way round: reading an escape the server does not honour leaves a
		// placeholder unsubstituted, a loud failure, where missing one it does
		// honour substitutes inside what the server reads as a literal.
		var backslashes:Bool = __sqlConnection != null ? __sqlConnection.__backslashEscapes() : true;

		return ParamBinder.substituteWith(query, name -> FieldStruct.exists(params, name), name -> FieldStruct.get(params, name), __literal,
			backslashes);
	}

	/** A parameter's value as a MySQL literal; see `parameters`. **/
	@:noCompletion private function __literal(value:Dynamic):String {
		if (value == null) {
			return "NULL";
		}

		if (Std.isOfType(value, Bool)) {
			return value ? "TRUE" : "FALSE";
		}

		if (Std.isOfType(value, Int)) {
			return Std.string(value);
		}

		// Before Float: an Int64 passes for one on cpp and the jvm, and
		// printed as a Float it loses everything past 2^53.
		if (haxe.Int64.isInt64(value)) {
			var wide:haxe.Int64 = value;
			return haxe.Int64.toStr(wide);
		}

		if (Std.isOfType(value, Float)) {
			var number:Float = value;

			if (Math.isNaN(number) || !Math.isFinite(number)) {
				throw new ArgumentError("MySQL has no literal for " + number);
			}

			return Std.string(number);
		}

		if (Std.isOfType(value, haxe.io.Bytes)) {
			var bytes:haxe.io.Bytes = value;
			return "X'" + bytes.toHex() + "'";
		}

		if (Std.isOfType(value, Date)) {
			return "'" + __utc(value) + "'";
		}

		return __quote(Std.string(value));
	}

	@:noCompletion private function __quote(text:String):String {
		if (__sqlConnection != null) {
			return __sqlConnection.quote(text);
		}

		return __connection.quote(text);
	}

	/** `YYYY-MM-DD hh:mm:ss[.mmm]`, in UTC. **/
	@:noCompletion private static function __utc(date:Date):String {
		var time:Float = date.getTime();
		var millis:Int = Std.int(((time % 1000.0) + 1000.0) % 1000.0);
		var text:String = date.getUTCFullYear() + "-" + __two(date.getUTCMonth() + 1) + "-" + __two(date.getUTCDate()) + " "
			+ __two(date.getUTCHours()) + ":" + __two(date.getUTCMinutes()) + ":" + __two(date.getUTCSeconds());

		if (millis != 0) {
			text += "." + StringTools.lpad(Std.string(millis), "0", 3);
		}

		return text;
	}

	@:noCompletion private static inline function __two(n:Int):String {
		return n < 10 ? "0" + n : Std.string(n);
	}

	public function next(prefetch:Int = -1):Void {
		if (__resultSet == null) {
			throw "MySQL Error - invalid result set";
		}
		__prefetch = prefetch;

		var more:Bool;

		// The rows come from the server as they are asked for, so reading
		// them can fail as a statement does, the connection lost part way.
		try {
			more = __resultSet.hasNext();

			if (more) {
				__queueResult();
			}
		} catch (e:Dynamic) {
			__executing = false;
			__prefetch = 0;
			__fail(e);
			return;
		}

		if (!more) {
			__executing = false;
			__prefetch = 0;
		}

		__dispatchEvent(new SQLEvent(SQLEvent.RESULT)); // the final one empty
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
			// From the statement's answer. This was a SELECT LAST_INSERT_ID()
			// on every call, a round trip per page, after which the
			// connection's affectedRows read as that SELECT's.
			var lastId:Float = __sqlConnection != null ? __sqlConnection.__insertIdFloat() : (__connection != null ? __connection.lastInsertId() : 0);

			return new SQLResult(results, len, complete, lastId);
		}
		return null;
	}

	private function __queueResult():Void {
		var rows:Array<Dynamic> = [];
		if (__resultSet == null) {
			// Nothing to read: a driver that answers a write with no result
			// set at all rather than an empty one.
			__push(rows);
			__executing = false;
		} else if (__prefetch == -1) {
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

	/** Queues a page, its rows made instances of `itemClass` when it is set. **/
	@:noCompletion private inline function __push(rows:Array<Dynamic>):Void {
		__resultQueue.push(ItemRows.make(rows, itemClass));
	}

	private function get_executing():Bool {
		return __executing;
	}

	/**
		The connection's handle as it is now. It was copied when
		`sqlConnection` was set, so a statement given its connection before
		`open()` held none and refused to run, as SQLite's did.
	**/
	@:noCompletion private inline function __live():Connection {
		return __sqlConnection != null ? __sqlConnection.__connection : __connection;
	}

	private function set_sqlConnection(v:MySQLConnection):MySQLConnection {
		__sqlConnection = v;
		// Kept for a statement given a handle directly, as tests do; with a
		// connection set, its handle is asked for each time instead.
		__connection = v != null ? v.__connection : null;
		return v;
	}

	private function get_sqlConnection():MySQLConnection {
		return __sqlConnection;
	}
}
#end
