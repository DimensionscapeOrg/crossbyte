package crossbyte.db.postgres;

// Not built for the browser: a database driver needs a socket or a file, and credentials do not belong in a page.
#if !(js && !nodejs)

import haxe.Json;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.EventDispatcher;
import crossbyte.errors.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import crossbyte.db.postgres._internal.PostgresWire;
import haxe.io.Bytes;
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
	@:noCompletion private var __savepoints:Array<String> = [];
	@:noCompletion private var __savepointSeq:Int = 0;

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
			__savepoints = [];
			__dispatchEvent(new SQLEvent(SQLEvent.BEGIN));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.BEGIN, "Begin failed", e);
		}
	}

	public function commit():Void {
		try {
			request("COMMIT;");
			__inTransaction = false;
			__savepoints = [];
			__dispatchEvent(new SQLEvent(SQLEvent.COMMIT));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.COMMIT, "Commit failed", e);
		}
	}

	public function rollback():Void {
		try {
			request("ROLLBACK;");
			__inTransaction = false;
			__savepoints = [];
			__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.ROLLBACK, "Rollback failed", e);
		}
	}

	/**
		Creates a savepoint and returns its name, so one created without a name
		can still be released or rolled back to. It returned nothing, which
		left a generated name known only to the statement that used it -- and
		release and rollback both require a name, so such a savepoint could
		never be reached again by any means.
	**/
	public function setSavepoint(name:String = null):String {
		var sp:String = __sanitizeSavePoint(name);
		__savepoints.push(sp);

		try {
			request('SAVEPOINT ' + sp + ';');
			__dispatchEvent(new SQLEvent(SQLEvent.SET_SAVEPOINT));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.SET_SAVEPOINT, "Savepoint failed", e);
		}

		return sp;
	}

	/**
		Rolls back to a savepoint, which stays active afterwards as PostgreSQL
		leaves it. With no name, rolls back to the innermost savepoint this
		connection holds -- and only to a full rollback() when it holds none.
		Omitting the name used to roll the whole transaction back, so a caller
		asking to return to a savepoint lost everything before it instead.
	**/
	public function rollbackToSavepoint(name:String = null):Void {
		if ((name == null || name == "") && __savepoints.length == 0) {
			rollback();
			return;
		}

		var sp:String = __takeSavepoint(name, true);
		try {
			request('ROLLBACK TO SAVEPOINT ' + sp + ';');
			__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK_TO_SAVEPOINT));
		} catch (e:Dynamic) {
			__dispatchError(SQLEvent.ROLLBACK_TO_SAVEPOINT, "Rollback to savepoint failed", e);
		}
	}

	/**
		Releases a savepoint, discarding it and any nested inside it. With no
		name, releases the innermost this connection holds; it used to mint a
		brand new name and ask the server to release a savepoint that had
		never existed.
	**/
	public function releaseSavepoint(name:String = null):Void {
		var sp:String = __takeSavepoint(name, false);

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

	/**
		Runs a statement with bound parameters, referenced as `$1`, `$2` and so
		on in the statement text.

		This is the path to use for anything carrying data. `request()` builds
		SQL by substitution, so a value is only ever as safe as the escaping
		applied to it — and no escaping can carry a NUL byte, because
		`PQescapeStringConn` works on NUL-terminated C strings and stops at the
		first zero. A ciphertext blob written that way is silently truncated,
		with no error anywhere.

		Bound values never enter the statement text at all, so quoting stops
		being a question. Values come back as `haxe.io.Bytes` rather than
		strings, since a `bytea` column and a `text` column holding invalid
		UTF-8 both have to survive the trip.

		```haxe
		connection.requestParams("INSERT INTO events (id, payload) VALUES ($1, $2)",
			[Text(Std.string(id)), Binary(ciphertext)]);

		var rows = connection.requestParams("SELECT payload FROM events WHERE id = $1", [Text("7")]);
		```

		Only available on cpp, where the libpq bridge lives; other targets throw
		rather than silently falling back to substitution, which would defeat
		the point.
	**/
	public function requestParams(sql:String, ?params:Array<PostgresParameter>):PostgresRawResult {
		__requireConnected();

		#if cpp
		var encoded:Bytes = PostgresWire.encodeParameters(params == null ? [] : params);
		var data = cpp.NativeArray.address(encoded.getData(), 0);
		var length:Int = NativePostgres.requestParams(__nativeHandle, sql == null ? "" : sql, cast data, encoded.length);

		if (length < 0) {
			throw new IOError("Postgres bridge returned no result block.");
		}

		var block:Bytes = Bytes.alloc(length);
		var source = NativePostgres.resultData();

		for (i in 0...length) {
			block.set(i, source.at(i));
		}

		// Raises the server message for an error block, so a failed statement
		// cannot read as a statement that matched nothing.
		var result:PostgresRawResult = PostgresWire.decodeResult(block);
		__lastAffectedRows = result.affectedRows;
		__lastInsertRowID = result.lastInsertRowID;
		return result;
		#else
		throw new IOError("Bound parameters need the native libpq bridge, which this target does not have.");
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

	/**
		Resolves the savepoint a release or rollback refers to, and updates the
		stack to match what the statement will do to it.

		RELEASE discards the savepoint and everything nested inside it;
		ROLLBACK TO discards what is nested but leaves the savepoint itself
		active. `keep` picks between the two.
	**/
	@:noCompletion private function __takeSavepoint(name:String, keep:Bool):String {
		if (name == null || name == "") {
			if (__savepoints.length == 0) {
				throw new ArgumentError("No savepoint is open on this connection; name one, or use rollback() to undo the transaction.");
			}

			var innermost:String = __savepoints[__savepoints.length - 1];

			if (!keep) {
				__savepoints.pop();
			}

			return innermost;
		}

		var resolved:String = __sanitizeSavePoint(name);
		var index:Int = -1;

		for (i in 0...__savepoints.length) {
			if (__savepoints[i] == resolved) {
				index = i;
			}
		}

		if (index >= 0) {
			__savepoints.splice(keep ? index + 1 : index, __savepoints.length);
		}

		return resolved;
	}

	@:noCompletion private function __sanitizeSavePoint(name:String):String {
		// A counter, not a timestamp. Measured on the identical SQLite version:
		// 2000 names generated back to back produced 47 duplicates, and the
		// value overflows Int about 36 minutes into a process and wraps every
		// 72, so a long-lived connection reissues names it has already used.
		// Two savepoints sharing a name make RELEASE and ROLLBACK TO act on the
		// wrong one.
		var n:String = (name != null && name != "") ? name : ("sp_" + (++__savepointSeq));

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

	/**
		Escapes a value for a server whose standard_conforming_strings is on,
		which has been the default since PostgreSQL 9.1.

		Doubling the quote is the whole of it there. Backslash carries no
		meaning inside an ordinary string literal, so doubling it as well --
		which this used to do -- turned every one into two: a value of
		C:\Users came back out of the database as C:\\Users. Silent
		corruption of anything holding a path, a regular expression, or a UNC
		name.

		Correct escaping is a property of the connection rather than of the
		string: it depends on the server standard_conforming_strings setting
		and on the client encoding, which is why libpq takes a connection for
		its own escape. This runs only when there is no connection to ask, so
		it assumes the default rather than guessing at a legacy setting; a
		connected escape() goes through libpq instead.
	**/
	@:noCompletion private function __fallbackEscape(value:String):String {
		var s = value == null ? "" : Std.string(value);
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
		// Runtime: this file is not cpp-only -- it builds for eval, the JVM and
		// Node -- and `#if windows` is unset on all three, so a Windows host
		// would have gone looking for libpq.so. Unreachable while the driver
		// itself is cpp-only, and wrong the moment that stops being true.
		if (crossbyte.sys.System.isWindows) {
			__pushCandidate(candidates, Path.join([cwd, "php", "libpq.dll"]));
			__pushCandidate(candidates, Path.join([cwd, "..", "php", "libpq.dll"]));
			__pushCandidate(candidates, Path.join([exeDir, "libpq.dll"]));
			__pushCandidate(candidates, Path.join([exeDir, "..", "..", "..", "..", "php", "libpq.dll"]));
			__pushCandidate(candidates, "libpq.dll");
		} else {
			__pushCandidate(candidates, "libpq.so.5");
			__pushCandidate(candidates, "libpq.so");
		}
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
			trimmed = Path.join([trimmed, crossbyte.sys.System.isWindows ? "libpq.dll" : "libpq.so"]);
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
#end
