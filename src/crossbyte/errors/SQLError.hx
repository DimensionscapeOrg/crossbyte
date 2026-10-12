package crossbyte.errors;

/** A database failure: what was being done, and what the database said. */
class SQLError extends Error {
	/** What was being done: an `SQLEvent` type, or `"request"`, `"migrate"` and the like. **/
	public var operation(default, null):String;

	private var __details:String;

	/**
		@param operation What was being done.
		@param details What the database said, as `details()` gives it.
		@param message The error's message.
		@param id The database's error number, where it has one; see `Error.errorID`.
	**/
	public function new(operation:String, details:String = "", message:String = "", id:Int = 0) {
		super(message, id);
		name = "SQLError";
		this.operation = operation;
		this.__details = details;
	}

	override public function details():String {
		return __details;
	}

	override public function toString():String {
		return super.toString();
	}
}
