package crossbyte.errors;

import crossbyte.errors.Error;

/**
 * ...
 * @author Christopher Speciale
 */
class SecurityError extends Error {
	public function new(message:String = "", id:Int = 0) {
		super(message, id);
	}
}
