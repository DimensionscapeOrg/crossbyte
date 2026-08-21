package crossbyte.rpc;

import crossbyte.Future;

@:allow(crossbyte.rpc.RPCCommands)
@:allow(crossbyte.rpc.RPCSession)
/**
 * The eventual result of a request/response RPC invocation.
 *
 * Everything about waiting for a value now lives in `crossbyte.Future`, which
 * this was before it was promoted: `then`, the event pair, `completed`,
 * `succeeded`, `result`, `error`. What is left here is the part that is
 * genuinely about RPC -- which request this was, and which operation.
 */
class RPCResponse<T> extends Future<T> {
	/**
		Dispatched when the response resolves successfully.

		The same event `Future` dispatches, kept under this name because that
		is what RPC callers already listen for.
	**/
	public static inline final RESULT:String = Future.RESULT;

	/** Dispatched when the response resolves with an error. */
	public static inline final ERROR:String = Future.ERROR;

	/** Request identifier assigned by the originating `RPCCommands` instance. */
	public final requestId:Int;

	/** Operation code associated with the request. */
	public final op:Int;

	public function new(requestId:Int, op:Int, ?responder:Responder<T>) {
		super();

		this.requestId = requestId;
		this.op = op;

		if (responder != null) {
			respond(responder);
		}
	}

	/** Binds or replaces the responder that should receive the final result. */
	public function respond(responder:Responder<T>):RPCResponse<T> {
		if (responder == null) {
			return this;
		}

		then(value -> responder.result(value), message -> responder.error(message));
		return this;
	}
}

typedef RPCResonse<T> = RPCResponse<T>;
