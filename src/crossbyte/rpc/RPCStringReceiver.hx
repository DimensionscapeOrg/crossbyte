package crossbyte.rpc;

/**
	Receives the answers of calls whose answer is a `String`, or an abstract
	over one. See `RPCReceiver`.
**/
interface RPCStringReceiver extends RPCReceiver {
	/** The call `call` was answered with `value`, the string read from the answer. **/
	function onString(call:Int, value:String):Void;
}
