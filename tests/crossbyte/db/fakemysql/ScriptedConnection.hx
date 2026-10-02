package crossbyte.db.fakemysql;

#if !js
import sys.db.Connection;
import sys.db.ResultSet;

/**
 * A `sys.db.Connection` answering from a script, for the MySQL and SQLite
 * drivers' logic on targets with no native client: the interpreter, the jvm
 * without a Connector/J on its class path, hl and neko.
 *
 * Every statement is recorded in `sent`. One named in `failures` throws the
 * value mapped to it -- a string, or on the jvm a Java exception, which is
 * what JDBC throws -- and one named in `results` answers with those rows.
 * Anything else answers with no rows, as a write does.
 */
class ScriptedConnection implements Connection {
	public var sent:Array<String> = [];
	public var failures:Map<String, Dynamic> = new Map();
	public var results:Map<String, Array<Dynamic>> = new Map();
	public var closed:Bool = false;
	public var closeCount:Int = 0;

	/** What `lastInsertId()` answers -- an Int, as `sys.db.Connection` has it, wrapped past 2^31 where a driver wraps. **/
	public var insertId:Int = 0;

	/**
		The `length` of what a statement with no rows answers, as a driver
		gives a write's count -- an Int, wrapped past 2^31 where a driver
		wraps -- or null for 0.
	**/
	public var writeCount:Null<Int> = null;

	public function new() {}

	public function request(s:String):ResultSet {
		sent.push(s);

		if (failures.exists(s)) {
			throw failures.get(s);
		}

		var rows:Array<Dynamic> = results.get(s);
		return new ScriptedResultSet(rows == null ? [] : rows, rows == null ? writeCount : null);
	}

	public function close():Void {
		closed = true;
		closeCount++;
	}

	/** Backslash escaping, as MySQL's default mode wants. **/
	public function escape(s:String):String {
		var out:StringBuf = new StringBuf();

		for (i in 0...s.length) {
			var c:Int = StringTools.fastCodeAt(s, i);

			switch (c) {
				case 0:
					out.add("\\0");
				case 10:
					out.add("\\n");
				case 13:
					out.add("\\r");
				case 26:
					out.add("\\Z");
				case 34, 39, 92:
					out.addChar(92);
					out.addChar(c);
				default:
					out.addChar(c);
			}
		}

		return out.toString();
	}

	public function quote(s:String):String {
		return "'" + escape(s) + "'";
	}

	public function addValue(s:StringBuf, v:Dynamic):Void {
		s.add(v == null ? "NULL" : quote(Std.string(v)));
	}

	public function lastInsertId():Int {
		return insertId;
	}

	public function dbName():String {
		return "MySQL";
	}

	public function startTransaction():Void {
		request("START TRANSACTION");
	}

	public function commit():Void {
		request("COMMIT");
	}

	public function rollback():Void {
		request("ROLLBACK");
	}
}

class ScriptedResultSet implements ResultSet {
	public var length(get, null):Int;
	public var nfields(get, null):Int;

	private var __rows:Array<Dynamic>;
	private var __index:Int = 0;
	private var __count:Null<Int>;

	public function new(rows:Array<Dynamic>, ?count:Int) {
		__rows = rows;
		__count = count;
	}

	private function get_length():Int {
		return __count != null ? __count : __rows.length;
	}

	private function get_nfields():Int {
		return __rows.length == 0 ? 0 : Reflect.fields(__rows[0]).length;
	}

	public function hasNext():Bool {
		return __index < __rows.length;
	}

	public function next():Dynamic {
		return __index < __rows.length ? __rows[__index++] : null;
	}

	public function results():List<Dynamic> {
		var out:List<Dynamic> = new List();

		while (hasNext()) {
			out.add(next());
		}

		return out;
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
		return __rows.length == 0 ? [] : Reflect.fields(__rows[0]);
	}
}
#end
