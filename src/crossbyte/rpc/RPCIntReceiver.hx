package crossbyte.rpc;

/**
	Receives the answers of calls whose answer is an `Int`, or a smaller
	integer (`Int8`, `UInt8`, `Int16`, `UInt16`), a `UInt`, or an abstract
	over one of them. See `RPCReceiver`.
**/
interface RPCIntReceiver extends RPCReceiver {
	/** The call `call` was answered with `value`. **/
	function onInt(call:Int, value:Int):Void;
}
