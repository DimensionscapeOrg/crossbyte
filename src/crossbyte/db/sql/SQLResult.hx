package crossbyte.db.sql;

/** Immutable row-and-metadata container returned from SQL-style queries. */
class SQLResult {
	public var complete(default, null):Bool;
	public var data(default, null):Array<Dynamic>;
	public var lastInsertRowID(default, null):Float;
	public var rowsAffected(default, null):Float;

	public function new(data:Array<Dynamic> = null, rowsAffected:Float = 0, complete:Bool = true, rowID:Float = 0) {
		this.data = data;
		this.rowsAffected = rowsAffected;
		this.complete = complete;
		this.lastInsertRowID = rowID;
	}
}
