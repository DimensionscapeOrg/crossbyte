package crossbyte.db;

#if cpp
import crossbyte.db.sql.SQLRow;
import crossbyte.db.sql.SQLValue;
import crossbyte.db.sql.sqlite.SQLiteConnection;
import crossbyte.db.sql.sqlite.SQLiteMode;
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.SQLError;
import crossbyte.test.Require;
import haxe.Int64;
import haxe.io.Bytes;
import utest.Assert;

/**
	SQLite statements prepared once and kept, their parameters bound as their
	types (`SQLValue`), their rows made with fixed slots, and read by column
	with `executeEach`.

	Parameters were `String`s, written into the statement's text as quoted
	literals, and the text prepared again on every run.
**/
class SQLiteBindingTest extends utest.Test {
	public function testParametersAreBoundAsTheirTypes():Void {
		var connection:SQLiteConnection = __open();
		connection.request("CREATE TABLE v (x)");
		var insert:SQLiteStatement = __statement(connection, "INSERT INTO v (x) VALUES (:x)");
		var blob:Bytes = Bytes.ofHex("00ff7f8001");
		var values:Array<SQLValue> = [7, 2.5, 3.0, true, Int64.make(0x12, 0x34567890), "it's", blob, null];

		for (value in values) {
			insert.parameters.x = value;
			insert.execute();
		}

		var rows:Array<Dynamic> = __rows(connection, "SELECT typeof(x) AS t, x FROM v ORDER BY rowid");
		Assert.equals("integer,real,integer,integer,integer,text,blob,null", [for (row in rows) Std.string(row.t)].join(","));
		Assert.equals(7, rows[0].x);
		Assert.equals(2.5, rows[1].x);
		// A whole Float is an integer, as its literal text was.
		Assert.equals(3, rows[2].x);
		Assert.equals(1, rows[3].x);
		Assert.equals("78187493520", Int64.toStr(rows[4].x));
		Assert.equals("it's", rows[5].x);
		// A blob, byte for byte: it was written as the text Bytes.toString gives.
		var back:Bytes = Bytes.ofData(rows[6].x);
		Assert.equals("00ff7f8001", back.toHex());
		Assert.isNull(rows[7].x);
		connection.close();
	}

	public function testAStringHoldingANulIsKeptWhole():Void {
		var connection:SQLiteConnection = __open();
		connection.request("CREATE TABLE v (x)");
		var insert:SQLiteStatement = __statement(connection, "INSERT INTO v (x) VALUES (:x)");
		insert.parameters.x = "a" + String.fromCharCode(0) + "b";
		insert.execute();
		var rows:Array<Dynamic> = __rows(connection, "SELECT typeof(x) AS t, length(CAST(x AS BLOB)) AS n FROM v");
		// As before: a blob of its bytes, since a quoted literal cannot hold it.
		Assert.equals("blob", rows[0].t);
		Assert.equals(3, rows[0].n);
		connection.close();
	}

	public function testEachRunBindsItsOwnValues():Void {
		var connection:SQLiteConnection = __open();
		var select:SQLiteStatement = __statement(connection, "SELECT :a AS a, :b AS b");

		select.parameters.a = 1;
		select.parameters.b = "one";
		select.execute();
		var first:Dynamic = select.getResult().data[0];
		Assert.equals(1, first.a);
		Assert.equals("one", first.b);

		// A value no longer set reads as NULL, not as the last run's.
		select.clearParameters();
		select.parameters.a = 2;
		select.execute();
		var second:Dynamic = select.getResult().data[0];
		Assert.equals(2, second.a);
		Assert.isNull(second.b);

		// Placeholders that are not :name stay unbound, NULL, as before.
		select.text = "SELECT ? AS q, @a AS at, $a AS dollar, :a AS colon";
		select.execute();
		var third:Dynamic = select.getResult().data[0];
		Assert.isNull(third.q);
		Assert.isNull(third.at);
		Assert.isNull(third.dollar);
		Assert.equals(2, third.colon);

		// Inside a literal or a comment a :name is text, as SQLite reads it.
		select.text = "SELECT ':a' AS quoted -- :a";
		select.execute();
		Assert.equals(":a", select.getResult().data[0].quoted);
		connection.close();
	}

	public function testAWideRowReadsBackEveryColumn():Void {
		// Rows are made with fixed slots, found by a binary search over the
		// signed hash of their names past the fifth: ordered by the unsigned
		// hash, every column whose hash has its top bit set read as absent.
		var connection:SQLiteConnection = __open();
		var names:Array<String> = [for (i in 0...40) "column_" + i + "_" + StringTools.hex((i * 40503) & 0xFFFF)];
		var sql:String = "SELECT " + [for (i in 0...names.length) i + " AS " + names[i]].join(", ");
		var viaStatement:Dynamic = __statement(connection, sql).runAll()[0];
		var viaRequest:Dynamic = __rows(connection, sql)[0];

		for (row in [viaStatement, viaRequest]) {
			var missing:Array<String> = [];

			for (i in 0...names.length) {
				if (Reflect.field(row, names[i]) != i) {
					missing.push(names[i]);
				}
			}

			Assert.equals(0, missing.length, "columns that did not read back: " + missing.join(", "));
			Assert.equals(names.length, Reflect.fields(row).length);
		}

		connection.close();
	}

	public function testAKeptStatementSeesTheSchemaChange():Void {
		var connection:SQLiteConnection = __open();
		connection.request("CREATE TABLE t (a INTEGER)");
		connection.request("INSERT INTO t VALUES (1)");
		var select:RunnableStatement = __statement(connection, "SELECT * FROM t");
		Assert.equals(1, Reflect.fields(select.runAll()[0]).length);

		connection.request("ALTER TABLE t ADD COLUMN b TEXT DEFAULT 'x'");
		var row:Dynamic = select.runAll()[0];
		Assert.equals("x", row.b, "the kept statement was prepared again for the new column");

		connection.request("DROP TABLE t");
		var error:SQLError = null;

		try {
			select.execute();
		} catch (e:SQLError) {
			error = e;
		}

		Require.notNull(error);
		Assert.isTrue(error.details().indexOf("no such table") >= 0, error.details());
		connection.close();
	}

	public function testCloseFinalizesWhatWasPrepared():Void {
		// SQLite will not close a connection with a statement left
		// unfinalized, and the glue then throws from close().
		var directory:String = haxe.io.Path.join([Sys.getCwd(), "export"]);

		if (!sys.FileSystem.exists(directory)) {
			sys.FileSystem.createDirectory(directory);
		}

		var path:String = haxe.io.Path.join([directory, "sqlite-binding-" + Std.random(0x7FFFFFFF) + ".db"]);
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(path, SQLiteMode.CREATE, false, 4096);
		connection.request("CREATE TABLE t AS WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50) SELECT i FROM n");

		for (i in 0...100) {
			// More texts than the connection keeps: the oldest are let go.
			connection.request("SELECT i FROM t WHERE i = " + i);
		}

		// One left part way through its rows.
		var paged:SQLiteStatement = __statement(connection, "SELECT i FROM t ORDER BY i");
		paged.execute(5);
		Assert.isTrue(paged.executing);
		connection.close();

		// Closed: the file is free to open and to delete.
		var again:SQLiteConnection = new SQLiteConnection();
		again.open(path, SQLiteMode.UPDATE, false, 4096);
		Assert.equals(50, __rows(again, "SELECT COUNT(*) AS n FROM t")[0].n);
		again.close();
		sys.FileSystem.deleteFile(path);
	}

	public function testExecuteEachReadsEveryColumnByIndex():Void {
		var connection:SQLiteConnection = __open();
		connection.request("CREATE TABLE r (id INTEGER, name TEXT, score REAL, flag BOOL, data BLOB, missing TEXT)");
		var insert:SQLiteStatement = __statement(connection, "INSERT INTO r VALUES (:id, :name, :score, :flag, :data, NULL)");

		for (i in 0...3) {
			insert.parameters.id = i;
			insert.parameters.name = "row " + i;
			insert.parameters.score = i + 0.5;
			insert.parameters.flag = i % 2 == 0;
			insert.parameters.data = Bytes.ofString("d" + i);
			insert.execute();
		}

		var select:SQLiteStatement = __statement(connection, "SELECT id, name, score, flag, data, missing FROM r WHERE id >= :from ORDER BY id");
		select.parameters.from = 1;
		var seen:Array<String> = [];
		var names:Array<String> = null;
		var changed:Float = select.executeEach(function(row:SQLRow):Void {
			if (names == null) {
				names = [for (i in 0...row.columnCount) row.columnName(i)];
			}

			seen.push(row.getInt(0) + "|" + row.getString(1) + "|" + row.getFloat(2) + "|" + row.getBool(3) + "|" + row.getBytes(4).toString() + "|"
				+ row.isNull(5) + "|" + row.getString(5) + "|" + row.getValue(0));
		});

		Assert.equals("id,name,score,flag,data,missing", names.join(","));
		Assert.equals("1|row 1|1.5|false|d1|true|null|1,2|row 2|2.5|true|d2|true|null|2", seen.join(","));
		Assert.equals(0.0, changed);

		// A write answers what it changed.
		var update:SQLiteStatement = __statement(connection, "UPDATE r SET score = score + 1 WHERE id < :n");
		update.parameters.n = 2;
		Assert.equals(2.0, update.executeEach(_ -> Assert.fail("a write has no rows")));
		connection.close();
	}

	public function testExecuteEachBetweenPagesKeepsThePagedRows():Void {
		var connection:SQLiteConnection = __open();
		connection.request("CREATE TABLE t AS WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 30) SELECT i FROM n");
		var paged:SQLiteStatement = __statement(connection, "SELECT i FROM t ORDER BY i");
		var counter:SQLiteStatement = __statement(connection, "SELECT COUNT(*) FROM t");
		paged.execute(10);
		var read:Int = paged.getResult().data.length;

		while (paged.executing) {
			var counted:Int = 0;
			counter.executeEach(row -> counted = row.getInt(0));
			Assert.equals(30, counted);
			paged.next(10);
			var page = paged.getResult();
			read += page == null ? 0 : page.data.length;
		}

		Assert.equals(30, read);
		connection.close();
	}

	public function testAFailureInsideExecuteEachIsThrownAsItIs():Void {
		var connection:SQLiteConnection = __open();
		var select:SQLiteStatement = __statement(connection, "SELECT 1 UNION ALL SELECT 2");
		var thrown:Dynamic = null;

		try {
			select.executeEach(_ -> throw "stop");
		} catch (e:Dynamic) {
			thrown = e;
		}

		Assert.equals("stop", thrown);
		// The statement is free to run again.
		var count:Int = 0;
		select.executeEach(_ -> count++);
		Assert.equals(2, count);

		var refused:SQLError = null;
		select.text = "SELECT FROM";

		try {
			select.executeEach(_ -> {});
		} catch (e:SQLError) {
			refused = e;
		}

		Require.notNull(refused);
		connection.close();
	}

	public function testExecuteEachNeedsASynchronousConnection():Void {
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.openAsync(null, SQLiteMode.CREATE, false, 4096);
		var select:SQLiteStatement = __statement(connection, "SELECT 1");
		Assert.raises(() -> select.executeEach(_ -> {}), IllegalOperationError);
		connection.close();
	}

	public function testTheConnectionsOwnReadsAnswerClasses():Void {
		// They were anonymous structures, read by name.
		var connection:SQLiteConnection = __open();
		connection.request("CREATE TABLE p (id INTEGER PRIMARY KEY)");
		connection.request("CREATE TABLE c (id INTEGER, p INTEGER REFERENCES p(id))");
		connection.request("INSERT INTO c VALUES (1, 99)");
		var stats = connection.stats();
		Assert.isTrue(Std.isOfType(stats, crossbyte.db.sql.sqlite.SQLiteConnection.DBStats));
		Assert.isTrue(stats.pageSize > 0);
		var violations = connection.foreignKeyCheck();
		Assert.equals(1, violations.length);
		Assert.isTrue(Std.isOfType(violations[0], crossbyte.db.sql.sqlite.SQLiteConnection.FKViolation));
		Assert.equals("c", violations[0].table);
		connection.loadSchema();
		var schema = connection.getSchemaResult();
		Assert.isTrue(Std.isOfType(schema, crossbyte.db.sql.sqlite.SQLiteConnection.SQLSchemaResult));
		Assert.isTrue(Std.isOfType(schema.tables[0], crossbyte.db.sql.sqlite.SQLiteConnection.SQLTableSchema));
		Assert.isTrue(Std.isOfType(schema.tables[0].columns[0], crossbyte.db.sql.sqlite.SQLiteConnection.SQLColumnSchema));
		Assert.isTrue(Std.isOfType(connection.walCheckpoint(), crossbyte.db.sql.sqlite.SQLiteConnection.WalCheckpointResult));
		connection.close();
	}

	private static function __open():SQLiteConnection {
		var connection:SQLiteConnection = new SQLiteConnection();
		connection.open(null, SQLiteMode.CREATE, false, 4096);
		return connection;
	}

	private static function __statement(connection:SQLiteConnection, text:String):RunnableStatement {
		var statement:RunnableStatement = new RunnableStatement();
		statement.sqlConnection = connection;
		statement.text = text;
		return statement;
	}

	private static function __rows(connection:SQLiteConnection, sql:String):Array<Dynamic> {
		return [for (row in connection.request(sql)) row];
	}
}

private class RunnableStatement extends SQLiteStatement {
	public function runAll():Array<Dynamic> {
		execute();
		return getResult().data;
	}
}
#end
