package crossbyte.errors;

/**
	The IllegalOperationError exception is thrown when a method is not
	implemented or the implementation doesn't cover the current usage.

	It marks a call that is legal in general but not here -- wrong state,
	wrong thread, or a target that cannot do it. What CrossByte throws it for:

	* A runtime reached from a thread it is not attached to, or
	  `CrossByte.make()` called before a primordial instance exists
	* The POLL main loop selected on a JavaScript target, which has no
	  pollable socket set
	* `acquire()` on a closed `ConnectionPool`, or one whose connections are
	  all in use past the timeout
	* A file attribute or path expansion asked for in a browser, which has
	  neither a shell nor a process environment
**/
class IllegalOperationError extends Error {
	/**
		Creates a new IllegalOperationError object.

		@param message A string associated with the error object.
	**/
	public function new(message:String = "") {
		super(message, 0);

		name = "IllegalOperationError";
	}
}
