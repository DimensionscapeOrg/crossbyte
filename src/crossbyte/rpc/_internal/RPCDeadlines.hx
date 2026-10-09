package crossbyte.rpc._internal;

import crossbyte._internal.system.timer.TimerHandle;
import crossbyte.rpc.RPCResponse;
import haxe.ds.Vector;

/**
	The deadlines of a session's calls, whatever each one is (the session's
	`callTimeout`, one given with `withTimeout` or `RPCResponse.timeout`), in
	a binary heap ordered by when each falls due, and one timer for all of
	them, set for the first: rather than a timer for each call, a closure
	and a timer node a call, and a slot of the 524,288 timers one runtime can
	hold at once.

	A call in the heap has its place in its `RPCResponse.__deadline`, below
	`TimerHandle.INVALID` (see `deadlineOf`), so it gains no field for it, and
	leaves it in a few steps when it is answered: calls under one timeout,
	answered in the order they were made, add at the end and leave from the
	top. Nothing is allocated once the heap has grown to the calls in flight.

	The timer, when it fires, fails the calls that are due, at the time a
	timer of their own would have fired, and is set for the next. A call
	that falls due before the time it is set for sets it again; one answered
	leaves it set, to find nothing due.
**/
@:noCompletion
@:access(crossbyte.rpc.RPCResponse)
final class RPCDeadlines {
	static inline final INITIAL:Int = 16;

	/** The most places an empty heap keeps; past it, it starts again from `INITIAL`. **/
	static inline final KEEP:Int = 65536;

	/** How much past its time the scheduler still counts a timer due: theirs, so these fall due with it. **/
	static inline final DUE_EPSILON:Float = 1e-9;

	var __calls:Vector<RPCResponse<Dynamic>>;
	var __due:Vector<Float>;
	var __milliseconds:Vector<Int>;
	// The order each was added in: calls due at the same time fall due in
	// the order they were made, as their own timers would have fired.
	var __order:Vector<Int>;
	var __added:Int = 0;
	var __count:Int = 0;
	var __timer:Int = TimerHandle.INVALID;
	// When the timer is set to fire: the first deadline when it was set.
	var __timerDue:Float = 0.0;
	var __firing:Bool = false;
	final __fire:Void->Void;

	public function new() {
		__allocate(INITIAL);
		__fire = __fired;
	}

	/** The `RPCResponse.__deadline` of a call at `place` in the heap. **/
	public static inline function deadlineOf(place:Int):Int {
		return -2 - place;
	}

	/** Whether an `RPCResponse.__deadline` is a place in a heap, rather than a timer's handle or none. **/
	public static inline function isPlace(deadline:Int):Bool {
		return deadline < -1;
	}

	/** How many calls wait here. **/
	public var length(get, never):Int;

	inline function get_length():Int {
		return __count;
	}

	/** Gives `response` the deadline `milliseconds` after `now`, the scheduler's time. **/
	public function add(response:RPCResponse<Dynamic>, milliseconds:Int, now:Float):Void {
		final due:Float = now + milliseconds / 1000;
		if (__count == __calls.length) {
			__grow();
		}
		final at:Int = __count++;
		__calls[at] = response;
		__due[at] = due;
		__milliseconds[at] = milliseconds;
		__order[at] = __added;
		__added = (__added + 1) | 0;
		response.__deadline = deadlineOf(at);
		__up(at);
		if (!__firing && (__timer == TimerHandle.INVALID || due < __timerDue)) {
			__arm(due, now);
		}
	}

	/**
		`response`, whose `RPCResponse.__deadline` was `deadline`, has left its
		place: answered, failed, or given another deadline.
	**/
	public function leave(response:RPCResponse<Dynamic>, deadline:Int):Void {
		final at:Int = -2 - deadline;
		if (at >= __count || __calls[at] != response) {
			// Not here: queued by another session, its commands bound to this
			// one since.
			return;
		}
		__removeAt(at);
		// The timer is left set: it finds nothing due when it fires, and a
		// caller making one call at a time would otherwise clear a timer and
		// set another for every call.
		if (__count == 0) {
			__shrink();
		}
	}

	/** Lets every call go, as they are failed together: the connection ended, or the session stopped. **/
	public function clear():Void {
		for (i in 0...__count) {
			final response = __calls[i];
			if (response.__deadline == deadlineOf(i)) {
				response.__deadline = TimerHandle.INVALID;
			}
			__calls[i] = null;
		}
		__count = 0;
		__disarm();
		__shrink();
	}

	/** The timer: every call that is due fails, and the timer is set for the next. **/
	function __fired():Void {
		__timer = TimerHandle.INVALID;
		__firing = true;
		final now:Float = Timer.getTime();
		var failed:Bool = false;
		var failure:Dynamic = null;
		// Read again each time round: failing a call runs its handlers,
		// which may make calls, answer them, or stop the session.
		while (__count > 0 && __due[0] <= now + DUE_EPSILON) {
			final response = __calls[0];
			final milliseconds:Int = __milliseconds[0];
			__removeAt(0);
			response.__deadline = TimerHandle.INVALID;
			try {
				response.__expire(milliseconds);
			} catch (error:Dynamic) {
				// The rest are still failed, and the timer set again, before
				// the scheduler hears of it.
				if (!failed) {
					failed = true;
					failure = error;
				}
			}
		}
		__firing = false;
		if (__count > 0 && __timer == TimerHandle.INVALID) {
			__arm(__due[0], Timer.getTime());
		} else if (__count == 0) {
			__shrink();
		}
		if (failed) {
			throw failure;
		}
	}

	inline function __arm(due:Float, now:Float):Void {
		if (__timer != TimerHandle.INVALID) {
			Timer.clear(__timer);
		}
		__timerDue = due;
		__timer = Timer.setTimeout(due - now, __fire);
	}

	inline function __disarm():Void {
		if (__timer != TimerHandle.INVALID) {
			Timer.clear(__timer);
			__timer = TimerHandle.INVALID;
		}
	}

	/** Takes the call at `at` out, the last put in its place and moved to where it belongs. **/
	function __removeAt(at:Int):Void {
		final last:Int = --__count;
		if (at != last) {
			__move(last, at);
			__calls[last] = null;
			if (at > 0 && __before(at, (at - 1) >> 1)) {
				__up(at);
			} else {
				__down(at);
			}
		} else {
			__calls[last] = null;
		}
	}

	/** Whether the call at `a` falls due before the one at `b`: sooner, or as soon and added first. **/
	inline function __before(a:Int, b:Int):Bool {
		return __due[a] < __due[b] || (__due[a] == __due[b] && ((__order[a] - __order[b]) | 0) < 0);
	}

	inline function __sooner(due:Float, order:Int, at:Int):Bool {
		return due < __due[at] || (due == __due[at] && ((order - __order[at]) | 0) < 0);
	}

	function __up(at:Int):Void {
		final response = __calls[at];
		final due:Float = __due[at];
		final milliseconds:Int = __milliseconds[at];
		final order:Int = __order[at];
		while (at > 0) {
			final parent:Int = (at - 1) >> 1;
			if (!__sooner(due, order, parent)) {
				break;
			}
			__move(parent, at);
			at = parent;
		}
		__put(at, response, due, milliseconds, order);
	}

	function __down(at:Int):Void {
		final response = __calls[at];
		final due:Float = __due[at];
		final milliseconds:Int = __milliseconds[at];
		final order:Int = __order[at];
		final half:Int = __count >> 1;
		while (at < half) {
			var child:Int = 2 * at + 1;
			final right:Int = child + 1;
			if (right < __count && __before(right, child)) {
				child = right;
			}
			if (__sooner(due, order, child)) {
				break;
			}
			__move(child, at);
			at = child;
		}
		__put(at, response, due, milliseconds, order);
	}

	inline function __move(from:Int, to:Int):Void {
		__put(to, __calls[from], __due[from], __milliseconds[from], __order[from]);
	}

	inline function __put(at:Int, response:RPCResponse<Dynamic>, due:Float, milliseconds:Int, order:Int):Void {
		__calls[at] = response;
		__due[at] = due;
		__milliseconds[at] = milliseconds;
		__order[at] = order;
		response.__deadline = deadlineOf(at);
	}

	function __grow():Void {
		final calls = __calls;
		final due = __due;
		final milliseconds = __milliseconds;
		final order = __order;
		__allocate(calls.length * 2);
		Vector.blit(calls, 0, __calls, 0, __count);
		Vector.blit(due, 0, __due, 0, __count);
		Vector.blit(milliseconds, 0, __milliseconds, 0, __count);
		Vector.blit(order, 0, __order, 0, __count);
	}

	/** An empty heap that grew past `KEEP` starts again small. **/
	inline function __shrink():Void {
		if (__count == 0 && __calls.length > KEEP) {
			__allocate(INITIAL);
		}
	}

	function __allocate(capacity:Int):Void {
		__calls = new Vector(capacity);
		__due = new Vector(capacity);
		__milliseconds = new Vector(capacity);
		__order = new Vector(capacity);
	}
}
