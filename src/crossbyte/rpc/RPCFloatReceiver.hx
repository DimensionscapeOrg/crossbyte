package crossbyte.rpc;

/**
	Receives the answers of calls whose answer is a `Float` or a `Float32`,
	or an abstract over one. See `RPCReceiver`.
**/
interface RPCFloatReceiver extends RPCReceiver {
	/** The call `call` was answered with `value`. **/
	function onFloat(call:Int, value:Float):Void;
}
