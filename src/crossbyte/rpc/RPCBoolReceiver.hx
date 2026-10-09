package crossbyte.rpc;

/** Receives the answers of calls whose answer is a `Bool`. See `RPCReceiver`. **/
interface RPCBoolReceiver extends RPCReceiver {
	/** The call `call` was answered with `value`. **/
	function onBool(call:Int, value:Bool):Void;
}
