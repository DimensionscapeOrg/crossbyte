package crossbyte.db;

#if cpp
import crossbyte.db.fakemysql.FakeMySQLServer;
import crossbyte.db.mysql.MySQLConfig;
import crossbyte.db.mysql.MySQLConnection;
import crossbyte.db.mysql.MySQLError;
import crossbyte.test.Require;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import sys.db.ResultSet;
import utest.Assert;

/**
 * What the native MySQL client makes of answers no MySQL server sends: counts
 * and lengths that a hostile server, or whoever answers in its place, can put
 * in a packet. The default `sslMode`, `PREFERRED`, checks no certificate, so
 * anyone in the middle can be that server.
 *
 * Each is a `MySQLError` with error 2027 (`CR_MALFORMED_PACKET`), and the
 * connection is closed, since the exchange cannot be followed past a packet
 * that breaks it, rather than a process ended, or a gigabyte allocated, from
 * a packet of a few bytes.
 */
@:access(crossbyte.db.mysql.MySQLConnection)
class MySQLNativeHostileTest extends utest.Test {
	/** `CR_MALFORMED_PACKET`, as libmysqlclient reports a packet it cannot read. **/
	private static inline var MALFORMED:Int = 2027;

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

	public function testAColumnCountPastTwoToTheThirtyOneIsRefused():Void {
		// Nine bytes: a column count of 2^31 - 1, which must not size a malloc
		// of 150 GB, returning NULL for the client to write to.
		__answerWith([__packet([0xFE, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0])]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
		Assert.isTrue(error.message.indexOf("2147483647 columns") >= 0, error.message);
	}

	public function testAColumnCountOfMillionsIsRefusedBeforeAnythingIsAllocated():Void {
		// Four bytes: 16,777,215 columns, which must not be allocated and
		// zeroed (1.2 GB) before the first of them is read.
		__answerWith([__packet([0xFD, 0xFF, 0xFF, 0xFF])]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
		Assert.isTrue(error.message.indexOf("16777215 columns") >= 0, error.message);
	}

	public function testAResultOfNoColumnsIsRefused():Void {
		__answerWith([__packet([0xFC, 0x00, 0x00])]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
	}

	public function testALocalFileRequestIsRefused():Void {
		// 0xFB is how a server asks the client to send it a file of the
		// client's own (LOAD DATA LOCAL INFILE). The client never offers
		// that, and must not read the byte as a count of -1 columns and
		// allocate accordingly.
		__answerWith([__packet([0xFB, "/".code, "e".code, "t".code, "c".code])]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
		Assert.isTrue(error.message.indexOf("local file") >= 0, error.message);
	}

	public function testAColumnWithoutANameIsRefused():Void {
		// A NULL where the name goes: the result must not be built with its
		// first row reading the name it does not have.
		var definition:BytesBuffer = new BytesBuffer();

		for (part in ["def", "app", "t", "t"]) {
			FakeMySQLServer.lenencString(definition, Bytes.ofString(part));
		}

		definition.addByte(0xFB);
		FakeMySQLServer.lenencString(definition, Bytes.ofString("id"));
		__columnTail(definition);

		__answerWith([__packet([1]), definition.getBytes(), __eof(), __row(["1"]), __eof()]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
	}

	public function testAColumnStringClaimingTwoGigabytesIsRefused():Void {
		// A catalog name 2^31 - 1 bytes long, in a packet of a few: added to
		// the position, the length would wrap the sum negative and pass the
		// check that it fitted, and malloc would then be asked for 2^31 bytes,
		// in an int, which wraps too.
		var definition:BytesBuffer = new BytesBuffer();
		definition.addByte(0xFE);
		definition.add(Bytes.ofHex("ffffff7f00000000"));
		definition.add(Bytes.ofString("def"));
		__answerWith([__packet([1]), definition.getBytes()]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
	}

	public function testARowValueClaimingTwoGigabytesIsRefused():Void {
		// The same wrap in a row: a value 2^31 - 1 bytes long must not pass its
		// check and have the row's end written 2 GB before its buffer.
		var row:BytesBuffer = new BytesBuffer();
		row.addByte(0xFE);
		row.add(Bytes.ofHex("ffffff7f00000000"));
		row.add(Bytes.ofString("x"));
		__answerWith([__packet([1]), __column("id"), __eof(), row.getBytes(), __eof()]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
	}

	public function testARowWithFewerValuesThanColumnsIsRefused():Void {
		__answerWith([__packet([2]), __column("a"), __column("b"), __eof(), __row(["1"]), __eof()]);

		var error:MySQLError = __refused("SELECT HOSTILE");
		Assert.equals(MALFORMED, error.code, error.message);
	}

	public function testAnEmptyPacketAmongTheRowsIsRefused():Void {
		// The rows are read into buffers each row keeps, and the connection's
		// own must not be let go before the first, or an empty packet would
		// write its end marker through a null pointer.
		__answerWith([__packet([1]), __column("id"), __eof(), Bytes.alloc(0)]);

		var connection:MySQLConnection = __open();
		var error:MySQLError = __refusedOn(connection, "SELECT HOSTILE");
		Assert.isTrue(error.code == MALFORMED || error.code == 2013, error.message);

		// The connection is closed, not left out of step with the server.
		var next:MySQLError = __refusedOn(connection, "SELECT 1");
		Assert.equals(2006, next.code, next.message);
		connection.close();
	}

	public function testAStreamedResultWithAHostileCountIsRefused():Void {
		// A result read a row at a time takes its columns the same way.
		__answerWith([__packet([0xFE, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0])]);

		var connection:MySQLConnection = __open();
		var error:Null<MySQLError> = null;

		try {
			connection.__requestStream("SELECT HOSTILE");
		} catch (e:MySQLError) {
			error = e;
		}

		Require.notNull(error);
		Assert.equals(MALFORMED, error.code, error.message);
		connection.close();
	}

	public function testAStreamedRowValueClaimingTwoGigabytesIsRefused():Void {
		var row:BytesBuffer = new BytesBuffer();
		row.addByte(0xFE);
		row.add(Bytes.ofHex("ffffff7f00000000"));
		row.add(Bytes.ofString("x"));
		__answerWith([__packet([1]), __column("id"), __eof(), row.getBytes(), __eof()]);

		var connection:MySQLConnection = __open();
		var rows:ResultSet = connection.__requestStream("SELECT HOSTILE");
		var error:Null<MySQLError> = null;

		try {
			while (rows.hasNext()) {
				rows.next();
			}
		} catch (e:Dynamic) {
			error = connection.__error("request", e);
		}

		Require.notNull(error);
		Assert.equals(MALFORMED, error.code, error.message);
		connection.close();
	}

	public function testAnErrorCutShortInItsStateDoesNotReadPastIt():Void {
		// An error packet that ends at the '#' that starts its SQLSTATE: the
		// five characters must not be copied from past its end (the end
		// marker, then whatever an earlier packet left in the buffer), which
		// would give the error the success state "00000".
		__server.onQuery = function(session, sql) {
			if (sql != "SELECT HOSTILE") {
				return false;
			}

			session.send(1, Bytes.ofHex("ff150423"));
			return true;
		};
		__server.start();

		var connection:MySQLConnection = __open();
		var error:MySQLError = __refusedOn(connection, "SELECT HOSTILE");
		Assert.equals(1045, error.code, error.message);
		Assert.equals("HY000", error.sqlState);
		connection.close();
	}

	public function testTheProcessCarriesOnAfterEachRefusal():Void {
		// One connection refused a hostile answer; the next, to an honest
		// server, works.
		__answerWith([__packet([0xFE, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0])]);
		__refused("SELECT HOSTILE");

		var connection:MySQLConnection = __open();
		var rows:ResultSet = connection.request("SELECT 1");
		Assert.isTrue(rows.hasNext());
		connection.close();
	}

	// ------------------------------------------------------------------ helpers

	/**
		Answers "SELECT HOSTILE" with `packets`, in order, and then ends the
		session: a client that did not refuse the first one would otherwise
		wait for the rest of a result that is never coming.
	**/
	private function __answerWith(packets:Array<Bytes>):Void {
		__server.onQuery = function(session, sql) {
			if (sql != "SELECT HOSTILE") {
				return false;
			}

			var sequence:Int = 1;

			for (packet in packets) {
				session.send(sequence++, packet);
			}

			session.__abort();
			return true;
		};
		__server.start();
	}

	private function __refused(sql:String):MySQLError {
		var connection:MySQLConnection = __open();
		var error:MySQLError = __refusedOn(connection, sql);
		connection.close();
		return error;
	}

	private function __refusedOn(connection:MySQLConnection, sql:String):MySQLError {
		var error:Null<MySQLError> = null;

		try {
			var rows:ResultSet = connection.request(sql);

			while (rows.hasNext()) {
				rows.next();
			}
		} catch (e:MySQLError) {
			error = e;
		}

		return Require.notNull(error, '"$sql" was answered with something no server sends, and was not refused');
	}

	private static function __packet(bytes:Array<Int>):Bytes {
		var out:Bytes = Bytes.alloc(bytes.length);

		for (i in 0...bytes.length) {
			out.set(i, bytes[i]);
		}

		return out;
	}

	private static function __column(name:String):Bytes {
		var out:BytesBuffer = new BytesBuffer();

		for (part in ["def", "app", "t", "t", name, name]) {
			FakeMySQLServer.lenencString(out, Bytes.ofString(part));
		}

		__columnTail(out);
		return out.getBytes();
	}

	/** What follows a column definition's names: charset, length, type, flags, decimals. **/
	private static function __columnTail(out:BytesBuffer):Void {
		out.addByte(0x0C);
		out.addByte(FakeMySQLServer.CHARSET_UTF8MB4);
		out.addByte(0);
		out.add(Bytes.ofHex("ff000000"));
		out.addByte(FakeMySQLServer.TYPE_VAR_STRING);
		out.addByte(0);
		out.addByte(0);
		out.addByte(0);
		out.addByte(0);
		out.addByte(0);
	}

	private static function __row(values:Array<String>):Bytes {
		var out:BytesBuffer = new BytesBuffer();

		for (value in values) {
			FakeMySQLServer.lenencString(out, Bytes.ofString(value));
		}

		return out.getBytes();
	}

	private static function __eof():Bytes {
		return Bytes.ofHex("fe00000200");
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
}
#end
