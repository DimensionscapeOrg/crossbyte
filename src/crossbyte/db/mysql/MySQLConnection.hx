package crossbyte.db.mysql;

// Not built for any JavaScript target (Node included, which has no a database driver): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.errors.IOError;
import crossbyte.errors.SQLError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import sys.db.Connection;
import sys.db.ResultSet;
import sys.db.Mysql;

/** MySQL connection wrapper over Haxe's `sys.db.Mysql` support. */
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

	// Transactions. Each throws an `SQLError` when the server refuses, after
	// dispatching it as an `SQLErrorEvent` as well. They used to dispatch and
	// return, so a failed COMMIT read as a committed one to every caller that
	// was not listening, `AsyncDatabase.transaction` and `SchemaMigrator`
	// among them, the way SQLiteConnection, which throws, never did.
	public function begin():Void {
		try {
			__connection.request("START TRANSACTION;");
		} catch (e:Dynamic) {
			__fail(SQLEvent.BEGIN, "Begin failed", e);
		}

		__inTransaction = true;
		__dispatch(SQLEvent.BEGIN);
	}

	/**
		Commits, or throws an `SQLError` saying why not.

		`inTransaction` stays `true` after a failed COMMIT. Whether MySQL has
		ended the transaction depends on why it failed, and of the two ways to
		be wrong this is the harmless one: a ROLLBACK sent to a connection with
		no transaction does nothing, while a connection believed idle and
		still inside one takes its locks, and the next borrower's writes, with
		it.
	**/
	public function commit():Void {
		try {
			__connection.request("COMMIT;");
		} catch (e:Dynamic) {
			__fail(SQLEvent.COMMIT, "Commit failed", e);
		}

		__inTransaction = false;
		__dispatch(SQLEvent.COMMIT);
	}

	public function rollback():Void {
		var failure:Dynamic = null;

		try {
			__connection.request("ROLLBACK;");
		} catch (e:Dynamic) {
			failure = e;
		}

		// A ROLLBACK that fails has lost the connection, and the server ends
		// the transaction with it.
		__inTransaction = false;

		if (failure != null) {
			__fail(SQLEvent.ROLLBACK, "Rollback failed", failure);
		}

		__dispatch(SQLEvent.ROLLBACK);
	}

	public function setSavepoint(name:String = null):Void {
		var sp:String = __sanitizeSavePoint(name);
		try {
			__connection.request('SAVEPOINT ' + sp + ';');
		} catch (e:Dynamic) {
			__fail(SQLEvent.SET_SAVEPOINT, "Savepoint failed", e);
		}

		__dispatch(SQLEvent.SET_SAVEPOINT);
	}

	public function rollbackToSavepoint(name:String):Void {
		if (name == null || name == "") {
			rollback();
			return;
		}

		var sp:String = __sanitizeSavePoint(name);

		try {
			__connection.request('ROLLBACK TO SAVEPOINT ' + sp + ';');
		} catch (e:Dynamic) {
			__fail(SQLEvent.ROLLBACK_TO_SAVEPOINT, "Rollback to savepoint failed", e);
		}

		__dispatch(SQLEvent.ROLLBACK_TO_SAVEPOINT);
	}

	public function releaseSavepoint(name:String):Void {
		var sp:String = __sanitizeSavePoint(name);

		try {
			__connection.request('RELEASE SAVEPOINT ' + sp + ';');
		} catch (e:Dynamic) {
			__fail(SQLEvent.RELEASE_SAVEPOINT, "Release savepoint failed", e);
		}

		__dispatch(SQLEvent.RELEASE_SAVEPOINT);
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

	/**
		Reports a failed transaction step both ways: as the `SQLErrorEvent` it
		always was, and as the `SQLError` it now throws.
	**/
	@:noCompletion private function __fail(op:String, msg:String, e:Dynamic):Void {
		var detail:String = Std.string(e);
		var error:SQLError = new SQLError(op, detail, msg + ": " + detail);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
	}
}
#end
