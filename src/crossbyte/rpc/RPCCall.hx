package crossbyte.rpc;

import crossbyte.Future;
import crossbyte.net.Reason;
import crossbyte.utils.Logger;

/**
	A call this side is answering, as its handler sees it: by when its caller
	wants the answer, and whether the caller still does.

	A handler's method reads it as `RPCHandler.currentCall` while it runs,
	and a runtime handler as `RPCSession.currentCall`. It is made the first
	time it is read in a call, so a call whose handler never reads it costs nothing
	for it. A method that answers later, with a `Future`, keeps it, to stop
	work its caller no longer wants:

	```haxe
	import crossbyte.Completer;
	import crossbyte.Future;

	class SearchHandler extends RPCHandler {
		public function new() {}

		@:rpc public function search(query:String):Future<Int> {
			final done = new Completer<Int>();
			final job = haxe.Timer.delay(() -> done.complete(42), 5000);
			// Stop working once the caller has stopped waiting.
			currentCall.onCancel = () -> job.stop();
			return done.future;
		}
	}
	```

	A call that is answered later ends before its answer when:

	- its caller cancels it (`RPCSession.cancelCall`), or the caller's
	  deadline passes: `reason` is `Cancelled` or `TimedOut`, and nothing is
	  sent back, since the caller has stopped waiting;
	- the session's `RPCSession.handlerTimeout` passes: `TimedOut`, and the
	  caller is answered `RPCError.TIMEOUT_MESSAGE`;
	- its connection ends: `Disconnected(reason)`.

	Then `cancelled` is `true`, `onCancel` is called once, and the future's
	answer, when it comes, goes nowhere. For the first two, `afterCall` is told
	then, with an `RPCError` (`RPCError.CANCELLED_MESSAGE`) or an
	`RPCTimeoutError`, and the call stops counting against `maxCallsWaiting`.
	A call answered at once has answered before anything else is read, so
	nothing can end it first. A call answered later whose handler never read
	this, with no deadline (its caller's, or `handlerTimeout`), is not
	tracked at all: it costs nothing more than before, and a cancel for it
	finds nothing to stop.

	A caller's deadline and its cancellations reach this side from a peer of
	1.0 or later, once the peers' hellos have been exchanged; a deadline given
	with `RPCResponse.timeout` after the call has gone arrives as a
	cancellation when it passes.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.Future)
final class RPCCall {
	/** The op of the call: the hash of its method's signature, or a runtime handler's number. **/
	public var op(default, null):Int;

	/** The call's request id, `0` for a one-way call. **/
	public var requestId(default, null):Int;

	/**
		When the caller stops waiting for the answer, on `crossbyte.Timer.getTime`'s
		clock, in seconds; `0` when it gave no deadline. Counted from when the
		call arrived, so it is a little later than the caller's own by the time
		the call took to arrive.
	**/
	public var deadline(default, null):Float = 0.0;

	/** Milliseconds left until `deadline`, `0` once it has passed, and `-1` with no deadline. **/
	public var timeLeft(get, never):Int;

	/** Whether the call has ended before its answer; see `reason`. **/
	public var cancelled(default, null):Bool = false;

	/** Why it ended, once `cancelled`: `Cancelled`, `TimedOut` or `Disconnected`. **/
	public var reason(default, null):Null<RPCFailure> = null;

	/**
		Called once, on the session's thread, when the call ends before its
		answer, if set. What it throws is logged, and changes nothing else.
	**/
	public var onCancel:Null<Void->Void> = null;

	@:noCompletion private final __session:RPCSession<Dynamic, Dynamic>;
	@:noCompletion private final __runtime:Bool;
	// While it waits for its future: what settles it, how, and its place in
	// its session's list of calls waiting and heap of their deadlines.
	@:noCompletion private var __future:Null<Future<Dynamic>> = null;
	@:noCompletion private var __settle:Null<(Future<Dynamic>, Bool) -> Void> = null;
	@:noCompletion private var __settled:Bool = false;
	@:noCompletion private var __listed:Bool = false;
	@:noCompletion private var __previous:Null<RPCCall> = null;
	@:noCompletion private var __next:Null<RPCCall> = null;
	@:noCompletion private var __place:Int = -1;
	@:noCompletion private var __due:Float = 0.0;
	@:noCompletion private var __order:Int = 0;
	// Whether the deadline in the heap is the caller's, rather than the
	// session's handlerTimeout.
	@:noCompletion private var __dueByCaller:Bool = false;

	@:noCompletion private function new(session:RPCSession<Dynamic, Dynamic>, op:Int, requestId:Int, timeout:Int, runtime:Bool) {
		__session = session;
		__runtime = runtime;
		this.op = op;
		this.requestId = requestId;
		if (timeout > 0) {
			deadline = Timer.getTime() + timeout / 1000;
		}
	}

	private function get_timeLeft():Int {
		if (deadline <= 0) {
			return -1;
		}
		// Less a hair, so that 400 ms left, read at once, is not 401 for the
		// sum's rounding.
		final left:Float = (deadline - Timer.getTime()) * 1000 - 1e-6;
		return left <= 0 ? 0 : Math.ceil(left);
	}

	/**
		Waits for `future`, which `settle` answers with once it completes, or
		once its deadline (the caller's or `handlerTimeout`, whichever is
		sooner) passes.
	**/
	@:noCompletion private function __wait(future:Future<Dynamic>, settle:(Future<Dynamic>, Bool) -> Void, handlerTimeout:Int):Void {
		__future = future;
		__settle = settle;
		__session.__listWaiting(this);
		final now:Float = Timer.getTime();
		var due:Float = handlerTimeout > 0 ? now + handlerTimeout / 1000 : 0.0;
		if (deadline > 0 && (due == 0 || deadline <= due)) {
			due = deadline;
			__dueByCaller = true;
		}
		if (due > 0) {
			__session.__callDeadlines().add(this, due, now);
		}
	}

	/** Its future has completed: answered with it, unless it ended first. **/
	@:noCompletion private function __finish():Void {
		if (!__leave()) {
			return;
		}
		__settle(__future, false);
	}

	/** Its deadline passed: the caller's, which is not answered, or `handlerTimeout`, which is. **/
	@:noCompletion private function __expire():Void {
		final byCaller:Bool = __dueByCaller;
		if (!__leave()) {
			return;
		}
		__end(TimedOut);
		__settle(RPCSession.__handlerTimedOut(), byCaller);
	}

	/** The caller cancelled it. **/
	@:noCompletion private function __cancelledByCaller():Void {
		if (!__leave()) {
			return;
		}
		__end(Cancelled);
		final cancelled = new Future<Dynamic>();
		cancelled.__failureObserved = true;
		cancelled.__fail(RPCError.CANCELLED_MESSAGE, new RPCError(RPCError.CANCELLED_MESSAGE));
		__settle(cancelled, true);
	}

	/**
		Its connection ended: told so, and no longer found by a cancel. Its
		future still settles it, and its deadline still frees its place, as
		they did before anything said so.
	**/
	@:noCompletion private function __disconnected(why:Reason):Void {
		if (__listed) {
			__session.__unlistWaiting(this);
		}
		__end(Disconnected(why));
	}

	/** No longer waiting, and its place among the calls waiting given up; `false` if it was settled already. **/
	@:noCompletion private function __leave():Bool {
		if (__settled) {
			return false;
		}
		__settled = true;
		if (__listed) {
			__session.__unlistWaiting(this);
		}
		if (__place >= 0) {
			__session.__callDeadlines().remove(this);
		}
		__session.__callsWaiting--;
		return true;
	}

	@:noCompletion private function __end(why:RPCFailure):Void {
		if (cancelled) {
			return;
		}
		cancelled = true;
		reason = why;
		final told:Null<Void->Void> = onCancel;
		if (told != null) {
			try {
				told();
			} catch (error:Dynamic) {
				Logger.error("RPCCall.onCancel threw: " + Std.string(error));
			}
		}
	}
}
