package crossbyte.db.sql;

import haxe.io.Bytes;

/**
	One row of a result, read column by column, by index from 0, with the
	type the caller asks for.

	What a statement's `executeEach` hands its callback, once per row. There
	is one `SQLRow` per call, moved on to each row in turn, and no object is
	made for a row at all: a row is valid only inside the callback, and a
	value taken out of it (a `String`, `Bytes`) is the caller's to keep.

	Rows read this way cost what the database costs to read them. The same
	SELECT of 20,000 rows of 8 columns, natively on SQLite, takes 199-330 ns
	a row this way and 539-775 ns as an object per row with its fields read
	by name.

	Conversions follow the driver: on SQLite, as `sqlite3_column_*` converts
	(the text "12" read as an Int is 12); on MySQL and Postgres, from the
	text the server sent. A NULL reads as 0, 0.0, `false` or `null`; ask
	`isNull` to tell it from a value.
**/
interface SQLRow {
	/** How many columns the row has. **/
	var columnCount(get, never):Int;

	/** The name of column `index`, as the result names it. **/
	function columnName(index:Int):String;

	/** Whether column `index` is NULL. **/
	function isNull(index:Int):Bool;

	/** Column `index` as an `Int`; 0 for NULL. **/
	function getInt(index:Int):Int;

	/** Column `index` as a `Float`; 0.0 for NULL. **/
	function getFloat(index:Int):Float;

	/** Column `index` as a `Bool`: true for anything but 0, NULL and an empty or "0", "f" or "false" text. **/
	function getBool(index:Int):Bool;

	/** Column `index` as text; `null` for NULL. **/
	function getString(index:Int):Null<String>;

	/** Column `index` as bytes; `null` for NULL. **/
	function getBytes(index:Int):Null<Bytes>;

	/** Column `index` as the value an object row would hold in that field. **/
	function getValue(index:Int):Dynamic;
}
