package crossbyte.db;

import crossbyte.db.postgres.PostgresRawResult;
import crossbyte.db.postgres._internal.PostgresWire;
import crossbyte.db.sql.SQLRow;
import crossbyte.db.sql.SQLValue;
import crossbyte.db.sql._internal.ParamBinder.ParamTemplate;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import utest.Assert;
#if !js
import crossbyte.db.fakemysql.ScriptedConnection;
import crossbyte.db.mysql.MySQLStatement;
import crossbyte.db.postgres.PostgresStatement;
#end

/**
	Rows read by column (`SQLRow`, `executeEach`), the result block both of
	Postgres's request paths share, statement texts split once at their
	placeholders, and `SQLValue` parameters on MySQL and Postgres. SQLite's
	are in SQLiteBindingTest, natively.
**/
class SQLRowTest extends utest.Test {
	public function testABlockIsReadRowByRowInPlace():Void {
		var block:Bytes = __block(["id", "name", "data"], [["1", "one", "\\x00ff"], ["2", null, "plain"]], 7, "SELECT 2");
		var seen:Array<String> = [];
		var changed:Float = PostgresWire.eachRow(block, function(row:SQLRow):Void {
			seen.push(row.columnCount + ":" + row.columnName(0) + "=" + row.getInt(0) + "," + row.getString(1) + "," + row.isNull(1) + ","
				+ row.getBytes(2).toHex() + "," + row.getBool(0) + "," + row.getFloat(0));
		});

		Assert.equals("3:id=1,one,false,00ff,true,1|3:id=2,null,true," + Bytes.ofString("plain").toHex() + ",true,2", seen.join("|"));
		// A statement that returns rows changed none.
		Assert.equals(0.0, changed);
		Assert.raises(() -> PostgresWire.eachRow(block, row -> row.getInt(3)), crossbyte.errors.RangeError);
	}

	public function testABlocksRowsDecodeAsObjectsWithTheirCommand():Void {
		var block:Bytes = __block(["a", "b", "c", "d", "e", "f", "g"], [["1", "2", "3", "4", "5", "6", "7"], ["x", null, "z", "", "e", "f", "g"]], 2,
			"SELECT 2");
		var decoded = PostgresWire.decodeRows(block, []);
		Assert.equals("SELECT 2", decoded.command);
		Assert.equals(2.0, decoded.affectedRows);
		Assert.equals("a,b,c,d,e,f,g", decoded.fields.join(","));
		Assert.equals("7", decoded.rows[0].g);
		Assert.isNull(decoded.rows[1].b);
		Assert.isTrue(Reflect.hasField(decoded.rows[1], "b"), "a NULL is there, holding null");
		Assert.equals("", decoded.rows[1].d);

		var raw:PostgresRawResult = PostgresWire.decodeResult(block);
		// A class, not an anonymous structure.
		Assert.isTrue(Std.isOfType(raw, PostgresRawResult));
		Assert.equals("SELECT 2", raw.command);
		Assert.equals("x", raw.rows[1][0].toString());
	}

	public function testABlockWithoutACommandStillDecodes():Void {
		// As a bridge built before the command tag sent it.
		var block:Bytes = __block(["n"], [["5"]], 1, null);
		Assert.isNull(PostgresWire.decodeResult(block).command);
		Assert.equals("5", PostgresWire.decodeRows(block, []).rows[0].n);
	}

	public function testAnErrorBlockRaisesBeforeAnyRow():Void {
		var out:BytesBuffer = new BytesBuffer();
		__int(out, PostgresWire.STATUS_ERROR);
		__text(out, "relation \"t\" does not exist");
		var block:Bytes = out.getBytes();
		var rows:Int = 0;
		Assert.raises(() -> PostgresWire.check(block), crossbyte.errors.SQLError);
		Assert.raises(() -> PostgresWire.eachRow(block, _ -> rows++), crossbyte.errors.SQLError);
		Assert.equals(0, rows);
	}

	public function testATemplateRendersAsTheScanSubstitutes():Void {
		var sql:String = "SELECT ':a' AS q, :a, :b, :absent -- :a\n, \"x:a\", :a";
		var template:ParamTemplate = ParamTemplate.parse(sql, false, false);
		var values:Map<String, Dynamic> = ["a" => "A", "b" => null];
		var map:haxe.ds.StringMap<Dynamic> = cast values;
		Assert.equals("SELECT ':a' AS q, <A>, <null>, :absent -- :a\n, \"x:a\", <A>", template.renderMap(map, v -> "<" + Std.string(v) + ">"));
		Assert.isTrue(template.matches(sql, false, false));
		Assert.isFalse(template.matches(sql, true, false));
		// Text with no placeholder is itself, not a copy.
		var plain:String = "SELECT 1";
		Assert.isTrue(ParamTemplate.parse(plain, false, false).renderMap(map, v -> "?") == plain);
	}

	#if !js
	public function testMySQLExecuteEachReadsTheRowsByColumn():Void {
		var wire:ScriptedConnection = new ScriptedConnection();
		var statement:MySQLStatement = new MySQLStatement();
		@:privateAccess statement.__connection = wire;
		statement.text = "SELECT id, name FROM t WHERE id > :from";
		statement.parameters.from = 0;
		wire.results.set("SELECT id, name FROM t WHERE id > 0", [{id: 1, name: "one"}, {id: 2, name: null}]);
		var seen:Array<String> = [];
		// The scripted result names its columns in the order the target
		// lists an object's fields; a server's are in the statement's order.
		var changed:Float = statement.executeEach(row -> {
			var id:Int = row.columnName(0) == "id" ? 0 : 1;
			var name:Int = 1 - id;
			seen.push(row.getInt(id) + ":" + row.getString(name) + ":" + row.isNull(name) + ":" + row.columnCount);
		});
		Assert.equals("1:one:false:2,2:null:true:2", seen.join(","));
		Assert.equals(0.0, changed);

		// A write answers what it changed, and calls nothing.
		wire.writeCount = 3;
		statement.text = "UPDATE t SET name = :name";
		statement.parameters.name = "x";
		Assert.equals(3.0, statement.executeEach(_ -> Assert.fail("a write has no rows")));
	}

	@:access(crossbyte.db.postgres.PostgresStatement)
	public function testPostgresParametersAreWrittenAsTheirTypes():Void {
		// Parameters of every type: an Int, Bytes or a Date compiles.
		var statement:PostgresStatement = new PostgresStatement();
		var values:Array<SQLValue> = [7, 1.5, true, haxe.Int64.parseString("9007199254740993"), Bytes.ofHex("00ff"), Date.fromTime(1790685296250.0),
			"it's", null, Math.NaN];
		var names:Array<String> = [];

		for (i in 0...values.length) {
			statement.parameters["p" + i] = values[i];
			names.push(":p" + i);
		}

		var sql:String = statement.__applyParameters("VALUES (" + names.join(", ") + ")");
		// hl's and neko's Date keep whole seconds.
		var fraction:String = Date.fromTime(1790685296250.0).getTime() % 1000 == 250 ? "250" : "000";
		Assert.equals("VALUES (7, 1.5, TRUE, 9007199254740993, '\\x00ff', '2026-09-29T12:34:56." + fraction + "Z', 'it''s', NULL, 'NaN')", sql);
	}
	#end

	/** A result block as the bridge writes it; `command` null for one from before the command tag. **/
	private static function __block(fields:Array<String>, rows:Array<Array<String>>, affected:Int, command:Null<String>):Bytes {
		var out:BytesBuffer = new BytesBuffer();
		__int(out, PostgresWire.STATUS_OK);
		__int(out, affected);
		__int(out, 0);
		__int(out, 0);
		__int(out, fields.length);

		for (field in fields) {
			__text(out, field);
		}

		__int(out, rows.length);

		for (row in rows) {
			for (value in row) {
				if (value == null) {
					__int(out, -1);
				} else {
					__text(out, value);
				}
			}
		}

		if (command != null) {
			__text(out, command);
		}

		return out.getBytes();
	}

	private static function __int(out:BytesBuffer, value:Int):Void {
		out.addByte(value & 0xFF);
		out.addByte((value >> 8) & 0xFF);
		out.addByte((value >> 16) & 0xFF);
		out.addByte((value >> 24) & 0xFF);
	}

	private static function __text(out:BytesBuffer, text:String):Void {
		var bytes:Bytes = Bytes.ofString(text);
		__int(out, bytes.length);
		out.add(bytes);
	}
}
