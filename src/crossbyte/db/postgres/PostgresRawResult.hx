package crossbyte.db.postgres;

import haxe.io.Bytes;

/**
	What one query returned, before anything has decided which columns are
	text: what `PostgresConnection.requestParams` answers.

	Values are bytes, not strings: a `bytea` column and a `text` column
	holding invalid UTF-8 both have to survive the trip.

	A class, where it was an anonymous structure: its fields are read
	directly rather than looked up by name, and an object literal with these
	fields still makes one.
**/
@:structInit
final class PostgresRawResult {
	/** The column names, in order. **/
	public final fields:Array<String>;

	/** Each row's values by column, `null` for NULL. **/
	public final rows:Array<Array<Null<Bytes>>>;

	/** Rows the statement changed, or a SELECT returned: exact to 2^53. **/
	public final affectedRows:Float;

	/** `PQoidValue`: an unsigned 32-bit OID, 0 on PostgreSQL 12 and later. **/
	public final lastInsertRowID:Float;

	/** The server's command tag -- `INSERT 0 1`, `COMMIT`, `ROLLBACK` -- or null when the bridge sent none. **/
	public final command:Null<String>;

	public function new(fields:Array<String>, rows:Array<Array<Null<Bytes>>>, affectedRows:Float, lastInsertRowID:Float, ?command:String) {
		this.fields = fields;
		this.rows = rows;
		this.affectedRows = affectedRows;
		this.lastInsertRowID = lastInsertRowID;
		this.command = command;
	}
}
