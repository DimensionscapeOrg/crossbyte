package crossbyte.errors;

import crossbyte.errors.Error;

/** Signals that a numeric value falls outside the accepted range. */
class RangeError extends Error {
	public function new(message:String = "", id:Int = 0) {
		super(message, id);
		name = "RangeError";
	}
}
