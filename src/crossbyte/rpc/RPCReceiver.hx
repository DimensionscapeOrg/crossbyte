package crossbyte.rpc;

/**
	What every receiver of answers has: how it is told that a call failed.

	A request on the compiled lane can be made two ways. `commands.join("lobby")`
	returns an `RPCResponse`, a `Future` made for the call. `commands.joinThen("lobby", receiver)`
	makes the same call and has the answer handed to `receiver` instead, typed,
	with nothing made for the call: no future, no closure, and for an answer
	that is a number (`haxe.Int64` among them, natively and on the jvm), a
	`Bool` or a `String`, no box. That is the way to call
	in a loop that runs every frame.

	The receiver is an interface for the type of the answer, so one object can
	receive the answers of every method that answers with that type:

	| answer | receiver | told with |
	|---|---|---|
	| `Int`, `Int8`, `UInt8`, `Int16`, `UInt16`, `UInt` | `RPCIntReceiver` | `onInt` |
	| `Float`, `Float32` | `RPCFloatReceiver` | `onFloat` |
	| `Bool` | `RPCBoolReceiver` | `onBool` |
	| `String` | `RPCStringReceiver` | `onString` |
	| `haxe.Int64` | `RPCInt64Receiver` | `onInt64` |
	| anything else, and `Null<T>` of anything | `RPCValueReceiver<T>` | `onValue` |

	An abstract over one of the first five is received as what it abstracts:
	an enum abstract over `Int` arrives through `onInt`.

	Each method is told the call's id, which the `...Then` method returned,
	so one receiver can tell its calls apart. Exactly one of the two
	methods is called for each call, once, on the thread that runs the
	session's connection. What a receiver throws is logged and goes no
	further.
**/
interface RPCReceiver {
	/**
		The call `call` will not be answered with a value, for `failure`. A
		call that cannot go at all (its connection has ended, or it is too
		large) is failed before its `...Then` method returns.
	**/
	function onFailure(call:Int, failure:RPCFailure):Void;
}
