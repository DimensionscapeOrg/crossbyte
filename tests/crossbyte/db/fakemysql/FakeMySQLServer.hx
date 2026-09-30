package crossbyte.db.fakemysql;

#if cpp
import haxe.crypto.Sha1;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

/**
 * A MySQL server that speaks just enough of the client/server protocol to
 * drive the native client, and records every packet it is sent.
 *
 * The native suite has no database, and the one CI job that does runs a
 * single server version with its defaults. What the client sends, byte for
 * byte, and what it makes of an answer, a status flag, an auth switch, a
 * column of a type the server chose, are only observable against a server
 * the test controls, so this is that server: a listener on 127.0.0.1, port 0,
 * with a thread per connection, answering from `onQuery` and falling back to
 * a small model of MySQL's own session state.
 *
 * `FakeMySQLServer` and its sessions only ever run on their own threads; a
 * test reads what they saw through `queries()` and `events()`, which copy
 * under a lock. The client call that sent a statement has returned by the
 * time the statement is in the log, because the log is written before the
 * answer is.
 */
class FakeMySQLServer {
	public static inline var TYPE_DECIMAL:Int = 0x00;
	public static inline var TYPE_TINY:Int = 0x01;
	public static inline var TYPE_SHORT:Int = 0x02;
	public static inline var TYPE_LONG:Int = 0x03;
	public static inline var TYPE_FLOAT:Int = 0x04;
	public static inline var TYPE_DOUBLE:Int = 0x05;
	public static inline var TYPE_NULL:Int = 0x06;
	public static inline var TYPE_TIMESTAMP:Int = 0x07;
	public static inline var TYPE_LONGLONG:Int = 0x08;
	public static inline var TYPE_INT24:Int = 0x09;
	public static inline var TYPE_DATE:Int = 0x0A;
	public static inline var TYPE_TIME:Int = 0x0B;
	public static inline var TYPE_DATETIME:Int = 0x0C;
	public static inline var TYPE_YEAR:Int = 0x0D;
	public static inline var TYPE_BIT:Int = 0x10;
	public static inline var TYPE_NEWDECIMAL:Int = 0xF6;
	public static inline var TYPE_BLOB:Int = 0xFC;
	public static inline var TYPE_VAR_STRING:Int = 0xFD;
	public static inline var TYPE_STRING:Int = 0xFE;

	public static inline var FLAG_NOT_NULL:Int = 1;
	public static inline var FLAG_UNSIGNED:Int = 32;
	public static inline var FLAG_BINARY:Int = 128;

	public static inline var STATUS_IN_TRANS:Int = 0x0001;
	public static inline var STATUS_AUTOCOMMIT:Int = 0x0002;
	public static inline var STATUS_NO_BACKSLASH_ESCAPES:Int = 0x0200;

	public static inline var CLIENT_CONNECT_WITH_DB:Int = 0x00000008;
	public static inline var CLIENT_PROTOCOL_41:Int = 0x00000200;
	public static inline var CLIENT_SSL:Int = 0x00000800;
	public static inline var CLIENT_TRANSACTIONS:Int = 0x00002000;
	public static inline var CLIENT_SECURE_CONNECTION:Int = 0x00008000;
	public static inline var CLIENT_PLUGIN_AUTH:Int = 0x00080000;
	public static inline var CLIENT_PLUGIN_AUTH_LENENC:Int = 0x00200000;

	public static inline var CHARSET_BINARY:Int = 63;
	public static inline var CHARSET_UTF8MB4:Int = 45;
	public static inline var CHARSET_UTF8MB4_0900:Int = 255;

	/** The port the server listens on, once `start()` has returned. **/
	public var port(default, null):Int = 0;

	/** Collation id sent in the greeting. **/
	public var charset:Int = CHARSET_UTF8MB4;

	public var serverVersion:String = "8.0.36-fake";

	/** The auth plugin the greeting names. **/
	public var plugin:String = "mysql_native_password";

	/**
	 * Capability flags the greeting advertises. `CLIENT_SSL` is added when
	 * `tlsCertificatePath` is set.
	 */
	public var capabilities:Int = 0x0000F7FF | CLIENT_PLUGIN_AUTH | CLIENT_PLUGIN_AUTH_LENENC;

	/** Status flags each new session starts with. **/
	public var initialStatus:Int = STATUS_AUTOCOMMIT;

	/**
	 * The account's password. `null` accepts any handshake without checking
	 * it, as the tests that are not about authentication want.
	 */
	public var password:Null<String> = null;

	/**
	 * For `caching_sha2_password`: whether the server has this account in its
	 * cache, so a correct scramble is enough (fast auth), or asks for the
	 * password itself (full auth).
	 */
	public var cachedAccount:Bool = true;

	/**
	 * An auth plugin to switch the client to after its handshake response,
	 * as a server does when the account uses another plugin than the one its
	 * greeting named.
	 */
	public var switchTo:Null<String> = null;

	/** PEM files for the TLS side, and the RSA key full auth decrypts with. **/
	public var tlsCertificatePath:Null<String> = null;

	public var tlsKeyPath:Null<String> = null;

	/** Seconds to wait before sending the greeting, for connect timeouts. **/
	public var greetingDelay:Float = 0;

	/**
	 * When not 0, a packet longer than this many bytes stops its session
	 * reading as soon as the packet's header arrives, a server that takes
	 * no more of what it is sent, for write timeouts, and the session
	 * closes `stallSeconds` later.
	 */
	public var stallOnPacketsOver:Int = 0;

	public var stallSeconds:Float = 5;

	/**
	 * Answers a COM_QUERY. Returns `false` to leave it to the default model,
	 * which tracks transactions, autocommit and `NO_BACKSLASH_ESCAPES` the way
	 * the server reports them in its status flags.
	 */
	public var onQuery:(session:FakeMySQLSession, sql:String) -> Bool = null;

	@:noCompletion private var __listener:Socket;
	@:noCompletion private var __stopping:Bool = false;
	@:noCompletion private var __lock:Mutex = new Mutex();
	@:noCompletion private var __events:Array<FakeMySQLEvent> = [];
	@:noCompletion private var __sessions:Array<FakeMySQLSession> = [];
	@:noCompletion private var __acceptDone:Lock = new Lock();
	/**
	 * The connection id the next session is given, sent as the greeting's
	 * thread id. Set negative for an id past 2^31, as the greeting's four
	 * bytes read unsigned.
	 */
	public var nextConnectionId:Int = 100;

	public function new() {}

	public function start():FakeMySQLServer {
		if (tlsCertificatePath != null) {
			capabilities |= CLIENT_SSL;
		}

		__listener = new Socket();
		__listener.bind(new Host("127.0.0.1"), 0);
		__listener.listen(16);
		port = __listener.host().port;

		Thread.create(__acceptLoop);
		return this;
	}

	/** Stops accepting, and closes every session still open. **/
	public function stop():Void {
		if (__listener == null) {
			return;
		}

		__stopping = true;
		__acceptDone.wait(5.0);

		__lock.acquire();
		var sessions:Array<FakeMySQLSession> = __sessions.copy();
		__lock.release();

		for (session in sessions) {
			session.__abort();
		}

		for (session in sessions) {
			session.__finished.wait(5.0);
		}

		try {
			__listener.close();
		} catch (_:Dynamic) {}

		__listener = null;
	}

	/** Every COM_QUERY received, in order, across all connections. **/
	public function queries():Array<String> {
		var out:Array<String> = [];

		for (event in events()) {
			if (event.kind == "query") {
				out.push(event.text);
			}
		}

		return out;
	}

	/** The last COM_QUERY received, or `null`. **/
	public function lastQuery():Null<String> {
		var all:Array<String> = queries();
		return all.length == 0 ? null : all[all.length - 1];
	}

	/** A copy of everything logged so far. **/
	public function events():Array<FakeMySQLEvent> {
		__lock.acquire();
		var copy:Array<FakeMySQLEvent> = __events.copy();
		__lock.release();
		return copy;
	}

	/** The events of one kind, in order. **/
	public function eventsOf(kind:String):Array<FakeMySQLEvent> {
		return events().filter(e -> e.kind == kind);
	}

	/**
	 * Waits, on the calling thread, until `predicate` holds for the log or
	 * `seconds` pass. For what a client does after its call has returned,
	 * a COM_QUIT sent by `close()`, a second connection sent by `cancel()`.
	 */
	public function waitFor(predicate:Array<FakeMySQLEvent>->Bool, seconds:Float = 5.0):Bool {
		var deadline:Float = haxe.Timer.stamp() + seconds;

		while (haxe.Timer.stamp() < deadline) {
			if (predicate(events())) {
				return true;
			}

			crossbyte.sys.System.sleep(0.005);
		}

		return predicate(events());
	}

	/** The session with this connection id, read unsigned, while it is open. **/
	public function session(id:Float):Null<FakeMySQLSession> {
		__lock.acquire();
		var found:Null<FakeMySQLSession> = null;

		for (candidate in __sessions) {
			var unsigned:Float = candidate.id < 0 ? candidate.id + 4294967296.0 : candidate.id;

			if (unsigned == id) {
				found = candidate;
			}
		}

		__lock.release();
		return found;
	}

	@:noCompletion public function __log(event:FakeMySQLEvent):Void {
		__lock.acquire();
		__events.push(event);
		__lock.release();
	}

	@:noCompletion private function __acceptLoop():Void {
		while (!__stopping) {
			var ready:Array<Socket>;

			try {
				ready = Socket.select([__listener], null, null, 0.02).read;
			} catch (_:Dynamic) {
				break;
			}

			if (ready.length == 0) {
				continue;
			}

			var client:Socket;

			try {
				client = __listener.accept();
			} catch (_:Dynamic) {
				continue;
			}

			__lock.acquire();
			var id:Int = nextConnectionId++;
			var session:FakeMySQLSession = new FakeMySQLSession(this, client, id);
			__sessions.push(session);
			__lock.release();

			Thread.create(session.__threadMain);
		}

		__acceptDone.release();
	}

	/**
	 * The scramble full auth decrypts with `openssl`, since the client's
	 * RSA-OAEP is the part of `caching_sha2_password` a mistake in would
	 * only show against a real server otherwise.
	 */
	@:noCompletion public function __decryptWithKey(ciphertext:Bytes):Null<Bytes> {
		if (tlsKeyPath == null) {
			return null;
		}

		var directory:String = haxe.io.Path.directory(tlsKeyPath);
		var stamp:String = Std.string(Std.random(0x7FFFFFFF));
		var input:String = haxe.io.Path.join([directory, "rsa-in-" + stamp + ".bin"]);
		var output:String = haxe.io.Path.join([directory, "rsa-out-" + stamp + ".bin"]);

		try {
			sys.io.File.saveBytes(input, ciphertext);
			var exit:Int = Sys.command("openssl", [
				"pkeyutl", "-decrypt", "-inkey", tlsKeyPath, "-pkeyopt", "rsa_padding_mode:oaep", "-in", input, "-out", output
			]);
			var plain:Null<Bytes> = exit == 0 ? sys.io.File.getBytes(output) : null;
			__deleteQuietly(input);
			__deleteQuietly(output);
			return plain;
		} catch (_:Dynamic) {
			__deleteQuietly(input);
			__deleteQuietly(output);
			return null;
		}
	}

	/** The RSA public key matching `tlsKeyPath`, as MySQL sends it. **/
	@:noCompletion public function __publicKeyPem():Null<String> {
		if (tlsKeyPath == null) {
			return null;
		}

		var directory:String = haxe.io.Path.directory(tlsKeyPath);
		var output:String = haxe.io.Path.join([directory, "rsa-pub-" + Std.random(0x7FFFFFFF) + ".pem"]);

		try {
			var exit:Int = Sys.command("openssl", ["pkey", "-in", tlsKeyPath, "-pubout", "-out", output]);
			var pem:Null<String> = exit == 0 ? sys.io.File.getContent(output) : null;
			__deleteQuietly(output);
			return pem;
		} catch (_:Dynamic) {
			__deleteQuietly(output);
			return null;
		}
	}

	private static function __deleteQuietly(path:String):Void {
		try {
			if (sys.FileSystem.exists(path)) {
				sys.FileSystem.deleteFile(path);
			}
		} catch (_:Dynamic) {}
	}

	// ------------------------------------------------------------------ wire

	public static function lenenc(out:BytesBuffer, n:Float):Void {
		if (n < 251) {
			out.addByte(Std.int(n));
		} else if (n < 0x10000) {
			out.addByte(0xFC);
			out.addByte(Std.int(n) & 0xFF);
			out.addByte((Std.int(n) >> 8) & 0xFF);
		} else if (n < 0x1000000) {
			out.addByte(0xFD);
			out.addByte(Std.int(n) & 0xFF);
			out.addByte((Std.int(n) >> 8) & 0xFF);
			out.addByte((Std.int(n) >> 16) & 0xFF);
		} else {
			out.addByte(0xFE);
			var low:Float = n % 4294967296.0;
			var high:Float = Math.ffloor(n / 4294967296.0);
			__addUInt32(out, low);
			__addUInt32(out, high);
		}
	}

	public static function lenencString(out:BytesBuffer, value:Bytes):Void {
		lenenc(out, value.length);
		out.add(value);
	}

	private static function __addUInt32(out:BytesBuffer, value:Float):Void {
		var v:Float = value;
		for (_ in 0...4) {
			var b:Int = Std.int(v % 256.0);
			out.addByte(b);
			v = Math.ffloor(v / 256.0);
		}
	}

	public static function sha1(b:Bytes):Bytes {
		return Sha1.make(b);
	}

	public static function sha256(b:Bytes):Bytes {
		return Sha256.make(b);
	}

	public static function xor(a:Bytes, b:Bytes):Bytes {
		var out:Bytes = Bytes.alloc(a.length);
		for (i in 0...a.length) {
			out.set(i, a.get(i) ^ b.get(i % b.length));
		}
		return out;
	}

	public static function concat(a:Bytes, b:Bytes):Bytes {
		var out:Bytes = Bytes.alloc(a.length + b.length);
		out.blit(0, a, 0, a.length);
		out.blit(a.length, b, 0, b.length);
		return out;
	}

	/** What `mysql_native_password` expects for `password` and `nonce`. **/
	public static function nativeScramble(password:String, nonce:Bytes):Bytes {
		var stage1:Bytes = sha1(Bytes.ofString(password));
		var stage2:Bytes = sha1(stage1);
		return xor(stage1, sha1(concat(nonce, stage2)));
	}

	/** What `caching_sha2_password` fast auth expects. **/
	public static function sha2Scramble(password:String, nonce:Bytes):Bytes {
		var stage1:Bytes = sha256(Bytes.ofString(password));
		var stage2:Bytes = sha256(stage1);
		return xor(stage1, sha256(concat(stage2, nonce)));
	}
}

typedef FakeMySQLEvent = {
	var connection:Int;
	var kind:String;
	@:optional var text:String;
	@:optional var bytes:Bytes;
	@:optional var command:Int;
	@:optional var flags:Int;
	@:optional var charset:Int;
	@:optional var user:String;
	@:optional var database:String;
	@:optional var plugin:String;
	@:optional var authResponse:Bytes;
};

typedef FakeColumn = {
	var name:String;
	var type:Int;
	@:optional var flags:Int;
	@:optional var charset:Int;
	@:optional var length:Int;
	@:optional var decimals:Int;
};

/** One client connection, on its own thread. **/
class FakeMySQLSession {
	/** Connection id, sent as the thread id in the greeting. **/
	public var id(default, null):Int;

	/** Status flags sent with the next OK or EOF. **/
	public var status:Int;

	/** Set by a KILL QUERY naming this session, from another one. **/
	public var killed:Bool = false;

	public var server(default, null):FakeMySQLServer;

	@:noCompletion public var __finished:Lock = new Lock();

	@:noCompletion private var __socket:Socket;
	@:noCompletion private var __ssl:Dynamic = null;
	@:noCompletion private var __sslConf:Dynamic = null;
	@:noCompletion private var __nonce:Bytes;
	@:noCompletion private var __clientFlags:Int = 0;
	@:noCompletion private var __closed:Bool = false;

	public function new(server:FakeMySQLServer, socket:Socket, id:Int) {
		this.server = server;
		this.id = id;
		__socket = socket;
		status = server.initialStatus;
		__nonce = Bytes.ofString("abcdefghijklmnopqrst");
	}

	@:noCompletion public function __abort():Void {
		__closed = true;

		try {
			__socket.shutdown(true, true);
		} catch (_:Dynamic) {}
	}

	@:noCompletion public function __threadMain():Void {
		try {
			__serve();
		} catch (_:Dynamic) {}

		try {
			if (__ssl != null) {
				cpp.NativeSsl.ssl_close(__ssl);
			}
		} catch (_:Dynamic) {}

		try {
			__socket.close();
		} catch (_:Dynamic) {}

		server.__log({connection: id, kind: "closed"});
		__finished.release();
	}

	@:noCompletion private function __serve():Void {
		if (server.greetingDelay > 0) {
			crossbyte.sys.System.sleep(server.greetingDelay);
		}

		__sendGreeting();

		var response:Packet = __readPacket();

		if (response == null) {
			return;
		}

		var flags:Int = response.payload.getInt32(0);

		if ((flags & FakeMySQLServer.CLIENT_SSL) != 0 && response.payload.length == 32) {
			server.__log({connection: id, kind: "ssl request", flags: flags});
			__startTls();
			response = __readPacket();

			if (response == null) {
				return;
			}
		}

		if (!__authenticate(response)) {
			return;
		}

		while (!__closed) {
			var packet:Packet = __readPacket();

			if (packet == null || packet.payload.length == 0) {
				return;
			}

			var command:Int = packet.payload.get(0);
			var body:Bytes = packet.payload.sub(1, packet.payload.length - 1);
			var text:String = body.getString(0, body.length, UTF8);

			switch (command) {
				case 0x01: // COM_QUIT
					server.__log({connection: id, kind: "quit", command: command});
					return;
				case 0x03: // COM_QUERY
					server.__log({connection: id, kind: "query", command: command, text: text, bytes: body});

					if (server.onQuery == null || !server.onQuery(this, text)) {
						defaultAnswer(text);
					}
				case 0x02: // COM_INIT_DB
					server.__log({connection: id, kind: "init db", command: command, text: text, bytes: body});
					ok();
				case 0x0E: // COM_PING
					server.__log({connection: id, kind: "ping", command: command});
					ok();
				default:
					server.__log({connection: id, kind: "command", command: command, bytes: body});
					ok();
			}
		}
	}

	/**
	 * MySQL's own account of a session's state, as far as a status flag
	 * shows it: a transaction opened by `START TRANSACTION` or `BEGIN`, or
	 * implicitly by any statement while autocommit is off; ended by `COMMIT`,
	 * `ROLLBACK` or turning autocommit back on.
	 */
	public function defaultAnswer(sql:String):Void {
		var upper:String = StringTools.trim(sql).toUpperCase();

		if (StringTools.endsWith(upper, ";")) {
			upper = upper.substr(0, upper.length - 1);
		}

		var compact:String = ~/\s+/g.replace(upper, " ");

		if (compact == "START TRANSACTION" || compact == "BEGIN") {
			status |= FakeMySQLServer.STATUS_IN_TRANS;
		} else if (compact == "COMMIT" || compact == "ROLLBACK") {
			status &= ~FakeMySQLServer.STATUS_IN_TRANS;
		} else if (compact == "SET AUTOCOMMIT = 0" || compact == "SET AUTOCOMMIT=0") {
			status &= ~FakeMySQLServer.STATUS_AUTOCOMMIT;
		} else if (compact == "SET AUTOCOMMIT = 1" || compact == "SET AUTOCOMMIT=1") {
			status |= FakeMySQLServer.STATUS_AUTOCOMMIT;
			status &= ~FakeMySQLServer.STATUS_IN_TRANS;
		} else if (compact.indexOf("SQL_MODE") >= 0) {
			if (compact.indexOf("NO_BACKSLASH_ESCAPES") >= 0) {
				status |= FakeMySQLServer.STATUS_NO_BACKSLASH_ESCAPES;
			} else {
				status &= ~FakeMySQLServer.STATUS_NO_BACKSLASH_ESCAPES;
			}
		} else if ((status & FakeMySQLServer.STATUS_AUTOCOMMIT) == 0 && !StringTools.startsWith(compact, "SET ")) {
			status |= FakeMySQLServer.STATUS_IN_TRANS;
		}

		if (StringTools.startsWith(compact, "KILL QUERY ")) {
			var target:Null<FakeMySQLSession> = server.session(Std.parseFloat(compact.substr(11)));

			if (target == null) {
				error(1094, "HY000", "Unknown thread id");
			} else {
				target.killed = true;
				ok();
			}
			return;
		}

		if (StringTools.startsWith(compact, "SELECT SLEEP(")) {
			var seconds:Float = Std.parseFloat(compact.substr(13));

			if (interruptible(seconds)) {
				error(1317, "70100", "Query execution was interrupted");
			} else {
				resultSet([{name: "SLEEP", type: FakeMySQLServer.TYPE_LONGLONG, charset: FakeMySQLServer.CHARSET_BINARY}], [["0"]]);
			}
			return;
		}

		if (StringTools.startsWith(compact, "SELECT 1")) {
			resultSet([{name: "1", type: FakeMySQLServer.TYPE_LONGLONG, charset: FakeMySQLServer.CHARSET_BINARY}], [["1"]]);
			return;
		}

		if (StringTools.startsWith(compact, "SELECT LAST_INSERT_ID()")) {
			resultSet([{name: "LAST_INSERT_ID()", type: FakeMySQLServer.TYPE_LONGLONG, flags: FakeMySQLServer.FLAG_UNSIGNED,
				charset: FakeMySQLServer.CHARSET_BINARY}], [[Std.string(lastInsertId)]]);
			return;
		}

		if (StringTools.startsWith(compact, "SELECT ROW_COUNT()")) {
			resultSet([{name: "n", type: FakeMySQLServer.TYPE_LONGLONG, charset: FakeMySQLServer.CHARSET_BINARY}], [[Std.string(lastAffectedRows)]]);
			return;
		}

		if (StringTools.startsWith(compact, "SELECT VERSION()")) {
			resultSet([{name: "v", type: FakeMySQLServer.TYPE_VAR_STRING}], [[server.serverVersion]]);
			return;
		}

		if (StringTools.startsWith(compact, "SELECT @@AUTOCOMMIT")) {
			resultSet([{name: "ac", type: FakeMySQLServer.TYPE_LONGLONG, charset: FakeMySQLServer.CHARSET_BINARY}],
				[[(status & FakeMySQLServer.STATUS_AUTOCOMMIT) != 0 ? "1" : "0"]]);
			return;
		}

		if (StringTools.startsWith(compact, "INSERT") || StringTools.startsWith(compact, "UPDATE") || StringTools.startsWith(compact, "DELETE")) {
			lastAffectedRows = 1;
			lastInsertId = StringTools.startsWith(compact, "INSERT") ? 42 : 0;
			ok(lastAffectedRows, lastInsertId);
			return;
		}

		lastAffectedRows = 0;
		ok();
	}

	/** What `LAST_INSERT_ID()` and `ROW_COUNT()` answer, as the server keeps them per session. **/
	public var lastInsertId:Float = 0;

	public var lastAffectedRows:Float = 0;

	// --------------------------------------------------------------- answers

	public function ok(affectedRows:Float = 0, insertId:Float = 0, warnings:Int = 0):Void {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte(0x00);
		FakeMySQLServer.lenenc(out, affectedRows);
		FakeMySQLServer.lenenc(out, insertId);
		out.addByte(status & 0xFF);
		out.addByte((status >> 8) & 0xFF);
		out.addByte(warnings & 0xFF);
		out.addByte((warnings >> 8) & 0xFF);
		send(1, out.getBytes());
	}

	public function error(code:Int, sqlState:String, message:String, sequence:Int = 1):Void {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte(0xFF);
		out.addByte(code & 0xFF);
		out.addByte((code >> 8) & 0xFF);
		out.addString("#" + sqlState);
		out.addString(message, UTF8);
		send(sequence, out.getBytes());
	}

	/**
	 * A text-protocol result set. A `null` value is SQL NULL. `pauseAfter`
	 * rows in, the rest waits `pauseSeconds`, which is how a test tells a
	 * result read as it arrives from one read whole first.
	 */
	public function resultSet(columns:Array<FakeColumn>, rows:Array<Array<Null<String>>>, ?pauseAfter:Int, pauseSeconds:Float = 0,
			?dropAfter:Int):Void {
		var sequence:Int = 1;
		var head:BytesBuffer = new BytesBuffer();
		FakeMySQLServer.lenenc(head, columns.length);
		send(sequence++, head.getBytes());

		for (column in columns) {
			send(sequence++, __columnDefinition(column));
		}

		send(sequence++, __eof());

		for (i in 0...rows.length) {
			if (dropAfter != null && i == dropAfter) {
				__abort();
				return;
			}

			if (pauseAfter != null && i == pauseAfter && pauseSeconds > 0) {
				crossbyte.sys.System.sleep(pauseSeconds);
			}

			var row:BytesBuffer = new BytesBuffer();

			for (value in rows[i]) {
				if (value == null) {
					row.addByte(0xFB);
				} else {
					FakeMySQLServer.lenencString(row, Bytes.ofString(value, UTF8));
				}
			}

			send(sequence++, row.getBytes());
		}

		send(sequence++, __eof());
	}

	/** Raw row bytes, for values a String cannot carry. **/
	public function resultSetBytes(columns:Array<FakeColumn>, rows:Array<Array<Null<Bytes>>>):Void {
		var sequence:Int = 1;
		var head:BytesBuffer = new BytesBuffer();
		FakeMySQLServer.lenenc(head, columns.length);
		send(sequence++, head.getBytes());

		for (column in columns) {
			send(sequence++, __columnDefinition(column));
		}

		send(sequence++, __eof());

		for (values in rows) {
			var row:BytesBuffer = new BytesBuffer();

			for (value in values) {
				if (value == null) {
					row.addByte(0xFB);
				} else {
					FakeMySQLServer.lenencString(row, value);
				}
			}

			send(sequence++, row.getBytes());
		}

		send(sequence++, __eof());
	}

	/**
		Waits `seconds`, or until a KILL QUERY names this session; says which.
	**/
	public function interruptible(seconds:Float):Bool {
		var deadline:Float = haxe.Timer.stamp() + seconds;

		while (!__closed && haxe.Timer.stamp() < deadline) {
			if (killed) {
				killed = false;
				return true;
			}

			crossbyte.sys.System.sleep(0.005);
		}

		return false;
	}

	/** Never answers: for read timeouts and cancellation. **/
	public function hang(seconds:Float):Void {
		var deadline:Float = haxe.Timer.stamp() + seconds;

		while (!__closed && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.01);
		}
	}

	public function send(sequence:Int, payload:Bytes):Void {
		var out:Bytes = Bytes.alloc(4 + payload.length);
		out.set(0, payload.length & 0xFF);
		out.set(1, (payload.length >> 8) & 0xFF);
		out.set(2, (payload.length >> 16) & 0xFF);
		out.set(3, sequence & 0xFF);
		out.blit(4, payload, 0, payload.length);
		__write(out);
	}

	@:noCompletion private function __eof():Bytes {
		var out:Bytes = Bytes.alloc(5);
		out.set(0, 0xFE);
		out.set(1, 0);
		out.set(2, 0);
		out.set(3, status & 0xFF);
		out.set(4, (status >> 8) & 0xFF);
		return out;
	}

	@:noCompletion private function __columnDefinition(column:FakeColumn):Bytes {
		var out:BytesBuffer = new BytesBuffer();
		FakeMySQLServer.lenencString(out, Bytes.ofString("def"));
		FakeMySQLServer.lenencString(out, Bytes.ofString("app"));
		FakeMySQLServer.lenencString(out, Bytes.ofString("t"));
		FakeMySQLServer.lenencString(out, Bytes.ofString("t"));
		FakeMySQLServer.lenencString(out, Bytes.ofString(column.name, UTF8));
		FakeMySQLServer.lenencString(out, Bytes.ofString(column.name, UTF8));
		out.addByte(0x0C);
		var charset:Int = column.charset == null ? FakeMySQLServer.CHARSET_UTF8MB4 : column.charset;
		out.addByte(charset & 0xFF);
		out.addByte((charset >> 8) & 0xFF);
		var length:Int = column.length == null ? 255 : column.length;
		out.addByte(length & 0xFF);
		out.addByte((length >> 8) & 0xFF);
		out.addByte((length >> 16) & 0xFF);
		out.addByte((length >> 24) & 0xFF);
		out.addByte(column.type);
		var flags:Int = column.flags == null ? 0 : column.flags;
		out.addByte(flags & 0xFF);
		out.addByte((flags >> 8) & 0xFF);
		out.addByte(column.decimals == null ? 0 : column.decimals);
		out.addByte(0);
		out.addByte(0);
		return out.getBytes();
	}

	// ------------------------------------------------------------ handshake

	@:noCompletion private function __sendGreeting():Void {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte(10);
		out.addString(server.serverVersion);
		out.addByte(0);
		out.addInt32(id);
		out.add(__nonce.sub(0, 8));
		out.addByte(0);
		out.addByte(server.capabilities & 0xFF);
		out.addByte((server.capabilities >> 8) & 0xFF);
		out.addByte(server.charset & 0xFF);
		out.addByte(status & 0xFF);
		out.addByte((status >> 8) & 0xFF);
		out.addByte((server.capabilities >> 16) & 0xFF);
		out.addByte((server.capabilities >> 24) & 0xFF);
		out.addByte(21);

		for (_ in 0...10) {
			out.addByte(0);
		}

		out.add(__nonce.sub(8, 12));
		out.addByte(0);
		out.addString(server.plugin);
		out.addByte(0);
		send(0, out.getBytes());
	}

	@:noCompletion private function __authenticate(response:Packet):Bool {
		var p:Bytes = response.payload;
		var flags:Int = p.getInt32(0);
		var charset:Int = p.get(8);
		var pos:Int = 32;
		var user:String = __cString(p, pos);
		pos += Bytes.ofString(user, UTF8).length + 1;

		var auth:Bytes;

		if ((flags & FakeMySQLServer.CLIENT_PLUGIN_AUTH_LENENC) != 0) {
			var length:Int = p.get(pos++);
			auth = p.sub(pos, length);
			pos += length;
		} else if ((flags & FakeMySQLServer.CLIENT_SECURE_CONNECTION) != 0) {
			var length:Int = p.get(pos++);
			auth = p.sub(pos, length);
			pos += length;
		} else {
			var text:String = __cString(p, pos);
			auth = Bytes.ofString(text);
			pos += text.length + 1;
		}

		var database:Null<String> = null;

		if ((flags & FakeMySQLServer.CLIENT_CONNECT_WITH_DB) != 0 && pos < p.length) {
			database = __cString(p, pos);
			pos += Bytes.ofString(database, UTF8).length + 1;
		}

		var plugin:Null<String> = null;

		if ((flags & FakeMySQLServer.CLIENT_PLUGIN_AUTH) != 0 && pos < p.length) {
			plugin = __cString(p, pos);
			pos += plugin.length + 1;
		}

		__clientFlags = flags;
		server.__log({
			connection: id,
			kind: "handshake",
			flags: flags,
			charset: charset,
			user: user,
			database: database,
			plugin: plugin,
			authResponse: auth
		});

		var sequence:Int = response.sequence + 1;
		var mechanism:String = plugin == null ? "mysql_native_password" : plugin;

		if (server.switchTo != null) {
			__nonce = Bytes.ofString("ABCDEFGHIJKLMNOPQRST");
			var request:BytesBuffer = new BytesBuffer();
			request.addByte(0xFE);
			request.addString(server.switchTo);
			request.addByte(0);
			request.add(__nonce);
			request.addByte(0);
			send(sequence++, request.getBytes());

			var switched:Packet = __readPacket();

			if (switched == null) {
				return false;
			}

			server.__log({connection: id, kind: "auth switch response", plugin: server.switchTo, authResponse: switched.payload});
			sequence = switched.sequence + 1;
			mechanism = server.switchTo;
			auth = switched.payload;
		}

		if (server.password == null) {
			__okAt(sequence);
			return true;
		}

		switch (mechanism) {
			case "mysql_native_password":
				var expected:Bytes = server.password == "" ? Bytes.alloc(0) : FakeMySQLServer.nativeScramble(server.password, __nonce);

				if (auth.compare(expected) != 0) {
					__deny(sequence);
					return false;
				}
			case "caching_sha2_password":
				var expected:Bytes = server.password == "" ? Bytes.alloc(0) : FakeMySQLServer.sha2Scramble(server.password, __nonce);

				if (auth.compare(expected) != 0) {
					__deny(sequence);
					return false;
				}

				if (server.cachedAccount) {
					send(sequence++, __authMoreData(Bytes.ofHex("03")));
				} else {
					send(sequence++, __authMoreData(Bytes.ofHex("04")));

					var next:Packet = __readPacket();

					if (next == null) {
						return false;
					}

					sequence = next.sequence + 1;
					var clear:Null<Bytes> = null;

					if (__ssl != null) {
						server.__log({connection: id, kind: "full auth", text: "tls", authResponse: next.payload});
						clear = next.payload;
					} else if (next.payload.length == 1 && next.payload.get(0) == 0x02) {
						server.__log({connection: id, kind: "public key request"});
						var pem:Null<String> = server.__publicKeyPem();

						if (pem == null) {
							__deny(sequence);
							return false;
						}

						send(sequence++, __authMoreData(Bytes.ofString(pem)));
						var encrypted:Packet = __readPacket();

						if (encrypted == null) {
							return false;
						}

						sequence = encrypted.sequence + 1;
						server.__log({connection: id, kind: "full auth", text: "rsa", authResponse: encrypted.payload});
						var decrypted:Null<Bytes> = server.__decryptWithKey(encrypted.payload);
						clear = decrypted == null ? null : FakeMySQLServer.xor(decrypted, __nonce);
					} else if (next.payload.length > 1) {
						// Encrypted with a key the client already had.
						server.__log({connection: id, kind: "full auth", text: "rsa", authResponse: next.payload});
						var decrypted:Null<Bytes> = server.__decryptWithKey(next.payload);
						clear = decrypted == null ? null : FakeMySQLServer.xor(decrypted, __nonce);
					} else {
						server.__log({connection: id, kind: "full auth", text: "unexpected", authResponse: next.payload});
					}

					var expected:Bytes = Bytes.ofString(server.password + String.fromCharCode(0));

					if (clear == null || clear.compare(expected) != 0) {
						__deny(sequence);
						return false;
					}
				}
			default:
				__deny(sequence);
				return false;
		}

		__okAt(sequence);
		return true;
	}

	@:noCompletion private function __authMoreData(data:Bytes):Bytes {
		var out:Bytes = Bytes.alloc(data.length + 1);
		out.set(0, 0x01);
		out.blit(1, data, 0, data.length);
		return out;
	}

	@:noCompletion private function __deny(sequence:Int):Void {
		server.__log({connection: id, kind: "auth denied"});
		error(1045, "28000", "Access denied for user", sequence);
	}

	@:noCompletion private function __okAt(sequence:Int):Void {
		var out:BytesBuffer = new BytesBuffer();
		out.addByte(0x00);
		out.addByte(0);
		out.addByte(0);
		out.addByte(status & 0xFF);
		out.addByte((status >> 8) & 0xFF);
		out.addByte(0);
		out.addByte(0);
		send(sequence, out.getBytes());
	}

	@:noCompletion private function __startTls():Void {
		var certificate:Dynamic = cpp.NativeSsl.cert_load_file(server.tlsCertificatePath);
		var key:Dynamic = cpp.NativeSsl.key_from_pem(sys.io.File.getContent(server.tlsKeyPath), false, null);
		__sslConf = cpp.NativeSsl.conf_new(true);
		cpp.NativeSsl.conf_set_cert(__sslConf, certificate, key);
		cpp.NativeSsl.conf_set_verify(__sslConf, 0);
		__ssl = cpp.NativeSsl.ssl_new(__sslConf);
		cpp.NativeSsl.ssl_set_socket(__ssl, @:privateAccess __socket.__s);
		cpp.NativeSsl.ssl_handshake(__ssl);
		server.__log({connection: id, kind: "tls established"});
	}

	// ------------------------------------------------------------------- io

	@:noCompletion private function __readPacket():Null<Packet> {
		var header:Null<Bytes> = __readExact(4);

		if (header == null) {
			return null;
		}

		var length:Int = header.get(0) | (header.get(1) << 8) | (header.get(2) << 16);

		if (server.stallOnPacketsOver > 0 && length > server.stallOnPacketsOver) {
			server.__log({connection: id, kind: "stalled"});
			hang(server.stallSeconds);
			return null;
		}

		var payload:Null<Bytes> = length == 0 ? Bytes.alloc(0) : __readExact(length);

		if (payload == null) {
			return null;
		}

		return {sequence: header.get(3), payload: payload};
	}

	@:noCompletion private function __readExact(count:Int):Null<Bytes> {
		var out:Bytes = Bytes.alloc(count);
		var got:Int = 0;

		while (got < count) {
			if (__closed) {
				return null;
			}

			var read:Int;

			try {
				if (__ssl != null) {
					read = cpp.NativeSsl.ssl_recv(__ssl, out.getData(), got, count - got);
				} else {
					read = __socket.input.readBytes(out, got, count - got);
				}
			} catch (_:Dynamic) {
				return null;
			}

			if (read <= 0) {
				return null;
			}

			got += read;
		}

		return out;
	}

	@:noCompletion private function __write(data:Bytes):Void {
		if (__closed) {
			return;
		}

		try {
			if (__ssl != null) {
				var sent:Int = 0;

				while (sent < data.length) {
					sent += cpp.NativeSsl.ssl_send(__ssl, data.getData(), sent, data.length - sent);
				}
			} else {
				__socket.output.writeFullBytes(data, 0, data.length);
			}
		} catch (_:Dynamic) {
			__closed = true;
		}
	}

	private static function __cString(b:Bytes, pos:Int):String {
		var end:Int = pos;

		while (end < b.length && b.get(end) != 0) {
			end++;
		}

		return b.getString(pos, end - pos, UTF8);
	}
}

private typedef Packet = {
	var sequence:Int;
	var payload:Bytes;
};
#end
