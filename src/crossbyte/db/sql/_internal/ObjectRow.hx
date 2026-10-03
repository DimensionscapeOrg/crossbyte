package crossbyte.db.sql._internal;

import crossbyte.db.sql.SQLRow;
import haxe.io.Bytes;

/**
	`SQLRow` over a driver's row object, read by the result's column names:
	for a driver whose client makes an object of every row anyway (MySQL's),
	so that `executeEach` reads the same way on every driver. Moved on to
	each row in turn; nothing more is made for a row.
**/
@:noCompletion
class ObjectRow implements SQLRow {
	public var columnCount(get, never):Int;

	@:noCompletion private var __names:Array<String>;
	@:noCompletion private var __row:Dynamic;

	public function new(names:Array<String>) {
		__names = names;
	}

	/** Stands on `row`. **/
	public inline function moveTo(row:Dynamic):Void {
		__row = row;
	}

	private function get_columnCount():Int {
		return __names.length;
	}

	public function columnName(index:Int):String {
		__check(index);
		return __names[index];
	}

	public function isNull(index:Int):Bool {
		return getValue(index) == null;
	}

	public function getInt(index:Int):Int {
		var value:Dynamic = getValue(index);

		if (value == null) {
			return 0;
		}

		if (Std.isOfType(value, Int)) {
			return value;
		}

		if (Std.isOfType(value, Bool)) {
			return value ? 1 : 0;
		}

		if (Std.isOfType(value, Float)) {
			return Std.int(value);
		}

		var parsed:Null<Int> = Std.parseInt(Std.string(value));
		return parsed == null ? 0 : parsed;
	}

	public function getFloat(index:Int):Float {
		var value:Dynamic = getValue(index);

		if (value == null) {
			return 0.0;
		}

		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			return value;
		}

		if (Std.isOfType(value, Bool)) {
			return value ? 1.0 : 0.0;
		}

		var parsed:Float = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? 0.0 : parsed;
	}

	public function getBool(index:Int):Bool {
		var value:Dynamic = getValue(index);

		if (value == null) {
			return false;
		}

		if (Std.isOfType(value, Bool)) {
			return value;
		}

		if (Std.isOfType(value, Int) || Std.isOfType(value, Float)) {
			return value != 0;
		}

		var text:String = Std.string(value);
		return !(text == "" || text == "0" || text == "f" || text == "false");
	}

	public function getString(index:Int):Null<String> {
		var value:Dynamic = getValue(index);

		if (value == null) {
			return null;
		}

		if (Std.isOfType(value, Bytes)) {
			return (value : Bytes).toString();
		}

		return Std.string(value);
	}

	public function getBytes(index:Int):Null<Bytes> {
		var value:Dynamic = getValue(index);

		if (value == null) {
			return null;
		}

		if (Std.isOfType(value, Bytes)) {
			return value;
		}

		return Bytes.ofString(Std.string(value));
	}

	public function getValue(index:Int):Dynamic {
		__check(index);
		return Reflect.field(__row, __names[index]);
	}

	@:noCompletion private inline function __check(index:Int):Void {
		if (index < 0 || index >= __names.length) {
			throw new crossbyte.errors.RangeError('Column $index of ${__names.length}.');
		}
	}
}
