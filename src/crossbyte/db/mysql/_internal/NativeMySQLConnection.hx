package crossbyte.db.mysql._internal;

#if cpp
import sys.db.Connection;
import sys.db.ResultSet;

/**
 * A `sys.db.Connection` over the native client, with what the driver needs
 * to know after each statement besides its rows.
 *
 * It replaces `sys.db.Mysql.connect` on cpp: the same client underneath, but
 * with its handle in reach, so the session state the server reported comes
 * back without a statement to ask for it.
 */
@:noCompletion
class NativeMySQLConnection implements Connection {
	@:noCompletion private var __handle:Dynamic;

	/**
		Connects, and selects `database` when one is given. A connection that
		opens and then cannot select its database is closed before the error
		leaves, rather than left for the collector.
	**/
	public static function connect(params:Dynamic, database:String):NativeMySQLConnection {
		var handle:Dynamic = NativeMySQL.connect(params);

		if (database != null && database != "") {
			try {
				NativeMySQL.selectDatabase(handle, database);
			} catch (e:Dynamic) {
				try {
					NativeMySQL.close(handle);
				} catch (_:Dynamic) {}
				cpp.Lib.rethrow(e);
			}
		}

		return new NativeMySQLConnection(handle);
	}

	public function new(handle:Dynamic) {
		__handle = handle;
	}

	/**
		The status flags of the server's last OK or EOF packet:
		`NativeMySQL.STATUS_IN_TRANS`, `STATUS_AUTOCOMMIT`,
		`STATUS_NO_BACKSLASH_ESCAPES` and the rest.
	**/
	public var serverStatus(get, never):Int;

	public function request(sql:String):ResultSet {
		return new NativeMySQLResultSet(NativeMySQL.request(__handle, sql));
	}

	public function close():Void {
		NativeMySQL.close(__handle);
	}

	/**
		Escapes by the session's current rules: doubling a quote once the
		server has reported `NO_BACKSLASH_ESCAPES`, backslash-escaping it
		otherwise.
	**/
	public function escape(s:String):String {
		return NativeMySQL.escape(__handle, s);
	}

	public function quote(s:String):String {
		return "'" + escape(s) + "'";
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
		return request("SELECT LAST_INSERT_ID()").getIntResult(0);
	}

	public function dbName():String {
		return "MySQL";
	}

	public function startTransaction():Void {
		request("START TRANSACTION");
	}

	public function commit():Void {
		request("COMMIT");
	}

	public function rollback():Void {
		request("ROLLBACK");
	}

	private function get_serverStatus():Int {
		return NativeMySQL.serverStatus(__handle);
	}

	/** Whether the session runs over TLS. **/
	public var encrypted(get, never):Bool;

	/** The authentication plugin the account logged in with. **/
	public var authPlugin(get, never):String;

	private function get_encrypted():Bool {
		return NativeMySQL.isTls(__handle);
	}

	private function get_authPlugin():String {
		return NativeMySQL.authPlugin(__handle);
	}
}

@:noCompletion
class NativeMySQLResultSet implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	@:noCompletion private var __result:Dynamic;
	@:noCompletion private var __cache:Dynamic;

	public function new(result:Dynamic) {
		__result = result;
	}

	private function get_length():Int {
		return NativeMySQL.resultLength(__result);
	}

	private function get_nfields():Int {
		return NativeMySQL.resultFields(__result);
	}

	public function hasNext():Bool {
		if (__cache == null) {
			__cache = next();
		}

		return __cache != null;
	}

	public function next():Dynamic {
		var cached:Dynamic = __cache;

		if (cached != null) {
			__cache = null;
			return cached;
		}

		return NativeMySQL.resultNext(__result);
	}

	public function results():List<Dynamic> {
		var out:List<Dynamic> = new List();

		while (hasNext()) {
			out.add(next());
		}

		return out;
	}

	public function getResult(n:Int):String {
		return NativeMySQL.resultGet(__result, n);
	}

	public function getIntResult(n:Int):Int {
		return NativeMySQL.resultGetInt(__result, n);
	}

	public function getFloatResult(n:Int):Float {
		return NativeMySQL.resultGetFloat(__result, n);
	}

	public function getFieldsNames():Null<Array<String>> {
		return NativeMySQL.resultFieldNames(__result);
	}
}
#end
