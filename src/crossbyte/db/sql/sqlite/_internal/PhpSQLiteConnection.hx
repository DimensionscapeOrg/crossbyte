package crossbyte.db.sql.sqlite._internal;

#if php
import sys.db.Connection;
import sys.db.ResultSet;

/**
	PHP's SQLite connection (`sys.db.Sqlite`), with each statement run once.

	PHP's `SQLite3::query` runs a statement as it is asked, and
	`SQLite3Result::fetchArray`, on the result of a statement with no result
	columns, runs it again: reading such a result, even only to ask its
	length or whether it has a row, would insert a row twice, or fail a
	BEGIN with "cannot start a transaction within a transaction". So a
	result with no columns is replaced, as it arrives, by one with no rows
	whose length is the rows the statement changed, which is what hxcpp's
	gives. Results with columns are PHP's own, read as they come.
**/
@:noCompletion
class PhpSQLiteConnection implements Connection {
	@:noCompletion private var __inner:Connection;
	@:noCompletion private var __database:php.db.SQLite3;

	public function new(inner:Connection) {
		__inner = inner;
		// The SQLite3 object std's connection keeps, for its count of the
		// rows the last statement changed.
		__database = php.Syntax.field(inner, "db");
	}

	public function request(s:String):ResultSet {
		var result:ResultSet = __inner.request(s);

		if (result != null && result.nfields == 0) {
			// Dropped unread: PHP frees it, and the statement with it, here.
			return new PhpChangedRows(__database.changes());
		}

		return result;
	}

	public function close():Void {
		__inner.close();
	}

	public function escape(s:String):String {
		return __inner.escape(s);
	}

	public function quote(s:String):String {
		return __inner.quote(s);
	}

	public function addValue(s:StringBuf, v:Dynamic):Void {
		__inner.addValue(s, v);
	}

	public function lastInsertId():Int {
		return __inner.lastInsertId();
	}

	public function dbName():String {
		return __inner.dbName();
	}

	public function startTransaction():Void {
		__inner.startTransaction();
	}

	public function commit():Void {
		__inner.commit();
	}

	public function rollback():Void {
		__inner.rollback();
	}
}

/** The result of a statement with no result columns: no rows, and the rows it changed as its length. **/
@:noCompletion
private class PhpChangedRows implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	@:noCompletion private var __changed:Int;

	public function new(changed:Int) {
		__changed = changed;
	}

	private function get_length():Int {
		return __changed;
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
		return null;
	}

	public function getIntResult(n:Int):Int {
		return 0;
	}

	public function getFloatResult(n:Int):Float {
		return 0;
	}

	public function getFieldsNames():Null<Array<String>> {
		return [];
	}
}
#end
