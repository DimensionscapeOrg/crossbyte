package crossbyte.errors;

import crossbyte.errors.Error;

/** Signals that an operation violated a runtime or environment security rule. */
class SecurityError extends Error {
	public function new(message:String = "", id:Int = 0) {
		super(message, id);
		name = "SecurityError";
	}
}
