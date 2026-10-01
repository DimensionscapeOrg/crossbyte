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
import crossbyte.db.postgres._internal.PostgresConnInfo;
import crossbyte.ipc._internal.VoidPointer;
import haxe.io.Path;
import sys.FileSystem;
import sys.thread.Mutex;
#end
#if php
import php.Global;
import php.Syntax;
#end

/**
	A connection to PostgreSQL. Natively (cpp) it drives libpq, loaded when
	the connection opens, from `PostgresConfig.libraryPath` or
	`libraryPaths`, or where the system keeps it, with bound parameters
	(`requestParams`), `cancel()` and the timeouts `PostgresConfig` sets. On
	php it runs on PDO. No other target has a driver: `isSupported` is
	`false` there, and `open()` throws.
**/
class PostgresConnection extends EventDispatcher implements crossbyte.db.ITransactionalConnection {
	public static final isSupported:Bool = #if php __checkSupport() #elseif cpp true #else false #end;

	public var connected(get, null):Bool;

	/**
		Whether a transaction is open, including one a failed statement has
		left waiting for a rollback. On the native driver this is the server's
		own account, taken after every statement, so a transaction begun or
		ended as SQL text, `request("BEGIN;")`, counts as surely as one
		begun with `begin()`. `ConnectionPool` reads it to roll back what a
		borrower left open.
	**/
	public var inTransaction(get, null):Bool;
	/**
		The OID of the row the last single-row `INSERT` made, as libpq's
		`PQoidValue` reports it, which PostgreSQL 12 and later never
		assign, since tables there have no OIDs, so it reads 0. For the key
		of a row inserted, ask the statement for it: `INSERT ... RETURNING
		id`.
	**/
	public var lastInsertRowID(get, null):Float;

	/**
		The rows the last statement changed, or a `SELECT` returned, as the
		server counts them in its command tag: a `Float`, exact to 2^53. The
		native bridge read it with `atoi`, into 32 bits, so a write of three
		billion rows read 2147483647, or, on Linux, a negative number.
	**/
	public var affectedRows(get, null):Float;
	public var serverVersion(get, null):String;

	/**
		Whether each statement commits on its own, as it does by default.
		Set `false`, a transaction begins before the next statement and stays
		open until `commit()` or `rollback()` ends it, and the statement after
		that begins another, as `autocommit` does on MySQL and in JDBC.
		PostgreSQL has no such setting on the server, so the driver sends the
		`BEGIN` itself. Set back to `true`, a transaction that is open is
		committed first, as MySQL commits it. A new connection starts with it
		on: `close()` resets it.

		It was stored and never read: set `false`, every statement still
		committed on its own.
	**/
	public var autocommit(get, set):Bool;

	/**
		The isolation level of the session's transactions, from the next one
		on. Setting it throws the `SQLError` the server refused it with.
	**/
	public var isolationLevel(get, set):PostgresIsolationLevel;

	@:noCompletion private var __connection:Dynamic;
	#if cpp
	@:noCompletion private var __nativeHandle:VoidPointer;
	// Held by cancel(), which may run on any thread, and by close(), so the
	// handle a cancel is using cannot be freed under it. Nothing on the query
	// path takes it.
	@:noCompletion private var __handleLock:Mutex = new Mutex();
	#end
	@:noCompletion private var __inTransaction:Bool = false;
	@:noCompletion private var __autocommit:Bool = true;
	@:noCompletion private var __isolationLevel:PostgresIsolationLevel = PostgresIsolationLevel.REPEATABLE_READ;
	@:noCompletion private var __lastInsertRowID:Float = 0;
	@:noCompletion private var __lastAffectedRows:Float = 0;
	@:noCompletion private var __savepoints:Array<String> = [];
	@:noCompletion private var __savepointSeq:Int = 0;
	// The command tag of the last request(), where the driver reports one.
	@:noCompletion private var __lastCommand:String = null;

	public function new() {
		super();
	}

	/**
		Connects, and dispatches `SQLEvent.OPEN`. On a connection already
		open, the connection it had is closed first, dispatching `CLOSE`, as
		`MySQLConnection.open()` does. It was replaced and left open,
		unreachable, a server connection held for the life of the process
		each time a reconnect or a pool factory opened twice.

		@throws IOError When the server cannot be reached or refuses.
	**/
	public function open(cfg:PostgresConfig):Void {
		__requireSupported();
		if (cfg == null) {
			throw "PostgresConnection: config is required.";
		}

		#if cpp
		if (__nativeHandle != null) {
			close();
		}
		#else
		if (__connection != null) {
			close();
		}
		#end

		#if cpp
		// Outside the try: a setting that cannot be expressed is a mistake in
		// the config, not a failure to connect, and should read as one.
		var conninfo:String = PostgresConnInfo.build(cfg);

		try {
			var handle:VoidPointer = NativePostgres.open(conninfo, __libraryCandidates(cfg));
			// Read from the handle rather than from anything shared: the reason
			// used to be one process-wide string, so connections opening on
			// several pool workers at once could each report another's failure.
			var failure:String = NativePostgres.error(handle);

			if (failure != null && failure != "") {
				NativePostgres.close(handle);
				throw new IOError(failure);
			}

			__nativeHandle = handle;
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
			// Taken out under the lock, so a cancel() already running finishes
			// with the handle before it is freed, and one arriving later finds
			// nothing to cancel.
			__handleLock.acquire();
			var handle:VoidPointer = __nativeHandle;
			__nativeHandle = null;
			__handleLock.release();

			NativePostgres.close(handle);
			__inTransaction = false;
			// The session it belonged to is gone; the next starts with it on.
			__autocommit = true;
			__dispatchEvent(new SQLEvent(SQLEvent.CLOSE));
		}
		#end

		if (__connection != null) {
			__connection = null;
			__inTransaction = false;
			__autocommit = true;
			__dispatchEvent(new SQLEvent(SQLEvent.CLOSE));
		}
	}

	public function ping():Bool {
		// No handle check of its own: request() already refuses without the
		// handle this target uses, and that refusal lands in the catch. This
		// used to test __connection, which only the php target sets, so on cpp
		// every connection answered false without the server being asked,
		// and a pool validating with ping() would discard each one it made.
		try {
			__request("SELECT 1;", false);
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	/**
		Starts a transaction.

		Throws an `SQLError` when the server refuses, after dispatching it as
		an `SQLErrorEvent` too. So do `commit`, `rollback` and the savepoint
		methods. They used to dispatch the event and return, which made a
		failed transaction indistinguishable from a successful one to any
		caller that did not listen for it: `AsyncDatabase.transaction` completed
		as success and `SchemaMigrator` recorded a migration that had been
		rolled back.
	**/
	public function begin():Void {
		try {
			__request("BEGIN;", false);
		} catch (e:Dynamic) {
			__fail(SQLEvent.BEGIN, "Begin failed", e);
		}

		__inTransaction = true;
		__savepoints = [];
		__dispatchEvent(new SQLEvent(SQLEvent.BEGIN));
	}

	/**
		Commits the transaction, or throws an `SQLError` saying why it did not.

		That includes a COMMIT the server accepted without committing: one sent
		after a statement in the transaction failed succeeds, with the command
		tag ROLLBACK, and everything in the transaction is discarded. That
		reads as success everywhere but in the tag, so it is reported as the
		failure it is. The tag is read on the native driver; PDO does not
		expose it.

		Either way the transaction is over afterwards, PostgreSQL ends it on
		a failed COMMIT as surely as on a successful one, so `inTransaction`
		is `false` whichever way this returns, unless `autocommit` is off.
	**/
	public function commit():Void {
		var failure:Dynamic = null;

		try {
			__request("COMMIT;", false);

			if (__lastCommand == "ROLLBACK") {
				failure = "a statement in the transaction had failed, so the server rolled it back instead of committing it";
			}
		} catch (e:Dynamic) {
			failure = e;
		}

		__inTransaction = false;
		__savepoints = [];

		if (failure != null) {
			__fail(SQLEvent.COMMIT, "Commit failed", failure);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.COMMIT));
	}

	public function rollback():Void {
		var failure:Dynamic = null;

		try {
			__request("ROLLBACK;", false);
		} catch (e:Dynamic) {
			failure = e;
		}

		// A ROLLBACK that fails has lost the connection, and the server ends
		// the transaction with it.
		__inTransaction = false;
		__savepoints = [];

		if (failure != null) {
			__fail(SQLEvent.ROLLBACK, "Rollback failed", failure);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK));
	}

	/**
		Creates a savepoint and returns its name, so one created without a name
		can still be released or rolled back to. It returned nothing, which
		left a generated name known only to the statement that used it, and
		release and rollback both require a name, so such a savepoint could
		never be reached again by any means.
	**/
	public function setSavepoint(name:String = null):String {
		var sp:String = __sanitizeSavePoint(name);

		try {
			__request('SAVEPOINT ' + sp + ';', false);
		} catch (e:Dynamic) {
			__fail(SQLEvent.SET_SAVEPOINT, "Savepoint failed", e);
		}

		// Recorded only once the server has it, so a savepoint that failed is
		// not the one a nameless release or rollback reaches for next.
		__savepoints.push(sp);
		__dispatchEvent(new SQLEvent(SQLEvent.SET_SAVEPOINT));
		return sp;
	}

	/**
		Rolls back to a savepoint, which stays active afterwards as PostgreSQL
		leaves it. With no name, rolls back to the innermost savepoint this
		connection holds, and only to a full rollback() when it holds none.
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
			__request('ROLLBACK TO SAVEPOINT ' + sp + ';', false);
		} catch (e:Dynamic) {
			__fail(SQLEvent.ROLLBACK_TO_SAVEPOINT, "Rollback to savepoint failed", e);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.ROLLBACK_TO_SAVEPOINT));
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
			__request('RELEASE SAVEPOINT ' + sp + ';', false);
		} catch (e:Dynamic) {
			__fail(SQLEvent.RELEASE_SAVEPOINT, "Release savepoint failed", e);
		}

		__dispatchEvent(new SQLEvent(SQLEvent.RELEASE_SAVEPOINT));
	}

	/**
		Runs `sql` and answers its rows. Throws an `SQLError` when the server
		refuses it or the connection is not open, as `requestParams()` and
		the other drivers' `request()` do; it threw an `IOError` for a refusal
		and a `String` for a connection not open, so code catching `SQLError`
		caught neither.
	**/
	public function request(sql:String):Dynamic {
		return __request(sql, true);
	}

	/**
		`request()`, and the connection's own statements, its transaction
		control, `ping()`, the settings it reads and writes, which pass
		`implicitBegin` false: none of them may begin a transaction for
		`autocommit` off.
	**/
	@:noCompletion private function __request(sql:String, implicitBegin:Bool):Dynamic {
		__requireConnected();

		if (implicitBegin && !__autocommit && !__inTransaction) {
			__beginImplicitly();
		}

		#if cpp
		var rawJson = NativePostgres.requestJson(__nativeHandle, sql);
		__syncTransaction();
		var parsed:Dynamic = Json.parse(rawJson == null || rawJson == "" ? "{\"rows\":[],\"affectedRows\":0,\"lastInsertRowID\":0}" : rawJson);
		var errorMessage:Dynamic = Reflect.field(parsed, "error");
		if (errorMessage != null) {
			var detail:String = Std.string(errorMessage);
			throw new SQLError("request", detail, detail);
		}

		var rows:Array<Dynamic> = __toRows(Reflect.field(parsed, "rows"));
		__lastAffectedRows = __count(Reflect.field(parsed, "affectedRows"));
		__lastInsertRowID = __count(Reflect.field(parsed, "lastInsertRowID"));
		__lastCommand = Reflect.field(parsed, "command");
		return new PostgresResultSet(rows);
		#else
		var statement:Dynamic = null;
		var rows:Array<Dynamic> = [];
		__lastAffectedRows = 0;
		__lastCommand = null;

		try {
			statement = __connection.query(sql);
		} catch (e:Dynamic) {
			var detail:String = Std.string(e);
			throw new SQLError("request", detail, detail);
		}

		try {
			var rawRows:Dynamic = statement.fetchAll();
			rows = __toRows(rawRows);
			__lastAffectedRows = __rowCount(statement);
		} catch (_:Dynamic) {
			try {
				var updated:Dynamic = __connection.exec(sql);
				__lastAffectedRows = __count(updated);
			} catch (e:Dynamic) {
				var detail:String = Std.string(e);
				throw new SQLError("request", detail, detail);
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
		applied to it, and no escaping can carry a NUL byte, because
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

		if (!__autocommit && !__inTransaction) {
			__beginImplicitly();
		}

		#if cpp
		var encoded:Bytes = PostgresWire.encodeParameters(params == null ? [] : params);
		// One call, and the block it returns is this call's own. It used to be
		// a length from one call and then the bytes from a second, read a byte
		// at a time out of a buffer every connection in the process shared,
		// so between the two another thread's query could replace it.
		var data:haxe.io.BytesData = NativePostgres.requestParams(__nativeHandle, sql == null ? "" : sql, encoded.getData(), encoded.length);
		__syncTransaction();

		if (data == null) {
			throw new IOError("Postgres bridge returned no result block.");
		}

		// Raises the server message for an error block, so a failed statement
		// cannot read as a statement that matched nothing.
		var result:PostgresRawResult = PostgresWire.decodeResult(Bytes.ofData(data));
		__lastAffectedRows = result.affectedRows;
		__lastInsertRowID = result.lastInsertRowID;
		return result;
		#else
		throw new IOError("Bound parameters need the native libpq bridge, which this target does not have.");
		#end
	}

	/**
		Asks the server to abandon the statement this connection is running.

		Safe to call from any thread, which is the point: the thread that sent
		the statement is blocked waiting for its answer, so it is another one,
		a watchdog, a request that was abandoned, a shutdown, that decides
		to stop it. The statement then fails on its own thread with the
		server's "canceling statement due to user request".

		Returns whether the request reached the server. That is not a promise
		the statement was stopped: one that finished in the meantime simply
		completes, and a cancel with nothing running does nothing. For a limit
		on every statement rather than an intervention in one, set
		`PostgresConfig.statementTimeout`.

		Needs the native driver; elsewhere it returns `false`.
	**/
	public function cancel():Bool {
		#if cpp
		__handleLock.acquire();

		var sent:Bool = false;

		try {
			sent = __nativeHandle != null && NativePostgres.cancel(__nativeHandle);
		} catch (e:Dynamic) {
			__handleLock.release();
			throw e;
		}

		__handleLock.release();
		return sent;
		#else
		return false;
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

	/**
		True while `autocommit` is off as well, as MySQL documents a session
		with autocommit off: every statement is part of a transaction that
		only `commit()` or `rollback()` ends, and the next statement begins
		another. `ConnectionPool` therefore rolls back, and retires, a
		connection handed back that way.
	**/
	private function get_inTransaction():Bool {
		return __inTransaction || !__autocommit;
	}

	/**
		Begins the transaction a statement runs in while `autocommit` is off.
		PostgreSQL has had no setting for that on the server since 7.4, so
		the client begins it, as JDBC and psql do.
	**/
	@:noCompletion private function __beginImplicitly():Void {
		__request("BEGIN;", false);
		__inTransaction = true;
		__savepoints = [];
	}

	#if cpp
	/**
		Takes the transaction state from the server after a statement. The
		server reports it at the end of every one, and libpq keeps it, so
		asking costs no round trip. The flag used to change only in `begin()`,
		`commit()` and `rollback()`, and a transaction opened with
		`request("BEGIN;")` read as none, so a pool returning the connection
		saw nothing to roll back, and handed the transaction to the next
		borrower.
	**/
	@:noCompletion private function __syncTransaction():Void {
		switch (NativePostgres.transactionStatus(__nativeHandle)) {
			case 2 | 3:
				// In a transaction, or in one a failed statement has aborted,
				// which still has to be rolled back.
				__inTransaction = true;
			case 0:
				if (__inTransaction) {
					__inTransaction = false;
					__savepoints = [];
				}
			default:
				// Mid-statement, a broken connection, or a libpq without the
				// call: nothing better than what is already known.
		}
	}
	#end

	private function get_lastInsertRowID():Float {
		return __lastInsertRowID;
	}

	private function get_affectedRows():Float {
		return __lastAffectedRows;
	}

	private function get_serverVersion():String {
		try {
			var rs = __request("SHOW server_version;", false);
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
		if (v && !__autocommit && __inTransaction) {
			// Turned back on: what is open is committed, as MySQL commits it
			// when autocommit is set again. A commit the server refused
			// throws, and autocommit stays off.
			commit();
		}

		__autocommit = v;
		return v;
	}

	private function get_isolationLevel():PostgresIsolationLevel {
		try {
			var rs = __request("SHOW transaction_isolation;", false);
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

	/**
		Sets the level of the session's transactions from the next one on,
		as MySQL's setter does. Throws the `SQLError` when the server refuses,
		inside a transaction a failed statement has aborted, say, where
		it swallowed the refusal, so the level read as set while the session
		went on at the old one. Never begins a transaction itself: one that
		`autocommit` off began and then rolled back would take the setting
		with it.
	**/
	private function set_isolationLevel(v:PostgresIsolationLevel):PostgresIsolationLevel {
		__request("SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL " + v + ";", false);
		__isolationLevel = v;
		return v;
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
		var open:Bool = __nativeHandle != null;
		#else
		var open:Bool = __connection != null;
		#end

		if (!open) {
			throw new SQLError("request", "PostgresConnection: not open.", "PostgresConnection: not open.");
		}
	}

	@:noCompletion private function __lastInsertId():Float {
		if (__connection == null) {
			return __lastInsertRowID;
		}
		try {
			return __count(__connection.lastInsertId());
		} catch (_:Dynamic) {
			return __lastInsertRowID;
		}
	}

	@:noCompletion private function __rowCount(statement:Dynamic):Float {
		try {
			return __count(statement.rowCount());
		} catch (_:Dynamic) {
			return 0;
		}
	}

	/**
		A count or id from the driver as a whole number, exact to 2^53: an
		`Int`, a `Float`, what JSON makes of a number past 32 bits, or
		digits as text. It was `Std.parseInt`, which past 2^31 answers
		differently on every target, and never the number.
	**/
	@:noCompletion private static function __count(value:Dynamic):Float {
		if (value == null) {
			return 0;
		}

		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			return value;
		}

		var parsed:Float = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? 0 : parsed;
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

	/**
		Reports a failed transaction step both ways: as the `SQLErrorEvent` it
		always was, for listeners, and as the `SQLError` it now throws, so a
		caller that does not listen cannot mistake it for success.
	**/
	@:noCompletion private function __fail(op:String, msg:String, e:Dynamic):Void {
		var detail:String = Std.string(e);
		var error:SQLError = new SQLError(op, detail, msg + ": " + detail);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
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
		meaning inside an ordinary string literal, so doubling it as well,
		which this used to do, turned every one into two: a value of
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
		// Runtime: this file is not cpp-only, it builds for eval, the JVM and
		// Node, and `#if windows` is unset on all three, so a Windows host
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
