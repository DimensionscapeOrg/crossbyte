package crossbyte.rpc._internal;

import crossbyte.rpc.RPCError;

/**
	The cause of a call the other side's session refused itself (no such
	method, too many calls waiting, its handler out of time, and the rest of
	`RPCWire.REFUSED_*`): an `RPCError` with its message, carrying the code,
	so `RPCResponse.failure` can say which, and a handler answering with that
	call's response passes the refusal on as it came, a busy peer as busy.

	Made only for those, and for a handler that refuses with one of their
	codes (`RPCError.refusal`): a handler's own refusal is a plain `RPCError`,
	as it always was, and nothing else an `RPCError` is made for is any
	larger.
**/
@:noCompletion
class RPCRefusal extends RPCError {
	/** What refused the call: one of `RPCWire.REFUSED_*`. **/
	public final code:Int;

	public function new(message:String, code:Int) {
		super(message);
		this.code = code;
	}
}
