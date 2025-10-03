package crossbyte.db.mysql;

import crossbyte.errors.IOError;
import crossbyte.errors.SQLError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import sys.db.Connection;
import sys.db.ResultSet;
import sys.db.Mysql;

class MySQLConnection extends EventDispatcher {
	private static final ALLOWED_CHARSETS = ["utf8mb4", "utf8", "latin1", "ucs2", "utf16", "utf32"];

	public var connected(get, null):Bool;
	public var inTransaction(get, null):Bool;
	public var lastInsertRowID(get, null):Int;
	public var affectedRows(get, null):Int;
	public var serverVersion(get, null):String;
	public var autocommit(get, set):Bool;
	public var isolationLevel(get, set):IsolationLevel;

	@:noCompletion private var __connection:Connection;
	@:noCompletion private var __inTransaction:Bool = false;

	public function new() {
		super();
	}

	public function open(cfg:MySQLConfig):Void {
		try {
			__connection = Mysql.connect({
				host: cfg.host,
				port: cfg.port,
				user: cfg.user,
				pass: cfg.password,
				database: cfg.database,
				socket: cfg.socket
			});

			if (cfg.charset != null && cfg.charset != "") {
				var cs:String = cfg.charset.toLowerCase();
				if (ALLOWED_CHARSETS.indexOf(cs) == -1) {
					throw "Unsupported charset: " + cfg.charset;
				}
				__connection.request("SET NAMES " + cs + ";");
			}

			if (cfg.timeZone != null && cfg.timeZone != "") {
				var sb:StringBuf = new StringBuf();
				sb.add("tz");
				__connection.addValue(sb, cfg.timeZone);
				__connection.request("SET time_zone = :tz;");
			}

			if (cfg.sqlMode != null && cfg.sqlMode != "") {
				var sb2:StringBuf = new StringBuf();
				sb2.add("sqlmode");
				__connection.addValue(sb2, cfg.sqlMode);
				__connection.request("SET SESSION sql_mode = :sqlmode;");
			}

			__dispatch(SQLEvent.OPEN);
		} catch (e:Dynamic) {
			throw new IOError(e);
		}
	}

	public function close():Void {
		if (__connection != null) {
			try {
				__connection.close();
				__dispatch(SQLEvent.CLOSE);
			} catch (e:Dynamic) {
				__dispatchError(SQLEvent.CLOSE, "Close failed", e);
			}

			__connection = null;
			__inTransaction = false;
		}
	}

	public function ping():Bool {
		try {
			if (__connection == null) {
				return false;
			}
			__connection.request("SELECT 1;");
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	// Transactions
	public function begin():Void {
		try {
			__connection.request("START TRANSACTION;");
			__inTransaction = true;
			__dispatch(SQLEvent.BEGIN);
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.BEGIN, "Begin failed", e);
		}
	}

	public function commit():Void {
		try {
			__connection.request("COMMIT;");
			__inTransaction = false;
			__dispatch(SQLEvent.COMMIT);
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.COMMIT, "Commit failed", e);
		}
	}

	public function rollback():Void {
		try {
			__connection.request("ROLLBACK;");
			__inTransaction = false;
			__dispatch(SQLEvent.ROLLBACK);
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.ROLLBACK, "Rollback failed", e);
		}
	}

	public function setSavepoint(name:String = null):Void {
		var sp:String = __sanitizeSavePoint(name);
		try {
			__connection.request('SAVEPOINT ' + sp + ';');
			__dispatch(SQLEvent.SET_SAVEPOINT);
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.SET_SAVEPOINT, "Savepoint failed", e);
		}
	}

	public function rollbackToSavepoint(name:String):Void {
		if (name == null || name == "") {
			rollback();
			return;
		}

		var sp:String = __sanitizeSavePoint(name);

		try {
			__connection.request('ROLLBACK TO SAVEPOINT ' + sp + ';'); // <-- add SAVEPOINT
			__dispatch(SQLEvent.ROLLBACK_TO_SAVEPOINT);
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.ROLLBACK_TO_SAVEPOINT, "Rollback to savepoint failed", e);
		}
	}

	public function releaseSavepoint(name:String):Void {
		var sp:String = __sanitizeSavePoint(name);

		try {
			__connection.request('RELEASE SAVEPOINT ' + sp + ';');
			__dispatch(SQLEvent.RELEASE_SAVEPOINT);
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.RELEASE_SAVEPOINT, "Release savepoint failed", e);
		}
	}

	public inline function request(sql:String):ResultSet {
		return __connection.request(sql);
	}

	private function get_connected():Bool {
		return __connection != null && ping();
	}

	private function get_inTransaction():Bool {
		return __inTransaction;
	}

	private function get_lastInsertRowID():Int {
		return (__connection != null) ? __connection.lastInsertId() : 0;
	}

	private function get_affectedRows():Int {
		if (__connection == null) {
			return 0;
		}

		var rs = __connection.request("SELECT ROW_COUNT() AS n;");

		return (rs != null && rs.hasNext()) ? Std.parseInt(Std.string(Reflect.field(rs.next(), "n"))) : 0;
	}

	private function get_serverVersion():String {
		if (__connection == null) {
			return "";
		}
		var rs:ResultSet = __connection.request("SELECT VERSION() AS v;");

		return (rs != null && rs.hasNext()) ? Std.string(Reflect.field(rs.next(), "v")) : "";
	}

	private function get_autocommit():Bool {
		if (__connection == null) {
			return true;
		}

		var rs:ResultSet = __connection.request("SELECT @@autocommit AS ac;");

		return (rs != null && rs.hasNext()) ? (Std.parseInt(Std.string(Reflect.field(rs.next(), "ac"))) == 1) : true;
	}

	private function set_autocommit(v:Bool):Bool {
		if (__connection != null) {
			__connection.request("SET autocommit = " + (v ? "1" : "0") + ";");
		}

		return v;
	}

	private function get_isolationLevel():IsolationLevel {
		if (__connection == null) {
			return IsolationLevel.REPEATABLE_READ;
		}
		var rs:ResultSet = __connection.request("SELECT @@transaction_isolation AS lvl;");

		if (rs != null && rs.hasNext()) {
			var s:String = Std.string(Reflect.field(rs.next(), "lvl"));
			return s; // let the enum-abstract coerce
		}

		return IsolationLevel.REPEATABLE_READ;
	}

	private function set_isolationLevel(v:IsolationLevel):IsolationLevel {
		if (__connection != null) {
			__connection.request("SET SESSION TRANSACTION ISOLATION LEVEL " + v + ";");
		}

		return v;
	}

	@:noCompletion private inline function __sanitizeSavePoint(name:String):String {
		var n:String = (name != null && name != "") ? name : ('sp_' + Std.int(haxe.Timer.stamp() * 1e6));
		return ~/[^\w]/g.replace(n, "_");
	}

	@:noCompletion private inline function __dispatch(t:String):Void {
		__dispatchEvent(new SQLEvent(t));
	}

	@:noCompletion private inline function __dispatchError(op:String, msg:String, e:Dynamic):Void {
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(op, e, msg)));
	}
}
