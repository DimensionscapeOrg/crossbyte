package crossbyte.db.sql.sqlite._internal;

#if cpp
import crossbyte.db.sql.SQLRow;
import haxe.io.Bytes;

/**
	`SQLRow` over a prepared statement standing on a row: each read is one
	`sqlite3_column_*` call, and nothing is made for the row.
**/
@:noCompletion
@:allow(crossbyte.db.sql.sqlite._internal.NativeSQLiteConnection)
class SQLiteRow implements SQLRow {
	public var columnCount(get, never):Int;

	@:noCompletion private var __statement:NativeSQLiteStatement;

	@:noCompletion private function new(statement:NativeSQLiteStatement) {
		__statement = statement;
	}

	private function get_columnCount():Int {
		return __statement.columns;
	}

	public function columnName(index:Int):String {
		__check(index);
		return __statement.columnName(index);
	}

	public function isNull(index:Int):Bool {
		__check(index);
		return __statement.columnType(index) == NativeSQLiteStatement.NULL;
	}

	public function getInt(index:Int):Int {
		__check(index);
		return __statement.columnInt(index);
	}

	public function getFloat(index:Int):Float {
		__check(index);
		return __statement.columnFloat(index);
	}

	public function getBool(index:Int):Bool {
		__check(index);

		return switch (__statement.columnType(index)) {
			case NativeSQLiteStatement.NULL: false;
			case NativeSQLiteStatement.INTEGER: __statement.columnInt(index) != 0;
			case NativeSQLiteStatement.FLOAT: __statement.columnFloat(index) != 0;
			default:
				var text:String = __statement.columnText(index);
				!(text == null || text == "" || text == "0" || text == "f" || text == "false");
		}
	}

	public function getString(index:Int):Null<String> {
		__check(index);
		return __statement.columnType(index) == NativeSQLiteStatement.NULL ? null : __statement.columnText(index);
	}

	public function getBytes(index:Int):Null<Bytes> {
		__check(index);

		if (__statement.columnType(index) == NativeSQLiteStatement.NULL) {
			return null;
		}

		var data:haxe.io.BytesData = __statement.columnBlob(index);
		return Bytes.ofData(data);
	}

	public function getValue(index:Int):Dynamic {
		__check(index);
		return __statement.columnValue(index);
	}

	@:noCompletion private inline function __check(index:Int):Void {
		if (index < 0 || index >= __statement.columns) {
			throw new crossbyte.errors.RangeError('Column $index of ${__statement.columns}.');
		}
	}
}
#end
