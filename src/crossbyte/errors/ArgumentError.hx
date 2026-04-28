package crossbyte.errors;

import crossbyte.errors.Error;

/** Signals that a caller supplied an invalid argument or malformed value. */
class ArgumentError extends Error {
	public function new(message:String = "", id:Int = 0) {
		super(message, id);
		name = "ArgumentError";
	}
}
