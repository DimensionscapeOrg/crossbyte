package crossbyte.rpc;

import crossbyte.Future;
import crossbyte._internal.system.timer.TimerHandle;
import crossbyte.rpc._internal.RPCDeadlines;
import crossbyte.rpc._internal.RPCReceiverCall;

@:allow(crossbyte.rpc.RPCCommands)
@:allow(crossbyte.rpc.RPCSession)
@:allow(crossbyte.rpc._internal.RPCReceiverCall)
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc.RPCSession)
/**
 * The eventual result of a request/response RPC invocation.
 *
 * Waiting for a value is `crossbyte.Future`'s: `then`, the event pair,
 * `completed`, `succeeded`, `result`, `error`. What is here is the part that
 * is genuinely about RPC (which request this was, and which operation) and
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
	public var requestId(default, null):Int;

	/** Operation code associated with the request. */
	public var op(default, null):Int;

	/**
		Why the call failed, typed as a receiver is told it: `TimedOut`,
		`Cancelled`, `Stopped`, `Disconnected(reason)`, `Unsent` or
		`Unreadable`; and for a call the other side refused, what refused it:
		`Refused(message)` for its handler's own `RPCError`, `UnknownMethod`,
		`UnreadableArguments`, `Busy`, `NoHandler`, `HandlerTimedOut` or
		`HandlerFailed`. `null` while it waits and once it has succeeded.

		Worked out from `error` and `cause` as it is read, so a call that never
		asks pays nothing for it.

		```haxe
		final asked = commands.join("lobby");
		asked.catchError(_ -> switch (asked.failure) {
			case TimedOut: trace("no answer in time");
			case Disconnected(reason): trace('gone: $reason');
			case other: trace('failed: $other');
		});
		```
	**/
	public var failure(get, never):Null<RPCFailure>;

	// Where the call waits for its answer, so a deadline can take it out:
	// the commands that made it, or the session, for a runtime call. Set by
	// whichever made it.
	@:noCompletion private var __commands:Null<RPCCommands> = null;
	@:noCompletion private var __session:Null<RPCSession<Dynamic, Dynamic>> = null;
	// The deadline: TimerHandle.INVALID while there is none; the handle of a
	// timer of its own, on the thread the call was made on; or, below
	// INVALID, its place in its session's queue of the deadlines its
	// `callTimeout` gives (see RPCDeadlines).
	@:noCompletion private var __deadline:Int = TimerHandle.INVALID;
	// Whether this is one of the calls its commands keep for calls made with
	// a receiver (RPCReceiverCall), never handed to anyone. Beside the
	// deadline, where natively it takes no room of its own.
	@:noCompletion private var __pooled:Bool = false;
	// Whether the deadline it waits under went with it, so its handler's
	// side ends the call itself when it passes, and needs no cancel.
	@:noCompletion private var __deadlineSent:Bool = false;

	// The responder bound now, which `respond` replaces, under the future's
	// lock; ANSWERED once the outcome has been handed to one, after which
	// another bound is told at once. One field, which a call with no
	// responder never touches.
	@:noCompletion private var __responder:Null<Responder<T>> = null;
	@:noCompletion private static final ANSWERED:Responder<Dynamic> = new Responder<Dynamic>();

	@:noCompletion private function get_failure():Null<RPCFailure> {
		return completed && !succeeded ? RPCReceiverCall.failureOf(error, cause) : null;
	}

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
		before (the one passed to the constructor included): only the last
		one bound hears it. One bound after the call has been answered is told
		at once, as `then` tells a handler added late. `null` changes nothing.

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
			// whichever responder is bound when the outcome comes, at once,
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
		of any deadline it had (the session's `callTimeout`, or one set
		here before). `0` leaves it none, to wait for as long as the connection
		lasts.

		Past it, the call fails with an `RPCTimeoutError` as its `cause`, and
		an answer arriving after that is dropped. The connection is left as
		it was: a slow answer is not a broken connection.

		A call with no deadline costs nothing for having none, and one given a
		deadline here waits with its session's other calls under one timer,
		allocating nothing. A call already complete is left as it is.

		Given here, after the call has gone, the deadline stays on this side:
		when it passes, the peer is told the call is cancelled. One given
		before the call goes (`RPCSession.callTimeout`, or the commands'
		`withTimeout`) travels with it, so its handler can read it; see
		`RPCCall`.

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
		// Another deadline than the one that went with the call, if one did.
		__deadlineSent = false;
		if (milliseconds <= 0 || completed) {
			return;
		}
		final session:Null<RPCSession<Dynamic, Dynamic>> = __commands != null ? __commands.__session : __session;
		if (session != null) {
			session.__queueDeadline(this, milliseconds);
			return;
		}
		__deadline = Timer.setTimeout(milliseconds / 1000, () -> __expire(milliseconds));
	}

	@:noCompletion private inline function __disarm():Void {
		final deadline:Int = __deadline;
		if (deadline != TimerHandle.INVALID) {
			__deadline = TimerHandle.INVALID;
			if (RPCDeadlines.isPlace(deadline)) {
				__leaveQueue(deadline);
			} else {
				Timer.clear(deadline);
			}
		}
	}

	/** Leaves its place in its session's queue of deadlines. **/
	@:noCompletion private function __leaveQueue(deadline:Int):Void {
		final session:Null<RPCSession<Dynamic, Dynamic>> = __commands != null ? __commands.__session : __session;
		if (session != null && session.__deadlines != null) {
			session.__deadlines.leave(this, deadline);
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
		if (!__deadlineSent) {
			__cancelOnPeer();
		}
	}

	/** Tells the peer this call is no longer waited for, if it can be told. **/
	@:noCompletion private function __cancelOnPeer():Void {
		if (__commands != null) {
			final session = __commands.__session;
			if (session != null) {
				session.__sendCancel(op, requestId, false);
			}
		} else if (__session != null) {
			__session.__sendCancel(op, requestId, true);
		}
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
