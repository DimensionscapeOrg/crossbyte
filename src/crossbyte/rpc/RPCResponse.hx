package crossbyte.rpc;

import crossbyte.Future;
import crossbyte._internal.system.timer.TimerHandle;

@:allow(crossbyte.rpc.RPCCommands)
@:allow(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc.RPCSession)
/**
 * The eventual result of a request/response RPC invocation.
 *
 * Everything about waiting for a value now lives in `crossbyte.Future`, which
 * this was before it was promoted: `then`, the event pair, `completed`,
 * `succeeded`, `result`, `error`. What is left here is the part that is
 * genuinely about RPC -- which request this was, and which operation -- and
 * how long it may wait.
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

	// Where the call waits for its answer, so a deadline can take it out:
	// the commands that made it, or the session, for a runtime call. Set by
	// whichever made it.
	@:noCompletion private var __commands:Null<RPCCommands> = null;
	@:noCompletion private var __session:Null<RPCSession<Dynamic, Dynamic>> = null;
	// The deadline's timer, on the thread the call was made on;
	// TimerHandle.INVALID while there is none.
	@:noCompletion private var __deadline:Int = TimerHandle.INVALID;

	// The responder bound now, which `respond` replaces, under the future's
	// lock; ANSWERED once the outcome has been handed to one, after which
	// another bound is told at once. One field, which a call with no
	// responder never touches.
	@:noCompletion private var __responder:Null<Responder<T>> = null;
	@:noCompletion private static final ANSWERED:Responder<Dynamic> = new Responder<Dynamic>();

	public function new(requestId:Int, op:Int, ?responder:Responder<T>) {
		super();

		this.requestId = requestId;
		this.op = op;

		if (responder != null) {
			respond(responder);
		}
	}

	/**
		Binds the responder that receives the outcome, replacing any bound
		before -- the one passed to the constructor included: only the last
		one bound hears it. One bound after the call has been answered is told
		at once, as `then` tells a handler added late. `null` changes nothing.

		It added one each time, so a responder replaced was told as well.
		`then` is the way to add: every handler added with it runs, beside
		whichever responder is bound.
	**/
	public function respond(responder:Responder<T>):RPCResponse<T> {
		if (responder == null) {
			return this;
		}

		__acquire();
		final previous:Null<Responder<T>> = __responder;
		final answered:Bool = previous == cast ANSWERED;
		if (!answered) {
			__responder = responder;
		}
		__release();

		if (previous == null) {
			// One pair of handlers for the life of the call, which tells
			// whichever responder is bound when the outcome comes -- at once,
			// should it have come already.
			then(__toResponder, __errorToResponder);
		} else if (answered) {
			// The responder bound before has been told; this one is told now.
			then(value -> responder.result(value), message -> responder.error(message));
		}
		return this;
	}

	/** The outcome, to the responder bound now. **/
	@:noCompletion private function __toResponder(value:T):Void {
		final responder:Null<Responder<T>> = __takeResponder();
		if (responder != null) {
			responder.result(value);
		}
	}

	@:noCompletion private function __errorToResponder(message:String):Void {
		final responder:Null<Responder<T>> = __takeResponder();
		if (responder != null) {
			responder.error(message);
		}
	}

	/**
		The responder bound now, read as the outcome is handed to it: from
		then on `respond` tells a responder itself, so none is told twice and
		none is missed whichever thread binds it.
	**/
	@:noCompletion private function __takeResponder():Null<Responder<T>> {
		__acquire();
		final responder:Null<Responder<T>> = __responder;
		__responder = cast ANSWERED;
		__release();
		return responder;
	}

	/**
		Gives the call until `milliseconds` from now to be answered, in place
		of any deadline it had -- the session's `callTimeout`, or one set
		here before. `0` leaves it none, to wait for as long as the connection
		lasts.

		Past it, the call fails with an `RPCTimeoutError` as its `cause`, and
		an answer arriving after that is dropped. The connection is left as
		it was: a slow answer is not a broken connection.

		A call with no deadline costs nothing for having none. One with a
		deadline holds a timer, on the thread the call was made on, until it
		is answered. A call already complete is left as it is.

		```haxe
		commands.join("lobby").timeout(2000).then(count -> trace(count), message -> trace(message));
		```
	**/
	public function timeout(milliseconds:Int):RPCResponse<T> {
		__arm(milliseconds);
		return this;
	}

	/** Sets this call's deadline to `milliseconds` from now, replacing any; `0` clears it. **/
	@:noCompletion private function __arm(milliseconds:Int):Void {
		__disarm();
		if (milliseconds <= 0 || completed) {
			return;
		}
		__deadline = Timer.setTimeout(milliseconds / 1000, () -> __expire(milliseconds));
	}

	@:noCompletion private inline function __disarm():Void {
		if (__deadline != TimerHandle.INVALID) {
			Timer.clear(__deadline);
			__deadline = TimerHandle.INVALID;
		}
	}

	/** The deadline passed with no answer: the call stops waiting, and fails. **/
	@:noCompletion private function __expire(milliseconds:Int):Void {
		__deadline = TimerHandle.INVALID;
		if (completed) {
			return;
		}
		// Taken out of where it waits first, so an answer arriving later
		// finds nothing to complete.
		if (__commands != null) {
			__commands.__takeResponse(requestId);
		} else if (__session != null) {
			__session.__takeRuntimeResponse(requestId);
		}
		final message:String = "RPC call timed out after " + milliseconds + " ms";
		__fail(message, new RPCTimeoutError(message));
	}

	override function __resolve(value:T):Bool {
		__disarm();
		return super.__resolve(value);
	}

	override function __fail(message:String, ?cause:Dynamic):Bool {
		__disarm();
		return super.__fail(message, cause);
	}
}

typedef RPCResonse<T> = RPCResponse<T>;
