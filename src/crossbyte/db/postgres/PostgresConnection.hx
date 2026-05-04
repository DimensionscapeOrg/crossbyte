package crossbyte.db.postgres;

import haxe.Json;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.EventDispatcher;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
#if cpp
import crossbyte.db.postgres._internal.NativePostgres;
import crossbyte.ipc._internal.VoidPointer;
import haxe.io.Path;
import sys.FileSystem;
#end
#if php
import php.Global;
import php.Syntax;
#end

/** PostgreSQL connection wrapper currently backed by PHP PDO on supported targets. */
class PostgresConnection extends EventDispatcher {
	public static final isSupported:Bool = #if php __checkSupport() #elseif cpp true #else false #end;

	public var connected(get, null):Bool;
	public var inTransaction(get, null):Bool;
	public var lastInsertRowID(get, null):Int;
	public var affectedRows(get, null):Int;
	public var serverVersion(get, null):String;
	public var autocommit(get, set):Bool;
	public var isolationLevel(get, set):PostgresIsolationLevel;

	@:noCompletion private var __connection:Dynamic;
	#if cpp
	@:noCompletion private var __nativeHandle:VoidPointer;
	#end
	@:noCompletion private var __inTransaction:Bool = false;
	@:noCompletion private var __autocommit:Bool = true;
	@:noCompletion private var __isolationLevel:PostgresIsolationLevel = PostgresIsolationLevel.REPEATABLE_READ;
	@:noCompletion private var __lastInsertRowID:Int = 0;
	@:noCompletion private var __lastAffectedRows:Int = 0;

	public function new() {
		super();
	}

	public function open(cfg:PostgresConfig):Void {
		__requireSupported();
		if (cfg == null) {
			throw "PostgresConnection: config is required.";
		}

		#if cpp
		try {
			var host:String = cfg.host != null ? cfg.host : "127.0.0.1";
			var port:Int = cfg.port != null ? cfg.port : 5432;
			var database:String = cfg.database != null ? cfg.database : "postgres";
			var user:String = cfg.user != null ? cfg.user : "";
			var pass:String = cfg.password != null ? cfg.password : "";
			var sslMode:String = cfg.sslMode != null ? cfg.sslMode : "";
			var connectTimeout:Int = cfg.connectTimeout != null ? cfg.connectTimeout : 5;
			var libraryPaths = __libraryCandidates(cfg);

			__nativeHandle = NativePostgres.open(host, port, user, pass, database, sslMode, connectTimeout, libraryPaths);
			if (__nativeHandle == null) {
				throw new IOError(NativePostgres.lastError());
			}

			__dispatchEvent(new SQLEvent(SQLEvent.OPEN));
		} catch (e:Dynamic) {
			throw new IOError(e);
		}
		#else
		#if php
		try {
			var host:String = cfg.host != null ? cfg.host : "127.0.0.1";
			var port:Int = cfg.port != null ? cfg.port : 5432;
			var database:String = cfg.database != null ? cfg.database : "postgres";
			var user:String = cfg.user != null ? cfg.user : "";
			var pass:String = cfg.password != null ? cfg.password : "";
			var dsn:StringBuf = new StringBuf();
			dsn.add("pgsql:host=");
			dsn.add(host);
			dsn.add(";port=");
			dsn.add(port);
			dsn.add(";dbname=");
			dsn.add(database);

			if (cfg.sslMode != null && cfg.sslMode != "") {
				dsn.add(";sslmode=");
				dsn.add(cfg.sslMode);
			}

			if (cfg.connectTimeout != null && cfg.connectTimeout > 0) {
				dsn.add(";connect_timeout=");
				dsn.add(cfg.connectTimeout);
			}

			__connection = Syntax.code("new \\PDO({0}, {1}, {2})", dsn.toString(), user, pass);

			__dispatchEvent(new SQLEvent(SQLEvent.OPEN));
		} catch (e:Dynamic) {
			throw new IOError(e);
		}
		#else
		throw new IOError("PostgreSQL is only supported on php targets.");
		#end
		#end
	}

	public function close():Void {
		#if cpp
		if (__nativeHandle != null) {
			NativePostgres.close(__nativeHandle);
			__nativeHandle = null;
			__inTransaction = false;
			__dispatchEvent(new SQLEvent(SQLEvent.CLOSE));
		}
		#end

		if (__connection != null) {
			__connection = null;
			__inTransaction = false;
			__dispatchEvent(new SQLEvent(SQLEvent.CLOSE));
		}
	}

	public function ping():Bool {
		try {
			if (__connection == null) {
				return false;
			}

			request("SELECT 1;");
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	public function begin():Void {
		try {
			request("BEGIN;");
			__inTransaction = true;
			__dispatchEvent(new SQLEvent(SQLEvent.BEGIN));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.BEGIN, "Begin failed", e);
		}
	}

	public function commit():Void {
		try {
			request("COMMIT;");
			__inTransaction = false;
			__dispatchEvent(new SQLEvent(SQLEvent.COMMIT));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.COMMIT, "Commit failed", e);
		}
	}

	public function rollback():Void {
		try {
			request("ROLLBACK;");
			__inTransaction = false;
			__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.ROLLBACK, "Rollback failed", e);
		}
	}

	public function setSavepoint(name:String = null):Void {
		var sp:String = __sanitizeSavePoint(name);

		try {
			request('SAVEPOINT ' + sp + ';');
			__dispatchEvent(new SQLEvent(SQLEvent.SET_SAVEPOINT));
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
			request('ROLLBACK TO SAVEPOINT ' + sp + ';');
			__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK_TO_SAVEPOINT));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.ROLLBACK_TO_SAVEPOINT, "Rollback to savepoint failed", e);
		}
	}

	public function releaseSavepoint(name:String):Void {
		var sp:String = __sanitizeSavePoint(name);

		try {
			request('RELEASE SAVEPOINT ' + sp + ';');
			__dispatchEvent(new SQLEvent(SQLEvent.RELEASE_SAVEPOINT));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.RELEASE_SAVEPOINT, "Release savepoint failed", e);
		}
	}

	public inline function request(sql:String):Dynamic {
		__requireConnected();

		#if cpp
		var rawJson = NativePostgres.requestJson(__nativeHandle, sql);
		var parsed:Dynamic = Json.parse(rawJson == null || rawJson == "" ? "{\"rows\":[],\"affectedRows\":0,\"lastInsertRowID\":0}" : rawJson);
		var errorMessage:Dynamic = Reflect.field(parsed, "error");
		if (errorMessage != null) {
			throw new IOError(Std.string(errorMessage));
		}

		var rows:Array<Dynamic> = __toRows(Reflect.field(parsed, "rows"));
		__lastAffectedRows = __toInt(Reflect.field(parsed, "affectedRows"));
		__lastInsertRowID = __toInt(Reflect.field(parsed, "lastInsertRowID"));
		return new PostgresResultSet(rows);
		#else
		var statement:Dynamic = null;
		var rows:Array<Dynamic> = [];
		__lastAffectedRows = 0;

		try {
			statement = __connection.query(sql);
		} catch (e:Dynamic) {
			throw new IOError(e);
		}

		try {
			var rawRows:Dynamic = statement.fetchAll();
			rows = __toRows(rawRows);
			__lastAffectedRows = __rowCount(statement);
		} catch (_:Dynamic) {
			try {
				var updated:Dynamic = __connection.exec(sql);
				__lastAffectedRows = __toInt(updated);
			} catch (e:Dynamic) {
				throw new IOError(e);
			}
		}

		__lastInsertRowID = __lastInsertId();
		return new PostgresResultSet(rows);
		#end
	}

	public function escape(value:String):String {
		#if cpp
		return __nativeHandle == null ? __fallbackEscape(value) : NativePostgres.escape(__nativeHandle, value == null ? "" : value);
		#else
		return __fallbackEscape(value);
		#end
	}

	public inline function quote(value:String):String {
		return "'" + escape(value) + "'";
	}

	private function get_connected():Bool {
		#if cpp
		if (__nativeHandle == null) {
			return false;
		}
		return NativePostgres.isOpen(__nativeHandle);
		#else
		if (__connection == null) {
			return false;
		}
		return ping();
		#end
	}

	private function get_inTransaction():Bool {
		return __inTransaction;
	}

	private function get_lastInsertRowID():Int {
		return __lastInsertRowID;
	}

	private function get_affectedRows():Int {
		return __lastAffectedRows;
	}

	private function get_serverVersion():String {
		try {
			var rs = request("SHOW server_version;");
			if (!rs.hasNext()) {
				return "";
			}

			var row = rs.next();
			if (row == null) {
				return "";
			}

			var direct = Reflect.field(row, "server_version");
			if (direct != null) {
				return Std.string(direct);
			}

			var keys:Array<String> = Reflect.fields(row);
			if (keys.length > 0) {
				return Std.string(Reflect.field(row, keys[0]));
			}
		} catch (_:Dynamic) {}

		return "";
	}

	private function get_autocommit():Bool {
		return __autocommit;
	}

	private function set_autocommit(v:Bool):Bool {
		__autocommit = v;
		return v;
	}

	private function get_isolationLevel():PostgresIsolationLevel {
		try {
			var rs = request("SHOW transaction_isolation;");
			if (!rs.hasNext()) {
				return __isolationLevel;
			}
			var row = rs.next();
			if (row == null) {
				return __isolationLevel;
			}

			var raw = Reflect.field(row, "transaction_isolation");
			var value:String = raw != null ? Std.string(raw) : "";
			return value != "" ? value : __isolationLevel;
		} catch (_:Dynamic) {}

		return __isolationLevel;
	}

	private function set_isolationLevel(v:PostgresIsolationLevel):PostgresIsolationLevel {
		try {
			request("SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL " + v + ";");
			__isolationLevel = v;
		} catch (_:Dynamic) {}

		return __isolationLevel;
	}

	@:noCompletion private function __sanitizeSavePoint(name:String):String {
		var n:String = (name != null && name != "") ? name : ('sp_' + Std.int(haxe.Timer.stamp() * 1e6));

		return ~/[^\w]/g.replace(n, "_");
	}

	@:noCompletion private inline function __requireSupported():Void {
		if (!isSupported) {
			throw new ArgumentError("PostgresConnection is not supported on this target or extension is not available.");
		}
	}

	@:noCompletion private inline function __requireConnected():Void {
		#if cpp
		if (__nativeHandle == null) {
			throw "PostgresConnection: no connection set.";
		}
		#else
		if (__connection == null) {
			throw "PostgresConnection: no connection set.";
		}
		#end
	}

	@:noCompletion private function __lastInsertId():Int {
		if (__connection == null) {
			return __lastInsertRowID;
		}
		try {
			return __toInt(__connection.lastInsertId());
		} catch (_:Dynamic) {
			return __lastInsertRowID;
		}
	}

	@:noCompletion private function __rowCount(statement:Dynamic):Int {
		try {
			return __toInt(statement.rowCount());
		} catch (_:Dynamic) {
			return 0;
		}
	}

	@:noCompletion private function __toInt(value:Dynamic):Int {
		var n:Null<Int> = null;
		if (value != null) {
			n = Std.parseInt(Std.string(value));
		}
		return n != null ? n : 0;
	}

	@:noCompletion private function __toRows(raw:Dynamic):Array<Dynamic> {
		if (raw == null) {
			return [];
		}
		if (Std.isOfType(raw, Array)) {
			return cast raw;
		}
		return [raw];
	}

	@:noCompletion private inline function __dispatchError(op:String, msg:String, e:Dynamic):Void {
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(op, e, msg)));
	}

	@:noCompletion private static function __checkSupport():Bool {
		#if php
		return Global.extension_loaded("pdo") && Global.extension_loaded("pdo_pgsql");
		#elseif cpp
		return true;
		#else
		return false;
		#end
	}

	@:noCompletion private function __fallbackEscape(value:String):String {
		var s = value == null ? "" : Std.string(value);
		s = s.split("\\").join("\\\\");
		return s.split("'").join("''");
	}

	#if cpp
	@:noCompletion private function __libraryCandidates(cfg:PostgresConfig):Array<String> {
		var candidates:Array<String> = [];
		__pushCandidate(candidates, cfg.libraryPath);
		if (cfg.libraryPaths != null) {
			for (path in cfg.libraryPaths) {
				__pushCandidate(candidates, path);
			}
		}

		var cwd = Sys.getCwd();
		var exeDir = Path.directory(Sys.programPath());
		#if windows
		__pushCandidate(candidates, Path.join([cwd, "php", "libpq.dll"]));
		__pushCandidate(candidates, Path.join([cwd, "..", "php", "libpq.dll"]));
		__pushCandidate(candidates, Path.join([exeDir, "libpq.dll"]));
		__pushCandidate(candidates, Path.join([exeDir, "..", "..", "..", "..", "php", "libpq.dll"]));
		__pushCandidate(candidates, "libpq.dll");
		#else
		__pushCandidate(candidates, "libpq.so.5");
		__pushCandidate(candidates, "libpq.so");
		#end
		return candidates;
	}

	@:noCompletion private function __pushCandidate(candidates:Array<String>, raw:String):Void {
		if (raw == null) {
			return;
		}

		var trimmed = StringTools.trim(raw);
		if (trimmed == "") {
			return;
		}

		if (FileSystem.exists(trimmed) && FileSystem.isDirectory(trimmed)) {
			#if windows
			trimmed = Path.join([trimmed, "libpq.dll"]);
			#else
			trimmed = Path.join([trimmed, "libpq.so"]);
			#end
		}

		if (candidates.indexOf(trimmed) == -1) {
			candidates.push(trimmed);
		}
	}
	#end
}

private class PostgresResultSet {
	public var length(default, null):Int = 0;

	@:noCompletion private var __rows:Array<Dynamic>;
	@:noCompletion private var __index:Int = 0;

	public function new(rows:Array<Dynamic>) {
		__rows = rows != null ? rows : [];
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
