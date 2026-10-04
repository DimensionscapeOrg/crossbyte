package crossbyte.db.mysql;

// Not built for any JavaScript target (Node included, which has no a database driver): a database driver needs a socket or a file, and credentials do not belong in a page.
#if !js

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.SQLError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
import sys.db.Connection;
import sys.db.ResultSet;
#if cpp
import crossbyte.db.mysql._internal.NativeMySQL;
import crossbyte.db.mysql._internal.NativeMySQLConnection;
#else
import sys.db.Mysql;
#end

/**
 * MySQL connection wrapper. On cpp it drives the client hxcpp bundles
 * directly, and reads the session state the server reports after every
 * statement; elsewhere it runs on Haxe's `sys.db.Mysql`.
 *
 * **What a server can send.** The native client takes the server's answers
 * as untrusted, since under the default `sslMode` whoever answers in the
 * server's place writes them. A result has from 1 to 65,535 columns, counted
 * before anything is allocated; every length is checked against the packet
 * it is in; and an answer no server sends, a count or length past those,
 * a column without a name, a row that does not match its columns, a
 * request for a file of the client's, fails the statement with a
 * `MySQLError` of code 2027 (`CR_MALFORMED_PACKET`) and closes the
 * connection, which cannot be followed past it. Each of those ended the
 * process, or allocated a gigabyte, from a packet of a few bytes. What the
 * client holds is then what the server sends: `request()` reads a result
 * whole, so a result without end is held without end, where
 * `MySQLStatement` reads rows as they are asked for. Other targets use
 * their own clients, which these bounds are not.
 */
class MySQLConnection extends EventDispatcher implements crossbyte.db.ITransactionalConnection {
	// The client character sets MySQL accepts that the escaping here is safe
	// for. ucs2, utf16 and utf32 were listed too, and MySQL refuses them as a
	// client character set, so SET NAMES failed on the server.
	private static final ALLOWED_CHARSETS = ["utf8mb4", "utf8mb3", "utf8", "latin1", "ascii"];

	public var connected(get, null):Bool;

	/**
		Whether a transaction is open. On cpp this is the server's own
		account, from the status flags of its last reply, so a transaction
		begun as SQL text, `request("START TRANSACTION")`, counts as
		surely as one begun with `begin()`. So does a session with autocommit
		turned off, which MySQL documents as always having a transaction
		open: every statement joins it until a COMMIT or ROLLBACK, after
		which the next one starts.

		The flag used to change only in `begin()`, `commit()` and
		`rollback()`. A connection handed back to a `ConnectionPool` after
		`autocommit = false` or a `START TRANSACTION` sent as SQL read as idle,
		was not rolled back, and the next borrower's `begin()` committed the
		abandoned work, MySQL commits an open transaction implicitly when a
		new one starts.

		Where the driver cannot read the server's flags (a target other than
		cpp) it follows `begin()`, `commit()`, `rollback()`, the `autocommit`
		setter, and those statements when they are sent as text.
	**/
	public var inTransaction(get, null):Bool;

	/**
		The AUTO_INCREMENT id the last statement generated: a `Float`, exact
		to 2^53 on every target. Natively it comes with the statement's
		answer; each read used to be a `SELECT LAST_INSERT_ID()`.

		Elsewhere it comes from Haxe's driver, which holds an `Int`: one that
		cannot be right there, negative, or 2^31 and past, is asked for
		in SQL, as text, as the SQLite driver does. On hl and neko, whose
		drivers read it in 32 bits, it is asked for so every time, which is
		the round trip their own read made: one past 2^32 wrapped back into
		range there, and was taken as it was.

		It was an `Int`, held at 2^31 - 1.
	**/
	public var lastInsertRowID(get, null):Float;

	/**
		The rows the last statement changed, as the server counts them: a
		`Float`, exact to 2^53. Natively from the statement's answer, where a
		`SELECT ROW_COUNT()` used to be sent for each read, and read after
		`getResult()`, which sent a statement of its own, it answered -1.
		Elsewhere `ROW_COUNT()` is asked as text: -1 after a statement that
		changes no rows, as MySQL counts it.

		It was an `Int`, held at 2^31 - 1 natively, and elsewhere read with
		`Std.parseInt`, which past 2^31 answers differently on every target.
	**/
	public var affectedRows(get, null):Float;
	public var serverVersion(get, null):String;
	public var autocommit(get, set):Bool;
	public var isolationLevel(get, set):IsolationLevel;

	/**
		Whether the session runs over TLS, which, with `sslMode` left at
		`PREFERRED`, is up to the server. Native client only; `false`
		elsewhere.
	**/
	public var encrypted(get, never):Bool;

	@:noCompletion private var __connection:Connection;
	#if cpp
	// The same object as __connection when the native client is in use, and
	// null when a test has put a connection of its own there.
	@:noCompletion private var __native:NativeMySQLConnection;
	#end
	@:noCompletion private var __inTransaction:Bool = false;
	// What the driver knows of autocommit where the server cannot be asked
	// for its flags; MySQL starts every session with it on.
	@:noCompletion private var __autocommitOff:Bool = false;
	// The same for NO_BACKSLASH_ESCAPES, which a session starts without
	// unless the server's default sql_mode has it.
	@:noCompletion private var __noBackslashEscapes:Bool = false;
	// Savepoints this connection holds, innermost last, for the nameless
	// forms of rollbackToSavepoint() and releaseSavepoint().
	@:noCompletion private var __savepoints:Array<String> = [];
	@:noCompletion private var __savepointSeq:Int = 0;
	// For cancel(), which runs on another thread and opens a connection of
	// its own: what to connect with, and the id to KILL. Both are set once,
	// when the connection opens, and read-only after.
	@:noCompletion private var __config:MySQLConfig;
	@:noCompletion private var __threadId:Float = 0;
	// Off cpp: the last statement's generated id is not the one Haxe's
	// driver kept, and has to be asked for; see request().
	@:noCompletion private var __insertIdStale:Bool = false;

	public function new() {
		super();
	}

	/**
		Connects and sets the session up: the character set, time zone and
		SQL mode `cfg` names. Throws an `ArgumentError` for a charset it will
		not send, before connecting, and an `IOError`, a
		`MySQLConnectionError`, with the error number and SQLSTATE, when the
		server refuses the connection or any of the settings.

		A connection whose setup failed is closed before the error leaves.
		It was left open, for the collector, or for good, so a pool
		factory retrying an open that could never succeed piled up server
		connections. And `timeZone` and `sqlMode` could never succeed: their
		values were escaped into a buffer that was then thrown away, and the
		server was sent `SET time_zone = :tz;`.

		On hl the server is first tried with a plain connection of the
		client's own, closed at once, and one that cannot be reached is
		refused without HashLink's mysql library: that library frees a
		connection that failed to open twice, and corrupts the process heap
		doing it. A login the server refuses still reaches it.
	**/
	public function open(cfg:MySQLConfig):Void {
		var charset:String = null;

		if (cfg.charset != null && cfg.charset != "") {
			charset = cfg.charset.toLowerCase();

			if (ALLOWED_CHARSETS.indexOf(charset) == -1) {
				throw new ArgumentError("Unsupported charset: " + cfg.charset);
			}
		}

		#if !cpp
		// The client here has no TLS. A mode that insists on it fails as the
		// native client fails against a server offering none, before anything
		// is sent, where it used to connect in the clear, password and all.
		if (cfg.sslMode != null && cfg.sslMode.toCode() >= MySQLSSLMode.REQUIRED.toCode()) {
			throw new MySQLConnectionError("sslMode " + cfg.sslMode + " needs TLS, and only the native client has it", 2026);
		}
		#end

		if (__connection != null) {
			// Opened again: the connection it had would otherwise stay open,
			// unreachable.
			close();
		}

		#if hl
		__reach(cfg);
		#end

		try {
			#if cpp
			var sslMode:MySQLSSLMode = cfg.sslMode == null ? MySQLSSLMode.PREFERRED : cfg.sslMode;
			__native = NativeMySQLConnection.connect({
				host: cfg.host,
				port: cfg.port == null ? 3306 : cfg.port,
				user: cfg.user,
				pass: cfg.password,
				socket: cfg.socket,
				sslMode: sslMode.toCode(),
				sslCa: cfg.sslCa,
				serverPublicKey: cfg.serverPublicKey,
				allowPublicKeyRetrieval: cfg.allowPublicKeyRetrieval == true,
				connectTimeout: cfg.connectTimeout == null ? 10.0 : cfg.connectTimeout,
				readTimeout: cfg.readTimeout == null ? 0.0 : cfg.readTimeout,
				writeTimeout: cfg.writeTimeout == null ? 0.0 : cfg.writeTimeout,
				keepAlive: cfg.keepAlive != false,
				keepAliveIdle: cfg.keepAliveIdle == null ? 60 : cfg.keepAliveIdle,
				keepAliveInterval: cfg.keepAliveInterval == null ? 10 : cfg.keepAliveInterval,
				keepAliveCount: cfg.keepAliveCount == null ? 6 : cfg.keepAliveCount
			}, cfg.database);
			__connection = __native;
			__threadId = __native.threadId;
			#else
			__connection = Mysql.connect({
				host: cfg.host,
				port: cfg.port,
				user: cfg.user,
				pass: cfg.password,
				database: cfg.database,
				socket: cfg.socket
			});
			#end
		} catch (e:Dynamic) {
			// An IOError still, with the error number and SQLSTATE: 1045 for
			// a refused login, 1049 for an unknown database, 2003 for a server
			// that could not be reached.
			if (Std.isOfType(e, MySQLError)) {
				var cause:MySQLError = e;
				throw new MySQLConnectionError(cause.message, cause.code, cause.sqlState);
			}

			throw new MySQLConnectionError(Std.string(e));
		}

		__config = cfg;

		try {
			if (charset != null) {
				request("SET NAMES " + charset + ";");
			}

			if (cfg.timeZone != null && cfg.timeZone != "") {
				request("SET time_zone = " + __connection.quote(cfg.timeZone) + ";");
			}

			if (cfg.sqlMode != null && cfg.sqlMode != "") {
				request("SET SESSION sql_mode = " + __connection.quote(cfg.sqlMode) + ";");
			}
		} catch (e:Dynamic) {
			var cause:MySQLError = __error("open", e);
			__abandon();
			throw new MySQLConnectionError(cause.message, cause.code, cause.sqlState);
		}

		__dispatch(SQLEvent.OPEN);
	}

	/**
		Closes a connection that never finished opening, so no `CLOSE` is
		dispatched for an `OPEN` that was not.
	**/
	@:noCompletion private function __abandon():Void {
		try {
			__connection.close();
		} catch (_:Dynamic) {}

		__connection = null;
		#if cpp
		__native = null;
		#end
		__inTransaction = false;
		__autocommitOff = false;
		__noBackslashEscapes = false;
		__savepoints = [];
		__config = null;
		__threadId = 0;
	}

	#if hl
	/**
		Refuses, before HashLink's mysql library is asked to connect, what
		that library would fail to connect to. When its connect fails it
		frees the connection it made and leaves the collector a finalizer
		that frees it again: a double free, often into memory the heap has
		since given to someone else, and the process dies of heap corruption
		at some later allocation. So a server that cannot be reached, what
		a pool retrying against a restarting database meets again and again,
		is found here with a connection of its own, which is closed
		before the library opens one, and a Unix socket, which the library
		refuses outright, is refused here.

		A login the server refuses still reaches the library; only a fix
		there spares that one.
	**/
	@:noCompletion private static function __reach(cfg:MySQLConfig):Void {
		if (cfg.socket != null && cfg.socket != "") {
			throw new MySQLConnectionError("Unix Socket connections are not supported");
		}

		var port:Int = cfg.port == null ? 3306 : cfg.port;
		var host:sys.net.Host;

		try {
			host = new sys.net.Host(cfg.host);
		} catch (e:Dynamic) {
			throw new MySQLConnectionError("Unknown MySQL server host '" + cfg.host + "': " + Std.string(e), 2005);
		}

		var probe:sys.net.Socket = new sys.net.Socket();

		try {
			probe.connect(host, port);
		} catch (e:Dynamic) {
			try {
				probe.close();
			} catch (_:Dynamic) {}

			throw new MySQLConnectionError("Can't connect to MySQL server on '" + cfg.host + ":" + port + "': " + Std.string(e), 2003);
		}

		probe.close();
	}
	#end

	public function close():Void {
		if (__connection != null) {
			try {
				__connection.close();
				__dispatch(SQLEvent.CLOSE);
			} catch (e:Dynamic) {
				__dispatchError(SQLEvent.CLOSE, "Close failed", e);
			}

			__connection = null;
			#if cpp
			__native = null;
			#end
			__inTransaction = false;
			__autocommitOff = false;
			__noBackslashEscapes = false;
			__savepoints = [];
			__config = null;
			__threadId = 0;
		}
	}

	/**
		Whether the server answers. Natively a COM_PING, a round trip with no
		statement for the server to parse; elsewhere `SELECT 1`.
	**/
	public function ping():Bool {
		try {
			if (__connection == null) {
				return false;
			}

			#if cpp
			if (__native != null) {
				return __native.ping();
			}
			#end

			__connection.request("SELECT 1;");
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	/**
		Asks the server to stop the statement this connection is running,
		with `KILL QUERY` sent over a second connection opened for the
		purpose.

		Safe to call from any thread, which is the point: the thread that sent
		the statement is blocked waiting for its answer, so it is another one,
		a watchdog, a request that was abandoned, a shutdown, that decides
		to stop it. The statement then fails on its own thread with a
		`MySQLError` 1317, "Query execution was interrupted", and this
		connection stays usable.

		Returns whether the KILL was accepted, which is not a promise the
		statement was stopped: one that finished in the meantime completes,
		and a KILL with nothing running does nothing. It connects as the same
		user, which MySQL lets kill its own statements. Needs the native
		driver; elsewhere it returns `false`.
	**/
	public function cancel():Bool {
		#if cpp
		var config:MySQLConfig = __config;
		var id:Float = __threadId;

		if (config == null || id <= 0) {
			return false;
		}

		var killer:MySQLConnection = new MySQLConnection();

		try {
			killer.open({
				host: config.host,
				port: config.port,
				user: config.user,
				password: config.password,
				database: null,
				socket: config.socket,
				sslMode: config.sslMode,
				sslCa: config.sslCa,
				serverPublicKey: config.serverPublicKey,
				allowPublicKeyRetrieval: config.allowPublicKeyRetrieval,
				connectTimeout: config.connectTimeout,
				readTimeout: 10.0,
				writeTimeout: 10.0
			});
			// The id is a number the server gave, never text from anywhere
			// else, so it is written as one, through Int64, since a
			// connection id is unsigned 32-bit and Std.int would overflow on
			// a server that has handed out more than 2^31 of them.
			killer.request("KILL QUERY " + haxe.Int64.toStr(haxe.Int64.fromFloat(id)));
			killer.close();
			return true;
		} catch (_:Dynamic) {
			try {
				killer.close();
			} catch (_:Dynamic) {}

			return false;
		}
		#else
		return false;
		#end
	}

	// Transactions. Each throws an `SQLError` when the server refuses, after
	// dispatching it as an `SQLErrorEvent` as well. They used to dispatch and
	// return, so a failed COMMIT read as a committed one to every caller that
	// was not listening, `AsyncDatabase.transaction` and `SchemaMigrator`
	// among them, the way SQLiteConnection, which throws, never did.
	public function begin():Void {
		try {
			request("START TRANSACTION;");
		} catch (e:Dynamic) {
			__fail(SQLEvent.BEGIN, "Begin failed", e);
		}

		__inTransaction = true;
		__savepoints = [];
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
			request("COMMIT;");
		} catch (e:Dynamic) {
			__fail(SQLEvent.COMMIT, "Commit failed", e);
		}

		__inTransaction = false;
		__savepoints = [];
		__dispatch(SQLEvent.COMMIT);
	}

	public function rollback():Void {
		var failure:Dynamic = null;

		try {
			request("ROLLBACK;");
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

		__dispatch(SQLEvent.ROLLBACK);
	}

	/**
		Creates a savepoint and returns its name, so one created without a
		name can still be released or rolled back to. It returned nothing, and
		the name it made came from the clock, identical for two made within
		a microsecond, and past `Int` about 36 minutes into a process.
	**/
	public function setSavepoint(name:String = null):String {
		var sp:String = __sanitizeSavePoint(name);

		try {
			request('SAVEPOINT ' + sp + ';');
		} catch (e:Dynamic) {
			__fail(SQLEvent.SET_SAVEPOINT, "Savepoint failed", e);
		}

		// Recorded only once the server has it, so a savepoint that failed is
		// not the one a nameless release or rollback reaches for next.
		__savepoints.push(sp);
		__dispatch(SQLEvent.SET_SAVEPOINT);
		return sp;
	}

	/**
		Rolls back to a savepoint, which stays active afterwards as MySQL
		leaves it. With no name, rolls back to the innermost savepoint this
		connection holds, and only to a full `rollback()` when it holds none.
		Omitting the name rolled the whole transaction back, so a caller asking
		to return to a savepoint lost everything before it instead.
	**/
	public function rollbackToSavepoint(name:String = null):Void {
		if ((name == null || name == "") && __savepoints.length == 0) {
			rollback();
			return;
		}

		var sp:String = __takeSavepoint(name, true);

		try {
			request('ROLLBACK TO SAVEPOINT ' + sp + ';');
		} catch (e:Dynamic) {
			__fail(SQLEvent.ROLLBACK_TO_SAVEPOINT, "Rollback to savepoint failed", e);
		}

		__dispatch(SQLEvent.ROLLBACK_TO_SAVEPOINT);
	}

	/**
		Releases a savepoint, discarding it and any nested inside it. With no
		name, releases the innermost this connection holds; it used to invent a
		fresh name and ask the server to release a savepoint that had never
		existed.
	**/
	public function releaseSavepoint(name:String = null):Void {
		var sp:String = __takeSavepoint(name, false);

		try {
			request('RELEASE SAVEPOINT ' + sp + ';');
		} catch (e:Dynamic) {
			__fail(SQLEvent.RELEASE_SAVEPOINT, "Release savepoint failed", e);
		}

		__dispatch(SQLEvent.RELEASE_SAVEPOINT);
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

	/**
		Escapes `value` for use inside a single-quoted literal, by the rules
		the session is using: a quote doubled once the server has reported
		`NO_BACKSLASH_ESCAPES`, backslash-escaped otherwise, with NUL, newline,
		carriage return, backslash, both quotes and Ctrl-Z escaped as MySQL's
		own client escapes them. Natively the session's mode comes from the
		server with every reply; elsewhere from the `sql_mode` statements this
		connection has sent.

		Prefer `MySQLStatement.parameters`, which quote for you and carry
		`null`, numbers and bytes as well as strings.
	**/
	public function escape(value:String):String {
		var text:String = value == null ? "" : value;

		#if cpp
		if (__native != null) {
			return __native.escape(text);
		}
		#end

		return __escapeText(text, __backslashEscapes());
	}

	/** `value`, escaped by `escape()` and quoted. **/
	public function quote(value:String):String {
		return "'" + escape(value) + "'";
	}

	/**
		Whether the session reads a backslash inside a literal as an escape:
		MySQL's default, and not under `NO_BACKSLASH_ESCAPES`.
	**/
	@:noCompletion private function __backslashEscapes():Bool {
		#if cpp
		if (__native != null) {
			try {
				return (__native.serverStatus & NativeMySQL.STATUS_NO_BACKSLASH_ESCAPES) == 0;
			} catch (_:Dynamic) {}
		}
		#end

		return !__noBackslashEscapes;
	}

	@:noCompletion private static function __escapeText(text:String, backslashes:Bool):String {
		var out:StringBuf = new StringBuf();

		for (i in 0...text.length) {
			var c:Int = StringTools.fastCodeAt(text, i);

			if (!backslashes) {
				out.addChar(c);

				if (c == "'".code) {
					out.addChar(c);
				}

				continue;
			}

			switch (c) {
				case 0:
					out.add("\\0");
				case 10:
					out.add("\\n");
				case 13:
					out.add("\\r");
				case 26:
					out.add("\\Z");
				case 34, 39, 92:
					out.addChar(92);
					out.addChar(c);
				default:
					out.addChar(c);
			}
		}

		return out.toString();
	}

	/**
		Runs `sql` and returns its result. Throws a `MySQLError`, with the
		error number and SQLSTATE where the driver reports them, when the
		server refuses it or the connection fails.
	**/
	public function request(sql:String):ResultSet {
		if (__connection == null) {
			throw new MySQLError("request", "MySQLConnection: not open.", "MySQLConnection: not open.", 2006, "HY000");
		}

		try {
			#if cpp
			if (__native != null) {
				var answer:ResultSet = __native.request(sql);

				// A transaction ended by SQL text takes its savepoints with it.
				if (__savepoints.length > 0 && !get_inTransaction()) {
					__savepoints = [];
				}

				return answer;
			}
			#end

			__insertIdStale = false;
			var result:ResultSet = __connection.request(sql);
			__noteStatement(sql);
			return result;
		} catch (e:Dynamic) {
			#if (java || jvm)
			if (__generatedKeyOverflowed(e, sql)) {
				// The statement ran, and committed; only reading its key
				// failed. The key is asked for in SQL when it is wanted.
				__insertIdStale = true;
				__noteStatement(sql);
				return new NoRows();
			}
			#end

			throw __error("request", e);
		}
	}

	#if (java || jvm)
	/**
		Whether `e` is Haxe's JDBC binding failing to read an insert's
		generated key as an `Int`: it reads a single insert's key with
		`getInt`, after the insert has run, and Connector/J refuses a value
		past 2^31 with SQLSTATE 22003 and no error number, so an insert
		that had committed was reported as failed. The server's own 22003, a
		value out of range for its column, carries MySQL's error number
		(1264) and is a failure as before.
	**/
	@:noCompletion private static function __generatedKeyOverflowed(e:Dynamic, sql:String):Bool {
		if (!Std.isOfType(e, java.sql.SQLException)) {
			return false;
		}

		var failure:java.sql.SQLException = cast e;

		if (failure.getSQLState() != "22003" || failure.getErrorCode() != 0 || sql == null) {
			return false;
		}

		var verb:String = StringTools.trim(sql).substr(0, 7).toUpperCase();
		return StringTools.startsWith(verb, "INSERT") || StringTools.startsWith(verb, "REPLACE");
	}
	#end

	/**
		What went wrong, as a `MySQLError`: the error number and SQLSTATE the
		native client kept of the failure, or of an error that already is one.
	**/
	@:noCompletion private function __error(operation:String, e:Dynamic):MySQLError {
		if (Std.isOfType(e, MySQLError)) {
			return e;
		}

		var detail:String = Std.string(e);
		var code:Int = 0;
		var state:String = "HY000";

		#if cpp
		if (__native != null) {
			try {
				code = __native.errorCode;
				state = __native.sqlState;
			} catch (_:Dynamic) {}
		}
		#elseif java
		// JDBC's failure carries both, and was passed on whole where a String
		// was expected: every MySQL failure on the jvm surfaced as a
		// ClassCastException instead, and a listener never ran.
		if (Std.isOfType(e, java.sql.SQLException)) {
			var failure:java.sql.SQLException = cast e;
			code = failure.getErrorCode();
			state = failure.getSQLState();
			var message:String = failure.getMessage();
			detail = message == null ? detail : message;
		}
		#end

		return new MySQLError(operation, detail, detail, code, state);
	}

	/**
		Follows the statements that open and close a transaction or switch
		autocommit, for a connection whose server flags cannot be read. Only
		after the statement succeeded, so one the server refused changes
		nothing. Costs a look at the first character for any other statement.
	**/
	@:noCompletion private function __noteStatement(sql:String):Void {
		if (sql == null) {
			return;
		}

		var start:Int = 0;

		while (start < sql.length && StringTools.isSpace(sql, start)) {
			start++;
		}

		if (start >= sql.length) {
			return;
		}

		var first:Int = StringTools.fastCodeAt(sql, start) | 0x20;

		if (first != "s".code && first != "b".code && first != "c".code && first != "r".code) {
			return;
		}

		var words:Array<String> = ~/[\s;=]+/g.split(StringTools.trim(sql).toUpperCase()).filter(w -> w != "");

		if (words.length == 0) {
			return;
		}

		switch (words[0]) {
			case "BEGIN":
				if (words.length == 1 || words[1] == "WORK") {
					__inTransaction = true;
				}
			case "START":
				if (words.length > 1 && words[1] == "TRANSACTION") {
					__inTransaction = true;
				}
			case "COMMIT":
				__inTransaction = false;
				__savepoints = [];
			case "ROLLBACK":
				if (words.length == 1 || words[1] == "WORK") {
					__inTransaction = false;
					__savepoints = [];
				}
			case "SET":
				for (word in words) {
					if (word.indexOf("SQL_MODE") >= 0) {
						// The whole new mode is in the statement; whether it
						// names the one flag the escaping depends on is all
						// that is needed of it.
						__noBackslashEscapes = sql.toUpperCase().indexOf("NO_BACKSLASH_ESCAPES") >= 0;
						break;
					}
				}

				var at:Int = words.indexOf("AUTOCOMMIT");

				if (at < 0) {
					at = words.indexOf("@@AUTOCOMMIT");
				}

				if (at >= 0 && at + 1 < words.length) {
					var value:String = words[at + 1];

					if (value == "0" || value == "OFF") {
						__autocommitOff = true;
					} else if (value == "1" || value == "ON") {
						// Turning autocommit on commits whatever was open.
						__autocommitOff = false;
						__inTransaction = false;
					}
				}
			default:
		}
	}

	private function get_encrypted():Bool {
		#if cpp
		if (__native != null) {
			return __native.encrypted;
		}
		#end

		return false;
	}

	private function get_connected():Bool {
		return __connection != null && ping();
	}

	private function get_inTransaction():Bool {
		#if cpp
		if (__native != null) {
			var status:Int = __native.serverStatus;
			return (status & NativeMySQL.STATUS_IN_TRANS) != 0 || (status & NativeMySQL.STATUS_AUTOCOMMIT) == 0;
		}
		#end

		return __inTransaction || __autocommitOff;
	}

	private function get_lastInsertRowID():Float {
		return __insertIdFloat();
	}

	private function get_affectedRows():Float {
		if (__connection == null) {
			return 0;
		}

		#if cpp
		if (__native != null) {
			return __whole(__native.affectedRows);
		}
		#end

		var rs:ResultSet = __connection.request("SELECT CAST(ROW_COUNT() AS CHAR) AS n");
		return (rs != null && rs.hasNext()) ? __parseWhole(Std.string(Reflect.field(rs.next(), "n"))) : 0;
	}

	/**
		The rows the statement just answered with `result` changed, as the
		server counts them, for a `MySQLStatement` to keep before another
		statement replaces the count: a `Float`, exact to 2^53, and 0 for a
		statement that returns rows, as AIR's `SQLResult.rowsAffected` has
		it. Natively from the statement's own answer, at no cost. Elsewhere
		the driver's count, an `Int`, where it can be right, and otherwise,
		negative, held at 2^31 - 1, or none at all, as Haxe's JDBC binding
		keeps none, asked in SQL as text. On hl and neko, whose drivers read
		it in 32 bits, a count past 2^32 wraps back into range there and is
		taken as it is.
	**/
	@:noCompletion private function __affectedBy(result:ResultSet):Float {
		#if cpp
		if (__native != null) {
			return __whole(__native.affectedRows);
		}
		#end

		if (result != null && result.nfields != 0) {
			return 0;
		}

		var count:Int = -1;

		try {
			if (result != null) {
				count = result.length;
			}
		} catch (_:Dynamic) {
			// The jvm's binding, whose result for a write holds no count and
			// throws for one.
		}

		return count >= 0 && count < 0x7FFFFFFF ? count : get_affectedRows();
	}

	/** A count or id the native client gives, an `Int`, or an `Int64` past 2^31, as a `Float`, exact to 2^53. **/
	@:noCompletion private static function __whole(value:Dynamic):Float {
		if (value == null) {
			return 0;
		}

		if (haxe.Int64.isInt64(value)) {
			var wide:haxe.Int64 = value;
			var low:Float = wide.low < 0 ? wide.low + 4294967296.0 : wide.low;
			return wide.high * 4294967296.0 + low;
		}

		var number:Float = value;
		return number;
	}

	/**
		Decimal digits, with a sign, as a whole number: exact to 2^53, where
		`Std.parseInt` answers each target differently past 2^31. 0 for
		anything else.
	**/
	@:noCompletion private static function __parseWhole(text:String):Float {
		var negative:Bool = text.length > 0 && StringTools.fastCodeAt(text, 0) == "-".code;
		// 0.0, not 0: eval does a Float seeded with an Int literal's
		// arithmetic in wrapping Int, and 3000000000 came out -1294967296.
		var value:Float = 0.0;

		for (i in (negative ? 1 : 0)...text.length) {
			var digit:Int = StringTools.fastCodeAt(text, i) - "0".code;

			if (digit < 0 || digit > 9) {
				return 0;
			}

			value = value * 10 + digit;
		}

		return negative ? -value : value;
	}

	private function get_serverVersion():String {
		if (__connection == null) {
			return "";
		}

		#if cpp
		if (__native != null) {
			// From the greeting, so there is nothing to ask.
			return __native.serverVersion;
		}
		#end

		var rs:ResultSet = __connection.request("SELECT VERSION() AS v;");

		return (rs != null && rs.hasNext()) ? Std.string(Reflect.field(rs.next(), "v")) : "";
	}

	/** The last generated id, exact to 2^53, for `SQLResult`. **/
	@:noCompletion private function __insertIdFloat():Float {
		#if cpp
		if (__native != null) {
			return __whole(__native.insertId);
		}
		#end

		if (__connection == null) {
			return 0;
		}

		#if !(hl || neko)
		// hl's and neko's lastInsertId() is a SELECT LAST_INSERT_ID() read in
		// 32 bits, past 2^32 wrapped back into range, where nothing here can
		// tell: there it is asked as text instead, the same round trip.
		if (!__insertIdStale) {
			var id:Null<Int> = null;

			try {
				id = __connection.lastInsertId();
			} catch (_:Dynamic) {
				// A driver whose own read of it overflowed.
			}

			if (id != null && id >= 0 && id < 0x7FFFFFFF) {
				return id;
			}
		}
		#end

		return __lastInsertIdBySQL();
	}

	/**
		`LAST_INSERT_ID()`, asked as text so no driver narrows it on the way:
		exact to 2^53. It was the driver's `Int`, wrapped past 2^31 on hl and
		neko, and on the jvm thrown for, after the insert had run.
	**/
	@:noCompletion private function __lastInsertIdBySQL():Float {
		var rows:ResultSet = request("SELECT CAST(LAST_INSERT_ID() AS CHAR) AS id");

		if (rows == null || !rows.hasNext()) {
			return 0;
		}

		return __parseWhole(Std.string(Reflect.field(rows.next(), "id")));
	}

	/**
		`request()`, with the rows read as they are asked for where the driver
		can: natively a result is no longer read whole before its first row
		is returned. Used by `MySQLStatement`.
	**/
	@:noCompletion private function __requestStream(sql:String):ResultSet {
		#if cpp
		if (__native != null) {
			try {
				var answer:ResultSet = __native.requestStream(sql);

				if (__savepoints.length > 0 && !get_inTransaction()) {
					__savepoints = [];
				}

				return answer;
			} catch (e:Dynamic) {
				throw __error("request", e);
			}
		}
		#end

		return request(sql);
	}

	private function get_autocommit():Bool {
		if (__connection == null) {
			return true;
		}

		#if cpp
		if (__native != null) {
			// Reported with every reply, so there is nothing to ask.
			return (__native.serverStatus & NativeMySQL.STATUS_AUTOCOMMIT) != 0;
		}
		#end

		var rs:ResultSet = __connection.request("SELECT @@autocommit AS ac;");

		return (rs != null && rs.hasNext()) ? (Std.parseInt(Std.string(Reflect.field(rs.next(), "ac"))) == 1) : true;
	}

	private function set_autocommit(v:Bool):Bool {
		if (__connection != null) {
			request("SET autocommit = " + (v ? "1" : "0") + ";");
		}

		return v;
	}

	private function get_isolationLevel():IsolationLevel {
		if (__connection == null) {
			return IsolationLevel.REPEATABLE_READ;
		}
		var rs:ResultSet;

		try {
			rs = request("SELECT @@transaction_isolation AS lvl;");
		} catch (_:Dynamic) {
			// The name MySQL before 5.7.20 and MariaDB before 11.1 give it;
			// both refuse @@transaction_isolation as an unknown variable.
			rs = request("SELECT @@tx_isolation AS lvl;");
		}

		if (rs != null && rs.hasNext()) {
			var s:String = Std.string(Reflect.field(rs.next(), "lvl"));
			return s; // let the enum-abstract coerce
		}

		return IsolationLevel.REPEATABLE_READ;
	}

	/**
		Sets the level of the session's transactions from the next one on.
		Throws the `MySQLError` the server refused it with, as every other
		statement does: it went round `request()`, so what the driver threw
		escaped as itself, on the jvm a `java.sql.SQLException`.
	**/
	private function set_isolationLevel(v:IsolationLevel):IsolationLevel {
		if (__connection != null) {
			request("SET SESSION TRANSACTION ISOLATION LEVEL " + v + ";");
		}

		return v;
	}

	@:noCompletion private function __sanitizeSavePoint(name:String):String {
		// A counter, not a timestamp: haxe.Timer.stamp() in microseconds
		// through Std.int collided for names made back to back, and passed
		// Int about 36 minutes into a process. Two savepoints sharing a name
		// make RELEASE and ROLLBACK TO act on the wrong one.
		var n:String = (name != null && name != "") ? name : ("sp_" + (++__savepointSeq));
		return ~/[^\w]/g.replace(n, "_");
	}

	@:noCompletion private inline function __dispatch(t:String):Void {
		__dispatchEvent(new SQLEvent(t));
	}

	@:noCompletion private function __dispatchError(op:String, msg:String, e:Dynamic):Void {
		var cause:MySQLError = __error(op, e);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new MySQLError(op, cause.details(), msg, cause.code, cause.sqlState)));
	}

	/**
		Reports a failed transaction step both ways: as the `SQLErrorEvent` it
		always was, and as the `SQLError` it now throws, a `MySQLError`,
		carrying the error number and SQLSTATE of what failed.
	**/
	@:noCompletion private function __fail(op:String, msg:String, e:Dynamic):Void {
		var cause:MySQLError = __error(op, e);
		var detail:String = cause.details();
		var error:MySQLError = new MySQLError(op, detail, msg + ": " + detail, cause.code, cause.sqlState);
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, error));
		throw error;
	}
}

#if (java || jvm)
/** What an insert answers: no rows, as Haxe's JDBC binding would have answered it. **/
@:noCompletion
private class NoRows implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	public function new() {}

	private function get_length():Int {
		return 0;
	}

	private function get_nfields():Int {
		return 0;
	}

	public function hasNext():Bool {
		return false;
	}

	public function next():Dynamic {
		return null;
	}

	public function results():List<Dynamic> {
		return new List();
	}

	public function getResult(n:Int):String {
		throw "No rows.";
	}

	public function getIntResult(n:Int):Int {
		throw "No rows.";
	}

	public function getFloatResult(n:Int):Float {
		throw "No rows.";
	}

	public function getFieldsNames():Null<Array<String>> {
		return null;
	}
}
#end
#end
