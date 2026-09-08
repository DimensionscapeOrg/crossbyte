package crossbyte.db;

import crossbyte.db.postgres.PostgresConfig;
import crossbyte.db.postgres.PostgresConnection;
import crossbyte.db.postgres.PostgresStatement;
import crossbyte.db.postgres.PostgresParameter;
import crossbyte.db.postgres._internal.PostgresWire;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
 * The first tests in this repository that talk to a real PostgreSQL server.
 *
 * Everything else covering this driver asserts the support flag and that
 * `open` throws when unsupported — nothing had ever connected, so the whole
 * query path was shipped unexercised. That matters more than it sounds: the
 * driver builds SQL by string substitution and returns every value as a JSON
 * string, and neither of those had ever been checked against a server that
 * would tell it it was wrong.
 *
 * `@:suiteExempt` because it needs a live server and so cannot be reachable
 * from `addNativeSmoke`, which the coverage macro would otherwise require of a
 * cpp-guarded case. It is run by the `Data | Postgres` CI job, and skips
 * cleanly anywhere `CROSSBYTE_PG_HOST` is unset so a developer without a
 * database still gets a green suite rather than a wall of connection errors.
 */
@:suiteExempt("needs a live PostgreSQL server; run by the Data | Postgres CI job")
class PostgresIntegrationTest extends utest.Test {
	#if cpp
	private var connection:PostgresConnection;
	private var table:String;
	#end

	public function setup():Void {
		#if cpp
		if (!__configured()) {
			return;
		}

		connection = new PostgresConnection();
		connection.open(__config());
		// Unique per run so a failed run leaving a table behind cannot make the
		// next one fail for an unrelated reason.
		table = "crossbyte_it_" + Std.string(Std.random(0x7FFFFFF));
		connection.request('CREATE TABLE $table (id INTEGER PRIMARY KEY, label TEXT, amount INTEGER)');
		#end
	}

	public function teardown():Void {
		#if cpp
		if (connection == null) {
			return;
		}

		try {
			connection.request('DROP TABLE IF EXISTS $table');
		} catch (_:Dynamic) {}

		try {
			connection.close();
		} catch (_:Dynamic) {}

		connection = null;
		#end
	}

	public function testConnectsAndReportsServerVersion():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		Assert.isTrue(connection.connected);
		Assert.isTrue(connection.ping());
		Assert.notNull(connection.serverVersion);
		Assert.isTrue(connection.serverVersion.length > 0);
		#else
		Assert.pass();
		#end
	}

	public function testRowsRoundTrip():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.request('INSERT INTO $table (id, label, amount) VALUES (1, \'first\', 10)');
		connection.request('INSERT INTO $table (id, label, amount) VALUES (2, \'second\', 20)');

		var result:Dynamic = connection.request('SELECT id, label, amount FROM $table ORDER BY id');
		var rows:Array<Dynamic> = __rows(result);

		Assert.equals(2, rows.length);
		Assert.equals("first", Std.string(Reflect.field(rows[0], "label")));
		Assert.equals("second", Std.string(Reflect.field(rows[1], "label")));
		// Every value arrives as text today, so this is a string comparison on
		// purpose rather than an assertion about types. The typed-result work
		// changes that, and this case is what will notice.
		Assert.equals("10", Std.string(Reflect.field(rows[0], "amount")));
		#else
		Assert.pass();
		#end
	}

	public function testAffectedRowsReflectsTheStatement():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.request('INSERT INTO $table (id, label, amount) VALUES (1, \'a\', 1)');
		connection.request('INSERT INTO $table (id, label, amount) VALUES (2, \'b\', 2)');
		connection.request('UPDATE $table SET amount = 99');

		Assert.equals(2, connection.affectedRows);
		#else
		Assert.pass();
		#end
	}

	public function testRollbackDiscardsAndCommitKeeps():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.begin();
		connection.request('INSERT INTO $table (id, label, amount) VALUES (1, \'rolled back\', 1)');
		connection.rollback();

		Assert.equals(0, __count());

		connection.begin();
		connection.request('INSERT INTO $table (id, label, amount) VALUES (2, \'committed\', 2)');
		connection.commit();

		Assert.equals(1, __count());
		#else
		Assert.pass();
		#end
	}

	public function testEscapeSurvivesAQuotedValue():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		// The driver has no parameter binding, so this escape is the only thing
		// standing between a value and the statement it lands in.
		var awkward:String = "o'brien \\ \"quoted\"";
		connection.request('INSERT INTO $table (id, label, amount) VALUES (1, \'' + connection.escape(awkward) + '\', 1)');

		var rows:Array<Dynamic> = __rows(connection.request('SELECT label FROM $table'));

		Assert.equals(1, rows.length);
		Assert.equals(awkward, Std.string(Reflect.field(rows[0], "label")));
		#else
		Assert.pass();
		#end
	}

	public function testFailedStatementRaisesRatherThanReturningEmpty():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		// A syntax error must surface. Returning an empty result set would let a
		// broken query read as a query that matched nothing.
		Assert.raises(() -> connection.request("SELECT * FROM a_table_that_does_not_exist"));
		Assert.isTrue(connection.ping());
		#else
		Assert.pass();
		#end
	}

	public function testBoundParametersCarryValuesThatEscapingCannot():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.request('CREATE TABLE ${table}_blob (id INTEGER PRIMARY KEY, payload BYTEA)');

		// A NUL in the middle is the case the substitution path cannot express:
		// PQescapeStringConn measures a C string, so everything from the zero
		// byte onward is dropped and nothing reports it.
		var ciphertext:Bytes = Bytes.ofHex("00DEADBEEF0000FF1A00");

		connection.requestParams('INSERT INTO ${table}_blob (id, payload) VALUES ($1, $2)', [Text("1"), Binary(ciphertext)]);

		var result = connection.requestParams('SELECT payload FROM ${table}_blob WHERE id = $1', [Text("1")]);

		Assert.equals(1, result.rows.length);
		// bytea comes back as its \x hex rendering, which is exact.
		Assert.equals(ciphertext.toHex(), PostgresWire.decodeByteaHex(result.rows[0][0]).toHex());

		try {
			connection.request('DROP TABLE ${table}_blob');
		} catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	public function testBoundTextIsNotInterpretedAsSql():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		// Stored verbatim rather than executed or mangled. If this ever comes
		// back altered, the value reached the statement text.
		var hostile:String = "'); DROP TABLE " + table + "; --";

		connection.requestParams('INSERT INTO $table (id, label, amount) VALUES ($1, $2, $3)', [Text("1"), Text(hostile), Text("5")]);

		var result = connection.requestParams('SELECT label, amount FROM $table WHERE id = $1', [Text("1")]);

		Assert.equals(1, result.rows.length);
		Assert.equals(hostile, result.rows[0][0].toString());
		Assert.equals("5", result.rows[0][1].toString());
		#else
		Assert.pass();
		#end
	}

	public function testBoundNullIsDistinctFromAnEmptyString():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.requestParams('INSERT INTO $table (id, label, amount) VALUES ($1, $2, $3)', [Text("1"), Null, Text("1")]);
		connection.requestParams('INSERT INTO $table (id, label, amount) VALUES ($1, $2, $3)', [Text("2"), Text(""), Text("2")]);

		var nulls = connection.requestParams('SELECT id FROM $table WHERE label IS NULL', []);
		var empties = connection.requestParams('SELECT id FROM $table WHERE label = $1', [Text("")]);

		Assert.equals(1, nulls.rows.length);
		Assert.equals("1", nulls.rows[0][0].toString());
		Assert.equals(1, empties.rows.length);
		Assert.equals("2", empties.rows[0][0].toString());

		// And the value itself survives the trip as NULL rather than "".
		var back = connection.requestParams('SELECT label FROM $table WHERE id = $1', [Text("1")]);
		Assert.isNull(back.rows[0][0]);
		#else
		Assert.pass();
		#end
	}

	public function testBoundStatementReportsFieldsAndAffectedRows():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		connection.requestParams('INSERT INTO $table (id, label, amount) VALUES ($1, $2, $3)', [Text("1"), Text("a"), Text("1")]);
		connection.requestParams('INSERT INTO $table (id, label, amount) VALUES ($1, $2, $3)', [Text("2"), Text("b"), Text("2")]);

		var result = connection.requestParams('SELECT id, label FROM $table ORDER BY id', []);

		Assert.same(["id", "label"], result.fields);
		Assert.equals(2, result.rows.length);

		connection.requestParams('UPDATE $table SET amount = $1', [Text("9")]);
		Assert.equals(2, connection.affectedRows);
		#else
		Assert.pass();
		#end
	}

	public function testBoundStatementFailureRaisesTheServerMessage():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		var message:String = null;

		try {
			connection.requestParams("SELECT * FROM a_table_that_does_not_exist WHERE id = $1", [Text("1")]);
		} catch (e:Dynamic) {
			message = Std.string(e);
		}

		Require.notNull(message);
		Assert.isTrue(message.indexOf("does not exist") >= 0);
		// The connection stays usable, so one bad statement does not cost the
		// pool a connection.
		Assert.isTrue(connection.ping());
		#else
		Assert.pass();
		#end
	}

	public function testStatementBindsRatherThanSubstituting():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		// The same NUL-carrying value the substituting path silently truncates,
		// now through the statement API rather than the connection.
		connection.request('CREATE TABLE ${table}_stmt (id INTEGER PRIMARY KEY, payload BYTEA)');

		var payload:Bytes = Bytes.ofHex("0011002200FF00");
		var insert = new PostgresStatement();
		insert.sqlConnection = connection;
		insert.text = 'INSERT INTO ${table}_stmt (id, payload) VALUES ($1, $2)';
		insert.executeParams([Text("1"), Binary(payload)]);

		var select = new PostgresStatement();
		select.sqlConnection = connection;
		select.text = 'SELECT payload FROM ${table}_stmt WHERE id = $1';
		select.executeParams([Text("1")]);

		var result = select.getResult();
		Require.notNull(result);
		Assert.equals(1, result.data.length);

		var hex:String = Std.string(Reflect.field(result.data[0], "payload"));
		Assert.equals(payload.toHex(), PostgresWire.decodeByteaHex(Bytes.ofString(hex)).toHex());

		try {
			connection.request('DROP TABLE ${table}_stmt');
		} catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	public function testStatementBoundFailureDispatchesAnError():Void {
		#if cpp
		if (__skip()) {
			return;
		}

		var statement = new PostgresStatement();
		statement.sqlConnection = connection;
		statement.text = "SELECT * FROM a_table_that_does_not_exist WHERE id = $1";

		var errored:Bool = false;
		statement.addEventListener(crossbyte.events.SQLErrorEvent.ERROR, _ -> errored = true);
		statement.executeParams([Text("1")]);

		// Reported through the statement's own error event rather than thrown,
		// matching how execute() reports a failure.
		Assert.isTrue(errored);
		Assert.isTrue(connection.ping());
		#else
		Assert.pass();
		#end
	}

	#if cpp
	@:noCompletion private function __skip():Bool {
		if (__configured()) {
			return false;
		}

		if (Sys.getEnv("CROSSBYTE_PG_REQUIRED") != null) {
			// The CI job sets this. Without it a broken service container, a
			// missing libpq or a mistyped variable would skip every case and
			// report a green run -- the job would exist and prove nothing,
			// which is exactly how the jvm suite stayed red unnoticed.
			Assert.fail("CROSSBYTE_PG_REQUIRED is set but CROSSBYTE_PG_HOST is not: the server this job exists to test was never reached.");
			return true;
		}

		// Passing rather than failing: no database configured is the normal
		// state on a development machine, and is not a defect in the driver.
		Assert.pass();
		return true;
	}

	@:noCompletion private function __count():Int {
		var rows:Array<Dynamic> = __rows(connection.request('SELECT COUNT(*) AS total FROM $table'));
		return rows.length == 0 ? 0 : Std.parseInt(Std.string(Reflect.field(rows[0], "total")));
	}

	@:noCompletion private function __rows(result:Dynamic):Array<Dynamic> {
		if (result == null) {
			return [];
		}

		var out:Array<Dynamic> = [];
		while (result.hasNext()) {
			out.push(result.next());
		}
		return out;
	}

	@:noCompletion private static function __configured():Bool {
		var host:String = Sys.getEnv("CROSSBYTE_PG_HOST");
		return host != null && host != "";
	}

	@:noCompletion private static function __config():PostgresConfig {
		var port:Null<Int> = Std.parseInt(__env("CROSSBYTE_PG_PORT", "5432"));

		return {
			host: __env("CROSSBYTE_PG_HOST", "127.0.0.1"),
			port: port == null ? 5432 : port,
			user: __env("CROSSBYTE_PG_USER", "postgres"),
			password: __env("CROSSBYTE_PG_PASSWORD", "postgres"),
			database: __env("CROSSBYTE_PG_DATABASE", "postgres")
		};
	}

	@:noCompletion private static function __env(name:String, fallback:String):String {
		var value:String = Sys.getEnv(name);
		return value == null || value == "" ? fallback : value;
	}
	#end
}
