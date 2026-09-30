package crossbyte.db.sql.sqlite._internal;

#if cpp
import sys.db.Connection;
import sys.db.ResultSet;

/**
 * A `sys.db.Connection` over the SQLite hxcpp bundles, as Haxe's
 * `sys.db.Sqlite` builds one, with the database handle kept in reach so the
 * driver can ask SQLite itself whether a transaction is open.
 *
 * `sqlite3_get_autocommit` answers from the connection's own state, so a
 * transaction begun or ended as SQL text, `request("BEGIN")`, or rolled
 * back by SQLite after an error is reflected, at no cost.
 */
@:noCompletion
@:buildXml('<include name="${HXCPP}/src/hx/libs/sqlite/Build.xml"/>')
@:cppFileCode('
HXCPP_EXTERN_CLASS_ATTRIBUTES bool _hx_sqlite_get_autocommit(Dynamic handle);
')
class NativeSQLiteConnection implements Connection {
	@:noCompletion private var __handle:Dynamic;

	public static function open(path:String):NativeSQLiteConnection {
		return new NativeSQLiteConnection(__connect(path));
	}

	public function new(handle:Dynamic) {
		__handle = handle;
	}

	/** Whether no transaction is open. **/
	public var autocommit(get, never):Bool;

	public function request(s:String):ResultSet {
		return new NativeSQLiteResultSet(__request(__handle, s));
	}

	public function close():Void {
		__close(__handle);
	}

	public function escape(s:String):String {
		return s.split("'").join("''");
	}

	public function quote(s:String):String {
		if (s.indexOf(String.fromCharCode(0)) >= 0) {
			var hexChars:Array<String> = [];

			for (i in 0...s.length) {
				hexChars.push(StringTools.hex(StringTools.fastCodeAt(s, i), 2));
			}

			return "x'" + hexChars.join("") + "'";
		}

		return "'" + s.split("'").join("''") + "'";
	}

	public function addValue(s:StringBuf, v:Dynamic):Void {
		if (v == null) {
			s.add("NULL");
		} else if (Std.isOfType(v, Bool)) {
			s.add(v ? 1 : 0);
		} else if (Std.isOfType(v, Int) || Std.isOfType(v, Float)) {
			s.add(v);
		} else {
			s.add(quote(Std.string(v)));
		}
	}

	public function lastInsertId():Int {
		return __lastInsertId(__handle);
	}

	public function dbName():String {
		return "SQLite";
	}

	public function startTransaction():Void {
		request("BEGIN TRANSACTION");
	}

	public function commit():Void {
		request("COMMIT");
	}

	public function rollback():Void {
		request("ROLLBACK");
	}

	private function get_autocommit():Bool {
		return __getAutocommit(__handle);
	}

	@:native("_hx_sqlite_connect")
	extern private static function __connect(filename:String):Dynamic;

	@:native("_hx_sqlite_request")
	extern private static function __request(handle:Dynamic, req:String):Dynamic;

	@:native("_hx_sqlite_close")
	extern private static function __close(handle:Dynamic):Void;

	@:native("_hx_sqlite_last_insert_id")
	extern private static function __lastInsertId(handle:Dynamic):Int;

	@:native("_hx_sqlite_get_autocommit")
	extern private static function __getAutocommit(handle:Dynamic):Bool;
}

@:noCompletion
private class NativeSQLiteResultSet implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	@:noCompletion private var __result:Dynamic;
	@:noCompletion private var __cache:List<Dynamic>;

	public function new(result:Dynamic) {
		__cache = new List();
		__result = result;
		// Steps the statement once, which is what runs a write.
		hasNext();
	}

	private function get_length():Int {
		if (nfields != 0) {
			while (true) {
				var row:Dynamic = __next(__result);

				if (row == null) {
					break;
				}

				__cache.add(row);
			}

			return __cache.length;
		}

		return __length(__result);
	}

	private function get_nfields():Int {
		return __nfields(__result);
	}

	public function hasNext():Bool {
		var row:Dynamic = next();

		if (row == null) {
			return false;
		}

		__cache.push(row);
		return true;
	}

	public function next():Dynamic {
		var cached:Dynamic = __cache.pop();

		if (cached != null) {
			return cached;
		}

		return __next(__result);
	}

	public function results():List<Dynamic> {
		var out:List<Dynamic> = new List();

		while (true) {
			var row:Dynamic = next();

			if (row == null) {
				break;
			}

			out.add(row);
		}

		return out;
	}

	public function getResult(n:Int):String {
		return new String(__get(__result, n));
	}

	public function getIntResult(n:Int):Int {
		return __getInt(__result, n);
	}

	public function getFloatResult(n:Int):Float {
		return __getFloat(__result, n);
	}

	public function getFieldsNames():Null<Array<String>> {
		return null;
	}

	@:native("_hx_sqlite_result_next")
	extern private static function __next(handle:Dynamic):Dynamic;

	@:native("_hx_sqlite_result_get_length")
	extern private static function __length(handle:Dynamic):Int;

	@:native("_hx_sqlite_result_get_nfields")
	extern private static function __nfields(handle:Dynamic):Int;

	@:native("_hx_sqlite_result_get")
	extern private static function __get(handle:Dynamic, i:Int):String;

	@:native("_hx_sqlite_result_get_int")
	extern private static function __getInt(handle:Dynamic, i:Int):Int;

	@:native("_hx_sqlite_result_get_float")
	extern private static function __getFloat(handle:Dynamic, i:Int):Float;
}
#end
