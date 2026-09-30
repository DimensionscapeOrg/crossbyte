package crossbyte.db.mongodb;

import crossbyte.errors.SQLError;

/**
	One document a write could not apply: its position in what was sent, and
	the server's reason.
**/
typedef MongoWriteError = {
	/** The document's position among those passed to the call, from 0. **/
	var index:Int;

	var code:Int;
	var codeName:String;
	var message:String;
}

/**
	A command the MongoDB server answered with an error, carrying the
	server's own account of it.

	`errorID` and `codeName` say which error it was, 11000 `DuplicateKey`, 13
	`Unauthorized`, 50 `MaxTimeMSExpired`, so a caller can tell a duplicate
	from a deadlock without reading prose. A write that applied some
	documents and refused others reports each refusal in `writeErrors`, and
	how many it did apply in `result`. A `SQLError`, so code catching the
	other drivers' failures catches this too.

	A failure to reach or talk to the server is an `IOError` instead.
**/
class MongoError extends SQLError {
	public static inline var AUTHENTICATION_FAILED:Int = 18;
	public static inline var UNAUTHORIZED:Int = 13;
	public static inline var NAMESPACE_NOT_FOUND:Int = 26;
	public static inline var COMMAND_NOT_FOUND:Int = 59;
	public static inline var WRITE_CONCERN_FAILED:Int = 64;
	public static inline var MAX_TIME_MS_EXPIRED:Int = 50;
	public static inline var CURSOR_NOT_FOUND:Int = 43;
	public static inline var NO_SUCH_TRANSACTION:Int = 251;
	public static inline var DUPLICATE_KEY:Int = 11000;

	/** The label on an error that means the whole transaction may be retried. **/
	public static inline var TRANSIENT_TRANSACTION_ERROR:String = "TransientTransactionError";

	/** The label on a commit whose outcome is unknown, which may be retried. **/
	public static inline var UNKNOWN_TRANSACTION_COMMIT_RESULT:String = "UnknownTransactionCommitResult";

	/** The server's name for the code, such as `DuplicateKey`, or `""`. **/
	public var codeName(default, null):String;

	/** Labels the server put on the error, such as `TransientTransactionError`. **/
	public var errorLabels(default, null):Array<String>;

	/** The documents a write refused, with their reasons; empty for other errors. **/
	public var writeErrors(default, null):Array<MongoWriteError>;

	/** Set when the write was applied but its write concern was not met. **/
	public var writeConcernError(default, null):Null<MongoWriteError>;

	/** What a write managed before it failed, or `null` for other commands. **/
	public var result(default, null):Null<MongoWriteResult>;

	/** The server's whole reply, for anything the fields above leave out. **/
	public var reply(default, null):Dynamic;

	public function new(operation:String, message:String, errorCode:Int = 0, codeName:String = "", ?errorLabels:Array<String>,
			?writeErrors:Array<MongoWriteError>, ?writeConcernError:MongoWriteError, ?result:MongoWriteResult, ?reply:Dynamic) {
		var summary:String = operation + " failed: " + message;

		if (errorCode != 0 || (codeName != null && codeName != "")) {
			summary += " (" + (codeName != null && codeName != "" ? codeName + ", " : "") + "code " + errorCode + ")";
		}

		// errorID is the server's code: the field every CrossByte error has for
		// one. Not a field of its own named code, which on php would redefine
		// the native Exception's.
		super(operation, message, summary, errorCode, errorCode, errorLabels);
		name = "MongoError";
		this.codeName = codeName == null ? "" : codeName;
		this.errorLabels = errorLabels == null ? [] : errorLabels;
		this.writeErrors = writeErrors == null ? [] : writeErrors;
		this.writeConcernError = writeConcernError;
		this.result = result;
		this.reply = reply;
	}

	/** Whether the server labelled the error `label`. **/
	public function hasErrorLabel(label:String):Bool {
		return errorLabels.indexOf(label) >= 0;
	}
}
