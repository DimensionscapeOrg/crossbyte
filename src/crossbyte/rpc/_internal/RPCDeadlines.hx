package crossbyte.rpc._internal;

import crossbyte._internal.system.timer.TimerHandle;
import crossbyte.rpc.RPCResponse;
import haxe.ds.Vector;

/**
	The deadlines of a session's calls made under its `callTimeout`, in the
	order the calls were made, which, with one timeout for all of them, is
	the order they fall due, and one timer for them all, set for the
	first. Each call armed a timer of its own: a closure and a timer node a
	call, a heap kept in order, and a slot of the 524,288 timers one runtime
	can hold at once.

	A call waiting here has its place in its `RPCResponse.__deadline`, below
	`TimerHandle.INVALID` (see `deadlineOf`), so it gains no field for it.
	One answered, failed or given a deadline of its own leaves its place
	empty at once, letting go of the call; and the empty places at the front
	go with it, so calls answered in the order they were made, as a peer
	answers them, keep the queue as long as the calls in flight. Empty
	places behind a call still waiting are closed up when the queue would
	otherwise grow.

	The timer, when it fires, fails the calls that are due, at the time a
	timer of their own would have fired, and is set for the next one. A
	call whose deadline would fall before the last one queued,
	`callTimeout` lowered between calls, is not queued, and arms its own.
**/
@:noCompletion
@:access(crossbyte.rpc.RPCResponse)
final class RPCDeadlines {
	/** Places run modulo this: a power of two, past any length the queue reaches. **/
	static inline final PLACES:Int = 0x40000000;

	static inline final INITIAL:Int = 16;

	/** The most places an empty queue keeps; past it, it starts again from `INITIAL`. **/
	static inline final KEEP:Int = 65536;

	/** How much past its time the scheduler still counts a timer due: theirs, so these fall due with it. **/
	static inline final DUE_EPSILON:Float = 1e-9;

	var __calls:Vector<RPCResponse<Dynamic>>;
	var __due:Vector<Float>;
	var __milliseconds:Vector<Int>;
	// The place of the first call queued; the queue runs `__count` places
	// from it, `__live` of them holding a call.
	var __first:Int = 0;
	var __count:Int = 0;
	var __live:Int = 0;
	var __timer:Int = TimerHandle.INVALID;
	var __firing:Bool = false;
	final __fire:Void->Void;

	public function new() {
		__allocate(INITIAL);
		__fire = __fired;
	}

	/** The `RPCResponse.__deadline` of a call queued at `place`. **/
	public static inline function deadlineOf(place:Int):Int {
		return -2 - place;
	}

	/** Whether an `RPCResponse.__deadline` is a place in a queue, rather than a timer's handle or none. **/
	public static inline function isPlace(deadline:Int):Bool {
		return deadline < -1;
	}

	/**
		Queues `response`'s deadline, `milliseconds` after `now`, the
		scheduler's time. `false`, and nothing queued, when it would fall
		before the last one queued.
	**/
	public function add(response:RPCResponse<Dynamic>, milliseconds:Int, now:Float):Bool {
		final due:Float = now + milliseconds / 1000;
		if (__count > 0 && due < __due[(__first + __count - 1) & (__calls.length - 1)]) {
			return false;
		}
		if (__count == __calls.length) {
			// Closed up, if at least half are empty places; else twice the size.
			__rebuild(__live * 2 <= __calls.length ? __calls.length : __calls.length * 2);
		}
		final place:Int = (__first + __count) & (PLACES - 1);
		final at:Int = place & (__calls.length - 1);
		__calls[at] = response;
		__due[at] = due;
		__milliseconds[at] = milliseconds;
		__count++;
		__live++;
		response.__deadline = deadlineOf(place);
		if (__timer == TimerHandle.INVALID && !__firing) {
			__timer = Timer.setTimeout(due - now, __fire);
		}
		return true;
	}

	/**
		`response`, whose `RPCResponse.__deadline` was `deadline`, has left its
		place: answered, failed, or given a deadline of its own.
	**/
	public function leave(response:RPCResponse<Dynamic>, deadline:Int):Void {
		final at:Int = (-2 - deadline) & (__calls.length - 1);
		if (__calls[at] != response) {
			// Not here: queued by another session, its commands bound to this
			// one since.
			return;
		}
		__calls[at] = null;
		__live--;
		if (at == (__first & (__calls.length - 1))) {
			__dropEmpty();
		}
	}

	/** Lets every call go, as they are failed together: the connection ended, or the session stopped. **/
	public function clear():Void {
		while (__count > 0) {
			final at:Int = __first & (__calls.length - 1);
			final response = __calls[at];
			if (response != null) {
				if (response.__deadline == deadlineOf(__first)) {
					response.__deadline = TimerHandle.INVALID;
				}
				__calls[at] = null;
			}
			__first = (__first + 1) & (PLACES - 1);
			__count--;
		}
		__live = 0;
		if (__timer != TimerHandle.INVALID) {
			Timer.clear(__timer);
			__timer = TimerHandle.INVALID;
		}
		__shrink();
	}

	/**
		The empty places at the front go, and so does any call there that no
		longer names its place, left by a way that could not find this
		queue, so the first is a call still waiting, or there is none.
	**/
	function __dropEmpty():Void {
		while (__count > 0) {
			final at:Int = __first & (__calls.length - 1);
			final response = __calls[at];
			if (response != null) {
				if (response.__deadline == deadlineOf(__first)) {
					return;
				}
				__calls[at] = null;
				__live--;
			}
			__first = (__first + 1) & (PLACES - 1);
			__count--;
		}
		__shrink();
	}

	/** The timer: every call that is due fails, and the timer is set for the next. **/
	function __fired():Void {
		__timer = TimerHandle.INVALID;
		__firing = true;
		final now:Float = Timer.getTime();
		var failed:Bool = false;
		var failure:Dynamic = null;
		while (true) {
			__dropEmpty();
			if (__count == 0) {
				break;
			}
			// Read again each time round: failing a call runs its handlers,
			// which may make calls, answer them, or stop the session.
			final at:Int = __first & (__calls.length - 1);
			if (__due[at] > now + DUE_EPSILON) {
				break;
			}
			final response = __calls[at];
			final milliseconds:Int = __milliseconds[at];
			__calls[at] = null;
			__live--;
			__first = (__first + 1) & (PLACES - 1);
			__count--;
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
			__timer = Timer.setTimeout(__due[__first & (__calls.length - 1)] - Timer.getTime(), __fire);
		}
		if (failed) {
			throw failure;
		}
	}

	/**
		The calls still waiting, in order and with no empty place between
		them, in a queue of `capacity` places: each told its new place.
	**/
	function __rebuild(capacity:Int):Void {
		final calls = __calls;
		final due = __due;
		final milliseconds = __milliseconds;
		final mask:Int = calls.length - 1;
		__allocate(capacity);
		final first:Int = __first;
		var count:Int = 0;
		for (i in 0...__count) {
			final from:Int = (first + i) & mask;
			final response = calls[from];
			if (response == null || response.__deadline != deadlineOf((first + i) & (PLACES - 1))) {
				continue;
			}
			final to:Int = (first + count) & (PLACES - 1);
			final at:Int = to & (capacity - 1);
			__calls[at] = response;
			__due[at] = due[from];
			__milliseconds[at] = milliseconds[from];
			response.__deadline = deadlineOf(to);
			count++;
		}
		__count = count;
		__live = count;
	}

	/** An empty queue that grew past `KEEP` starts again small. **/
	inline function __shrink():Void {
		if (__count == 0 && __calls.length > KEEP) {
			__allocate(INITIAL);
		}
	}

	function __allocate(capacity:Int):Void {
		__calls = new Vector(capacity);
		__due = new Vector(capacity);
		__milliseconds = new Vector(capacity);
	}
}
