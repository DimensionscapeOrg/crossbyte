package crossbyte.rpc;

/**
	Receives the answers of calls whose answer is of type `T`: an array, a
	structure, an enum, `haxe.io.Bytes`, or a `Null<T>` of any type. What it
	is given is the answer read from the frame, and its own to keep. See
	`RPCReceiver`.

	A number, a `Bool` or a `String` has a receiver of its own, which
	takes it unboxed.
**/
interface RPCValueReceiver<T> extends RPCReceiver {
	/** The call `call` was answered with `value`. **/
	function onValue(call:Int, value:T):Void;
}
