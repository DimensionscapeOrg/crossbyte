package crossbyte.db.sql.sqlite._internal;

#if !js
import crossbyte.db.sql.sqlite.SQLiteStatement;
import crossbyte.errors.SQLError;
import crossbyte.events.Event;
import crossbyte.events.SQLErrorEvent;

/**
	One piece of work queued for an asynchronous `SQLiteConnection`'s worker.

	`run` does the work on the worker's thread and reports how it went.
	`operation` -- the `SQLEvent` type it reports -- and `statement`, the
	statement it reports to or `null` for the connection's own work, say whom
	to tell when it never runs: queued behind a `close()`, or behind an open
	that failed.
**/
@:noCompletion
class SQLiteJob {
	public var run(default, null):Void->Void;
	public var operation(default, null):String;
	public var statement(default, null):Null<SQLiteStatement>;

	public function new(run:Void->Void, operation:String, statement:Null<SQLiteStatement>) {
		this.run = run;
		this.operation = operation;
		this.statement = statement;
	}
}

/**
	What a statement's work on the worker sends back to the runtime's thread:
	the page it read, there, and the event to dispatch with it.

	The rows are read on the worker. They were read on the runtime's thread
	from the result set the worker handed over, while the worker had already
	gone on to the next statement -- and hxcpp's glue starts a statement by
	finalizing the one before it, so a statement queued behind another took
	all but the first of its rows.
**/
@:noCompletion
class SQLiteStatementMessage {
	public var statement(default, null):SQLiteStatement;
	public var event:Event;

	/** The page read, or `null` when there is none to queue. **/
	public var rows:Null<Array<Dynamic>> = null;

	/** Whether no rows remain: the statement has finished. **/
	public var done:Bool = false;

	/** Whether this answers `execute()`, which sets the rows affected; `next()` leaves them. **/
	public var executed:Bool;

	public var affected:Float = 0;

	/** The statement's rowid, read once its rows were all read; meaningful when `done`. **/
	public var rowId:Float = 0;

	public function new(statement:SQLiteStatement, executed:Bool) {
		this.statement = statement;
		this.executed = executed;
	}

	/** Turns this into the report of a failure. **/
	public function fail(error:SQLError):Void {
		rows = null;
		done = true;
		event = new SQLErrorEvent(SQLErrorEvent.ERROR, error);
	}
}
#end
