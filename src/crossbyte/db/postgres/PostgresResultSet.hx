package crossbyte.db.postgres;

// Built where PostgresConnection is: not for the browser.
#if !(js && !nodejs)
#if !js
import sys.db.ResultSet;
#end

/**
	The rows `PostgresConnection.request()` answers, read in order: each an
	object with a field per column, holding the column's text, or `null` for
	NULL, or, on PHP, what PDO makes of it.

	A `sys.db.ResultSet`, like the other drivers' `request()`.
	`getResult(n)` and its kin read field `n` of the row `next()` last
	gave, in column order.
**/
class PostgresResultSet #if !js implements ResultSet #end {
	/** How many rows it holds. **/
	public var length(get, null):Int;

	/** How many columns each row has. **/
	public var nfields(get, null):Int;

	@:noCompletion private var __rows:Array<Dynamic>;
	@:noCompletion private var __fields:Null<Array<String>>;
	@:noCompletion private var __index:Int = 0;

	@:noCompletion @:allow(crossbyte.db.postgres) private function new(rows:Array<Dynamic>, ?fields:Array<String>) {
		__rows = rows != null ? rows : [];
		__fields = fields;
	}

	private function get_length():Int {
		return __rows.length;
	}

	private function get_nfields():Int {
		var fields:Null<Array<String>> = getFieldsNames();
		return fields == null ? 0 : fields.length;
	}

	public function hasNext():Bool {
		return __index < __rows.length;
	}

	public function next():Dynamic {
		return __index < __rows.length ? __rows[__index++] : null;
	}

	public function results():List<Dynamic> {
		var out:List<Dynamic> = new List();

		while (__index < __rows.length) {
			out.add(__rows[__index++]);
		}

		return out;
	}

	public function getResult(n:Int):String {
		var value:Dynamic = __current(n);
		return value == null ? null : Std.string(value);
	}

	public function getIntResult(n:Int):Int {
		var value:Dynamic = __current(n);

		if (value == null) {
			return 0;
		}

		if (Std.isOfType(value, Int)) {
			return value;
		}

		var parsed:Null<Int> = Std.parseInt(Std.string(value));
		return parsed == null ? 0 : parsed;
	}

	public function getFloatResult(n:Int):Float {
		var value:Dynamic = __current(n);

		if (value == null) {
			return 0;
		}

		var parsed:Float = Std.parseFloat(Std.string(value));
		return Math.isNaN(parsed) ? 0 : parsed;
	}

	public function getFieldsNames():Null<Array<String>> {
		if (__fields == null && __rows.length > 0) {
			__fields = Reflect.fields(__rows[0]);
		}

		return __fields;
	}

	/** Field `n` of the row `next()` last gave. **/
	@:noCompletion private function __current(n:Int):Dynamic {
		var fields:Null<Array<String>> = getFieldsNames();

		if (__index == 0 || fields == null || n < 0 || n >= fields.length) {
			throw new crossbyte.errors.RangeError('No field $n of a current row.');
		}

		return Reflect.field(__rows[__index - 1], fields[n]);
	}
}
#end
