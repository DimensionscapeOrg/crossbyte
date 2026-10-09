package crossbyte.rpc;

import haxe.Int64;

/**
	Receives the answers of calls whose answer is a `haxe.Int64`, or an
	abstract over one. Natively and on the jvm an `Int64` is a value of its
	own, and nothing is allocated to hand it over; elsewhere it is an
	object, made as the answer is read. See `RPCReceiver`.
**/
interface RPCInt64Receiver extends RPCReceiver {
	/** The call `call` was answered with `value`. **/
	function onInt64(call:Int, value:Int64):Void;
}
