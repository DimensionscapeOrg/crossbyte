package crossbyte.db.mongodb.bson;

/**
	BSON JavaScript code, with the scope it was stored with, if any.

	Kept so a document holding code reads and writes back unchanged; MongoDB
	itself has not run stored JavaScript since 4.4 removed server-side
	`eval`.
**/
final class BsonJavaScript {
	public var code(default, null):String;

	/** The variables stored with the code, or `null` for plain code. **/
	public var scope(default, null):Dynamic;

	public function new(code:String, ?scope:Dynamic) {
		this.code = code == null ? "" : code;
		this.scope = scope;
	}

	public function toString():String {
		return code;
	}
}
