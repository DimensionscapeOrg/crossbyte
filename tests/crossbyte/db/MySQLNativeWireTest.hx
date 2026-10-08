package crossbyte.db;

#if cpp
import crossbyte.db.fakemysql.FakeMySQLServer;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLConnectionError;
import crossbyte.db.mysql.MySQLError;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.errors.IOError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
 * What the native MySQL client puts on the wire, against a server that logs
 * every byte it is sent (`fakemysql/FakeMySQLServer`).
 */
@:access(crossbyte.db.mysql.MySQLConnection)
class MySQLNativeWireTest extends utest.Test {
	private var __server:FakeMySQLServer;

	public function setup():Void {
		__server = new FakeMySQLServer();
	}

	public function teardown():Void {
		if (__server != null) {
			__server.stop();
			__server = null;
		}
	}

	public function testANonAsciiQueryArrivesWhole():Void {
		// The query's length is counted in UTF-8 bytes, not UTF-16 units, which
		// would cut a byte off the end for each extra byte of a non-ASCII
		// character: this UPDATE would arrive as "... WHERE id = 1", changing
		// another row.
		__server.start();
		var connection:MySQLConnection = __open();

		var sql:String = "UPDATE users SET city = 'Zürich' WHERE id = 12";
		connection.request(sql);

		Assert.equals(sql, __server.lastQuery());
		Assert.equals(Bytes.ofString(sql, UTF8).toHex(), __lastQueryBytes().toHex());

		connection.close();
	}

	public function testANonAsciiValueIsEscapedWhole():Void {
		// The escape buffer is sized the same way, and escapes the whole value,
		// not only the first value.length bytes, which would cost an escaped
		// value its tail too: 'Zoë \u{1F680}' going out followed by NUL bytes,
		// with the quote and the rest of the statement gone.
		__server.start();
		var connection:MySQLConnection = __open();

		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "UPDATE users SET name = :name WHERE id = 12345";
		statement.parameters.name = "Zoë \u{1F680} it's";

		try {
			statement.execute();
		} catch (_:Dynamic) {}

		Assert.equals("UPDATE users SET name = 'Zoë \u{1F680} it\\'s' WHERE id = 12345", __server.lastQuery());

		connection.close();
	}

	public function testTypedParametersReachTheServerExactly():Void {
		// Values as themselves: NULL, numbers unquoted, bytes not cut at a NUL.
		__server.start();
		var connection:MySQLConnection = __open();
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "INSERT INTO blobs (id, owner, data, at, note) VALUES (:id, :owner, :data, :at, :note)";
		statement.parameters.id = haxe.Int64.parseString("1234567890123456789");
		statement.parameters.owner = null;
		statement.parameters.data = haxe.io.Bytes.ofHex("00ff0027");
		statement.parameters.at = Date.fromTime(-149040000000.0);
		statement.parameters.note = "Zoë's";
		statement.execute();

		Assert.equals("INSERT INTO blobs (id, owner, data, at, note) VALUES (1234567890123456789, NULL, X'00ff0027', '1965-04-12 00:00:00', 'Zoë\\'s')",
			__server.lastQuery());

		// And the connection quotes as the session escapes.
		Assert.equals("'a\\'b'", connection.quote("a'b"));
		connection.request("SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'");
		Assert.equals("'a''b\\'", connection.quote("a'b\\"));
		connection.close();
	}

	public function testAServerThatNeverGreetsTimesOut():Void {
		// The handshake is bounded by connectTimeout, not a fixed 50 seconds,
		// and the TCP connect too, not as long as the operating system cares to.
		__server.greetingDelay = 5;
		__server.start();
		var config:MySQLConfig = __config();
		config.connectTimeout = 0.3;
		var started:Float = haxe.Timer.stamp();
		var message:String = "";

		try {
			new MySQLConnection().open(config);
		} catch (e:IOError) {
			message = e.message;
		}

		Assert.isTrue(haxe.Timer.stamp() - started < 3.0, "the connect timeout was not applied");
		Assert.isTrue(message.indexOf("Timed out") >= 0, message);
	}

	public function testAGreetingSentAByteAtATimeIsBoundedByTheConnectTimeout():Void {
		// The handshake's reads share one connect timeout, rather than each
		// waiting the whole of it again: a server sending its greeting a byte at
		// a time, each inside it, would otherwise hold open() for as long as it
		// went on (here 0.25 s a byte, some 80 bytes, under a 1 s connectTimeout)
		// and then log in.
		__server.greetingTrickle = 0.25;
		__server.start();
		var config:MySQLConfig = __config();
		config.connectTimeout = 1.0;
		var started:Float = haxe.Timer.stamp();
		var error:Null<IOError> = null;
		var connection:MySQLConnection = new MySQLConnection();

		try {
			connection.open(config);
		} catch (e:IOError) {
			error = e;
		}

		var took:Float = haxe.Timer.stamp() - started;

		if (error == null) {
			connection.close();
		}

		Assert.isTrue(took < 4.0, 'open() took ${took}s under a 1 s connectTimeout');
		Require.notNull(error);
		Assert.isTrue(error.message.indexOf("Timed out") >= 0, error.message);
	}

	public function testAConnectNobodyAnswersTimesOut():Void {
		// connect() itself is bounded: unbounded, to a host that drops the SYN
		// it would wait for as long as the system resent it, 21 seconds on
		// Windows and over two minutes on Linux. Here, a listener that never
		// accepts, its queue filled: the next SYN goes unanswered, on Linux and
		// macOS for good, on Windows until it refuses the connection a couple of
		// seconds later. The queue is filled until a connect is not answered,
		// not by a count assumed: one connection fills a listen(0) on Linux and
		// Windows, while macOS makes the next connection all the same, so that
		// the server's greeting times out instead (2013).
		var listener:sys.net.Socket = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(1);
		var port:Int = listener.host().port;
		var fillers:Array<sys.net.Socket> = [];
		var unanswered:Bool = false;

		while (!unanswered && fillers.length < 64) {
			var filler:sys.net.Socket = new sys.net.Socket();
			fillers.push(filler);
			filler.setBlocking(false);

			try {
				filler.connect(new sys.net.Host("127.0.0.1"), port);
			} catch (_:Dynamic) {}

			// Writable, or failed, once answered either way.
			var ready = sys.net.Socket.select([], [filler], [filler], 0.25);
			unanswered = ready.write.length == 0 && ready.others.length == 0;
		}

		var config:MySQLConfig = {
			host: "127.0.0.1",
			port: port,
			user: "app",
			password: "secret",
			database: "app",
			connectTimeout: 0.3
		};
		var started:Float = haxe.Timer.stamp();
		var error:MySQLConnectionError = null;

		try {
			new MySQLConnection().open(config);
		} catch (e:MySQLConnectionError) {
			error = e;
		}

		var elapsed:Float = haxe.Timer.stamp() - started;

		for (filler in fillers) {
			filler.close();
		}

		listener.close();

		Assert.isTrue(elapsed < 3.0, "the connect was not bounded: " + elapsed + " s");
		Require.notNull(error);
		Assert.isTrue(unanswered, 'every one of ${fillers.length} connects to a listener that takes nobody was answered');
		Assert.equals(2003, error.code);
		Assert.isTrue(error.message.indexOf("Timed out after 0.3 seconds connecting") >= 0, error.message);
	}

	public function testAConnectionTheServerNeverGreetsIsNotACannotConnect():Void {
		// The other side of connectTimeout's contract: a listener whose queue
		// has room completes the connection before the server takes it, so a
		// server too busy to accept is one that said nothing (2013, and what ran
		// out was the greeting), not one that could not be reached.
		var listener:sys.net.Socket = new sys.net.Socket();
		listener.bind(new sys.net.Host("127.0.0.1"), 0);
		listener.listen(16);
		var config:MySQLConfig = {
			host: "127.0.0.1",
			port: listener.host().port,
			user: "app",
			password: "secret",
			database: "app",
			connectTimeout: 0.3
		};
		var started:Float = haxe.Timer.stamp();
		var error:MySQLConnectionError = null;

		try {
			new MySQLConnection().open(config);
		} catch (e:MySQLConnectionError) {
			error = e;
		}

		var elapsed:Float = haxe.Timer.stamp() - started;
		listener.close();

		Assert.isTrue(elapsed < 3.0, "the connect was not bounded: " + elapsed + " s");
		Require.notNull(error);
		Assert.equals(2013, error.code);
		Assert.isTrue(error.message.indexOf("Timed out after 0.3 seconds waiting for the server's greeting") >= 0, error.message);
	}

	public function testAReadTimeoutFailsTheStatementAndClosesTheConnection():Void {
		// After connecting, an answer is waited for within the read timeout, not five hours.
		__server.onQuery = function(session, sql) {
			if (sql == "SELECT SLOW") {
				// Answers late, so a client with no limit returns eventually.
				session.hang(5);
				session.ok();
				return true;
			}
			return false;
		};
		__server.start();
		var config:MySQLConfig = __config();
		config.readTimeout = 0.3;
		var connection:MySQLConnection = new MySQLConnection();
		connection.open(config);

		var started:Float = haxe.Timer.stamp();
		var error:MySQLError = null;

		try {
			connection.request("SELECT SLOW");
		} catch (e:MySQLError) {
			error = e;
		}

		Assert.isTrue(haxe.Timer.stamp() - started < 3.0, "the read timeout was not applied");
		Require.notNull(error);
		Assert.equals(2013, error.code);
		Assert.isTrue(error.message.indexOf("Timed out") >= 0, error.message);

		// The answer it gave up on is still coming, so the connection is
		// closed rather than left to read it as the next statement's.
		var next:MySQLError = null;

		try {
			connection.request("SELECT 1");
		} catch (e:MySQLError) {
			next = e;
		}

		Require.notNull(next);
		Assert.equals(2006, next.code);
		connection.close();
	}

	public function testAWriteTimeoutFailsTheStatementAndClosesTheConnection():Void {
		// A server that stops reading must not hold a statement's send for as
		// long as the socket waits, five hours: the write has a timeout too.
		__server.stallOnPacketsOver = 1 << 20;
		__server.start();
		var config:MySQLConfig = __config();
		config.writeTimeout = 0.3;
		var connection:MySQLConnection = new MySQLConnection();
		connection.open(config);

		// More than one packet carries, so the statement goes as two. Windows
		// takes a single send() whole, however little room its buffer has (an
		// 8 MB statement to a server not reading goes out at once), and only the
		// send after it waits; Linux waits part way through.
		var filler:Bytes = Bytes.alloc(17 << 20);
		filler.fill(0, filler.length, "x".code);
		var sql:String = "SELECT '" + filler.toString() + "'";

		var started:Float = haxe.Timer.stamp();
		var error:MySQLError = null;

		try {
			connection.request(sql);
		} catch (e:MySQLError) {
			error = e;
		}

		Assert.isTrue(haxe.Timer.stamp() - started < 3.0, "the write timeout was not applied");
		Assert.equals(1, __server.eventsOf("stalled").length);
		Require.notNull(error);
		Assert.equals(2013, error.code);
		Assert.isTrue(error.message.indexOf("Timed out after 0.3 seconds") >= 0, error.message);

		// Part of the statement went and the rest never will, so the
		// connection is closed rather than left to send the next one after it.
		var next:MySQLError = null;

		try {
			connection.request("SELECT 1");
		} catch (e:MySQLError) {
			next = e;
		}

		Require.notNull(next);
		Assert.equals(2006, next.code);
		connection.close();
	}

	public function testKeepAliveIsSetOnTheSocket():Void {
		// The client sets keepalive, so a connection to a host that has vanished
		// is noticed without waiting for a read to run out of time. Read back
		// from the socket, not from what was asked for.
		__server.start();
		var config:MySQLConfig = __config();
		config.keepAliveIdle = 45;
		config.keepAliveInterval = 7;
		config.keepAliveCount = 4;
		var connection:MySQLConnection = new MySQLConnection();
		connection.open(config);

		var state:Array<Int> = connection.__native.keepAlive;
		Assert.equals(1, state[0], "keepalive is off");

		// Where the system reports them (Linux, and Windows 10 1709 on) they are
		// the ones asked for; on Windows the count as well, which
		// SIO_KEEPALIVE_VALS cannot set.
		if (Sys.systemName() == "Linux" || Sys.systemName() == "Windows") {
			Assert.equals("45 7 4", state.slice(1).join(" "));
		}

		connection.close();

		config.keepAlive = false;
		var plain:MySQLConnection = new MySQLConnection();
		plain.open(config);
		Assert.equals(0, plain.__native.keepAlive[0], "keepalive is on when asked not to be");
		plain.close();
	}

	public function testAnErrorCarriesItsNumberAndStateButNotTheStatement():Void {
		// A duplicate-key error carries the server's message, not the whole
		// INSERT with its values, which would send the token in this row to
		// whatever logged the error; and a number and SQLSTATE to tell it from
		// a deadlock.
		__server.onQuery = function(session, sql) {
			if (sql.indexOf("api_token") >= 0) {
				session.error(1062, "23000", "Duplicate entry 'zoe@example.com' for key 'users.email'");
				return true;
			}
			return false;
		};
		__server.start();
		var connection:MySQLConnection = __open();

		var error:MySQLError = null;

		try {
			connection.request("INSERT INTO users (email, api_token) VALUES ('zoe@example.com', 'tok_live_9f8e7d6c5b4a')");
		} catch (e:MySQLError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(1062, error.code);
		Assert.equals("23000", error.sqlState);
		Assert.isTrue(error.message.indexOf("Duplicate entry") >= 0, error.message);
		Assert.equals(-1, error.message.indexOf("tok_live"), error.message);
		Assert.equals(-1, error.details().indexOf("tok_live"), error.details());

		// A statement's error carries them too.
		var statement:MySQLStatement = new MySQLStatement();
		statement.sqlConnection = connection;
		statement.text = "INSERT INTO users (email, api_token) VALUES ('zoe@example.com', :token)";
		statement.parameters.token = "tok_live_9f8e7d6c5b4a";
		var dispatched:Dynamic = null;
		statement.addEventListener(SQLErrorEvent.ERROR, e -> dispatched = (cast e : SQLErrorEvent).error);

		try {
			statement.execute();
		} catch (_:Dynamic) {}

		Assert.isTrue(Std.isOfType(dispatched, MySQLError));
		Assert.equals(1062, (dispatched : MySQLError).code);
		Assert.equals(-1, (dispatched : MySQLError).message.indexOf("tok_live"));
		connection.close();
	}

	public function testCancelStopsTheRunningStatement():Void {
		// The thread that sent a statement waits for its answer, so stopping
		// it takes another thread reaching the server for it.
		__server.start();
		var connection:MySQLConnection = __open();
		var outcome:Null<Int> = null;
		var done:sys.thread.Lock = new sys.thread.Lock();

		sys.thread.Thread.create(function():Void {
			try {
				connection.request("SELECT SLEEP(10)");
				outcome = 0;
			} catch (e:MySQLError) {
				outcome = e.code;
			} catch (_:Dynamic) {
				outcome = -1;
			}

			done.release();
		});

		// Once the statement is running on the server.
		Assert.isTrue(__server.waitFor(events -> events.filter(e -> e.kind == "query" && e.text == "SELECT SLEEP(10)").length == 1));
		var started:Float = haxe.Timer.stamp();
		Assert.isTrue(connection.cancel());

		if (!done.wait(5.0)) {
			// Still running on the other thread, which owns the connection
			// until it returns: stopping the server in teardown ends it.
			Assert.fail("the statement ran on after the cancel");
			return;
		}

		Assert.equals(1317, outcome);
		Assert.isTrue(haxe.Timer.stamp() - started < 3.0);

		// It went over a second connection, and this one is still usable.
		Assert.isTrue(__server.queries().indexOf("KILL QUERY 100") >= 0, __server.queries().join(" | "));
		Assert.isTrue(connection.ping());
		connection.close();
	}

	public function testCancelReachesAConnectionIdPastTwoToTheThirtyOne():Void {
		// Connection ids are unsigned 32-bit. Written through Std.int, one past
		// 2^31 would become -2147483648, and the KILL would name no connection.
		__server.nextConnectionId = -2; // 4294967294 on the wire
		__server.start();
		var connection:MySQLConnection = __open();
		var done:sys.thread.Lock = new sys.thread.Lock();
		var outcome:Null<Int> = null;

		sys.thread.Thread.create(function():Void {
			try {
				connection.request("SELECT SLEEP(10)");
				outcome = 0;
			} catch (e:MySQLError) {
				outcome = e.code;
			} catch (_:Dynamic) {
				outcome = -1;
			}

			done.release();
		});

		Assert.isTrue(__server.waitFor(events -> events.filter(e -> e.kind == "query" && e.text == "SELECT SLEEP(10)").length == 1));
		Assert.isTrue(connection.cancel());

		if (!done.wait(5.0)) {
			Assert.fail("the KILL did not reach the connection");
			return;
		}

		Assert.equals(1317, outcome);
		Assert.isTrue(__server.queries().indexOf("KILL QUERY 4294967294") >= 0, __server.queries().join(" | "));
		connection.close();
	}

	public function testPingIsAComPing():Void {
		__server.start();
		var connection:MySQLConnection = __open();

		Assert.isTrue(connection.ping());
		Assert.equals(1, __server.eventsOf("ping").length);
		Assert.equals(0, __server.queries().filter(q -> StringTools.startsWith(q, "SELECT 1")).length);
		connection.close();
		Assert.isFalse(connection.ping());
	}

	private function __open():MySQLConnection {
		var connection:MySQLConnection = new MySQLConnection();
		connection.open(__config());
		return connection;
	}

	private function __config():MySQLConfig {
		return {
			host: "127.0.0.1",
			port: __server.port,
			user: "app",
			password: "secret",
			database: "app"
		};
	}

	private function __lastQueryBytes():Bytes {
		var queries = __server.eventsOf("query");
		return queries.length == 0 ? Bytes.alloc(0) : queries[queries.length - 1].bytes;
	}
}
#end
