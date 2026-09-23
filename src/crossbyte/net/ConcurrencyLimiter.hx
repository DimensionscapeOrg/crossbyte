package crossbyte.net;

import crossbyte.errors.ArgumentError;

/**
 * Caps how much work is in flight at once -- logins, handshakes, database
 * calls, anything a server can start more of than it can finish -- and
 * decides what happens to the rest: refused on the spot, or held in a
 * bounded queue for a bounded time.
 *
 * `RateLimiter` meters how often; this meters how many at once. A server
 * accepting players faster than it can authenticate them wants both.
 *
 * ```haxe
 * // At most 32 logins at once; up to 256 more wait, for 5 seconds at most.
 * var logins = new ConcurrencyLimiter(32, 256, 5.0);
 *
 * // A login arrives.
 * client.login = logins.acquire(
 * 	permit -> authenticate(client, () -> permit.release()),
 * 	reason -> client.close('login refused: $reason'));
 *
 * // The client goes away -- whatever became of its login.
 * client.login.release();
 *
 * // Every tick.
 * logins.sweep();
 * ```
 *
 * **Capacity** is counted in whatever units callers pass as `cost`: one per
 * request by default, or bytes, or rows. `limit` may be changed at any time,
 * which is the hook for an adaptive scheme that moves it with latency or
 * load; lowering it revokes nothing already held.
 *
 * **Waiting.** With `maxQueued` above zero, a request that finds no capacity
 * free waits in arrival order for up to `maxWait` seconds. Nothing jumps the
 * queue -- not a smaller request behind a larger one, and not `tryAcquire()`
 * -- so a large request is never starved by a stream of small ones. A waiter
 * is granted by whichever call frees enough capacity, or refused with
 * `TIMED_OUT` by the first `sweep()` at or after its deadline: there is no
 * timer in here, so call `sweep()` from your tick. Every waiter shares the
 * one `maxWait`, which keeps deadlines in queue order; a caller that wants
 * to give up sooner releases its permit.
 *
 * **Callbacks** run inside the call that decided them. `onGranted` or
 * `onRejected` may run before `acquire()` returns -- when capacity is free,
 * or there is no room to wait -- and otherwise inside the `release()`,
 * `sweep()`, `close()` or `limit` change that settled it. A callback may call
 * back into the limiter: whatever that decides is delivered after the
 * callback returns, in order, never nested inside it, so a thousand waiters
 * each releasing in their own grant cost one stack frame, not a thousand. A
 * callback that throws has still been granted or refused; the exception
 * reaches the caller, and anything decided alongside it is delivered by the
 * next call into the limiter.
 *
 * **Threading.** None. Use it from the runtime that owns it.
 */
@:allow(crossbyte.net.ConcurrencyPermit)
final class ConcurrencyLimiter {
	/**
	 * Capacity, in the units callers pass as `cost`. Raising it admits
	 * waiters that now fit. Lowering it revokes nothing already held --
	 * `inFlight` can sit above it until enough is released -- and leaves
	 * waiters queued, to be admitted if it rises again or refused when their
	 * wait runs out. A request costing more than the current limit is
	 * refused at once with `EXCEEDS_LIMIT` rather than queued.
	 */
	public var limit(get, set):Int;

	/**
	 * Capacity currently held: the summed cost of every held permit.
	 */
	public var inFlight(default, null):Int = 0;

	/**
	 * Capacity free right now. Zero while `inFlight` is at or above `limit`.
	 */
	public var available(get, never):Int;

	/**
	 * Requests waiting for capacity.
	 */
	public var queued(default, null):Int = 0;

	/**
	 * Most requests that may wait at once. Zero means a request that finds no
	 * capacity is refused rather than queued.
	 */
	public var maxQueued(default, null):Int;

	/**
	 * Longest a request waits for capacity, in seconds, before it is refused.
	 */
	public var maxWait(default, null):Float;

	/**
	 * Whether `close()` has been called.
	 */
	public var closed(default, null):Bool = false;

	private var __limit:Int;
	private var __clock:Void->Float;

	// Waiting permits in arrival order, from __head on. A permit withdrawn
	// from the middle stays where it is until the head reaches it, and
	// __dead counts those, so the array can be compacted long before it
	// fills with them: acquire-then-withdraw in a loop must not grow memory
	// while one waiter at the head goes unserved.
	private var __queue:Array<ConcurrencyPermit> = [];
	private var __head:Int = 0;
	private var __dead:Int = 0;

	// Outcomes decided but not yet delivered, in the order they were decided.
	private var __outbox:Array<ConcurrencyPermit> = [];
	private var __outboxAt:Int = 0;
	private var __delivering:Bool = false;

	/**
	 * @param limit Capacity, in the units callers pass as `cost`.
	 * @param maxQueued Most requests that may wait for capacity at once; zero
	 *        refuses instead of waiting.
	 * @param maxWait Seconds a request may wait before it is refused. Must be
	 *        above zero when anything may wait; `Math.POSITIVE_INFINITY` waits
	 *        without a limit.
	 * @param clock Where the time comes from, in seconds; it must not run
	 *        backwards. Supply one in a test.
	 */
	public function new(limit:Int, maxQueued:Int = 0, maxWait:Float = 0, ?clock:Void->Float) {
		if (limit < 0) {
			throw new ArgumentError("A concurrency limit cannot be negative.");
		}
		if (maxQueued < 0) {
			throw new ArgumentError("maxQueued cannot be negative.");
		}
		if (Math.isNaN(maxWait) || maxWait < 0) {
			throw new ArgumentError("maxWait must be zero or more seconds.");
		}
		// Every waiter would be refused by the next sweep, having waited for
		// nothing: a queue that cannot hold anyone is a configuration mistake,
		// not a policy.
		if (maxQueued > 0 && maxWait == 0) {
			throw new ArgumentError("A queue needs maxWait above zero; use Math.POSITIVE_INFINITY to wait without a limit.");
		}

		this.__limit = limit;
		this.maxQueued = maxQueued;
		this.maxWait = maxWait;
		this.__clock = clock == null ? function():Float return haxe.Timer.stamp() : clock;
	}

	/**
	 * Takes capacity now if it is free, and never waits.
	 *
	 * Fails while anyone is queued, even with capacity free, because a free
	 * unit behind a waiting request belongs to that request once enough
	 * else is returned.
	 *
	 * @return A held permit, or `null` if the capacity is not there.
	 */
	public function tryAcquire(cost:Int = 1):Null<ConcurrencyPermit> {
		__requireCost(cost);

		var permit:ConcurrencyPermit = null;
		if (!closed && cost <= __limit) {
			__settle(__clock());

			if (queued == 0 && inFlight + cost <= __limit) {
				permit = new ConcurrencyPermit(this, cost, ConcurrencyPermit.HELD);
				inFlight += cost;
			}
		}

		__deliver();
		return permit;
	}

	/**
	 * Asks for capacity: granted now if it is free and nobody is queued,
	 * otherwise queued if there is room to wait, otherwise refused.
	 *
	 * @param onGranted Called with the permit once it holds the capacity.
	 *        Release the permit when the work is done.
	 * @param onRejected Called with the reason if the request is refused.
	 * @param cost Capacity the request needs; one by default.
	 * @return The request's permit, whatever happened to it. Keep it to
	 *         withdraw the request -- or free what it holds -- with
	 *         `release()`.
	 */
	public function acquire(onGranted:ConcurrencyPermit->Void, ?onRejected:ConcurrencyRejection->Void, cost:Int = 1):ConcurrencyPermit {
		if (onGranted == null) {
			throw new ArgumentError("acquire() needs a callback for the grant.");
		}
		__requireCost(cost);

		var permit:ConcurrencyPermit = new ConcurrencyPermit(this, cost, ConcurrencyPermit.WAITING, onGranted, onRejected);

		if (closed) {
			__reject(permit, CLOSED);
		} else if (cost > __limit) {
			__reject(permit, EXCEEDS_LIMIT);
		} else {
			var now:Float = __clock();
			__settle(now);

			if (queued == 0 && inFlight + cost <= __limit) {
				__grant(permit);
			} else if (queued < maxQueued) {
				permit.__deadline = now + maxWait;
				__queue.push(permit);
				queued++;
			} else {
				__reject(permit, SATURATED);
			}
		}

		__deliver();
		return permit;
	}

	/**
	 * Refuses every waiter whose wait has run out, then admits whoever the
	 * capacity now fits. Call it from your tick.
	 *
	 * @param now The time to judge deadlines by; the clock's by default.
	 * @return How many waiters were refused with `TIMED_OUT`.
	 */
	public function sweep(?now:Float):Int {
		var expired:Int = closed ? 0 : __settle(now == null ? __clock() : now);
		__deliver();
		return expired;
	}

	/**
	 * Refuses every waiter with `CLOSED`, and every request from now on.
	 * Capacity already held stays held until its permits are released, so
	 * `inFlight` reaching zero is what says the work has drained.
	 */
	public function close():Void {
		if (!closed) {
			closed = true;

			for (i in __head...__queue.length) {
				var permit:ConcurrencyPermit = __queue[i];
				if (permit.__state == ConcurrencyPermit.WAITING) {
					__reject(permit, CLOSED);
				}
			}
			__queue = [];
			__head = 0;
			__dead = 0;
			queued = 0;
		}

		__deliver();
	}

	private function __release(permit:ConcurrencyPermit):Bool {
		var state:Int = permit.__state;

		if (state == ConcurrencyPermit.WAITING) {
			permit.__finish();
			queued--;
			__dead++;

			// It may have been the head, holding back smaller requests
			// behind it that fit already.
			if (!closed) {
				__admit();
			}
			__compact();
			__deliver();
			return true;
		}

		if (state == ConcurrencyPermit.HELD) {
			permit.__finish();
			inFlight -= permit.cost;

			if (!closed) {
				__settle(__clock());
			}
			__deliver();
			return true;
		}

		// Already ended. A refusal decided but not yet delivered goes with it.
		permit.__finish();
		return false;
	}

	// Expiry before admission: a waiter past its deadline was due a refusal,
	// and granting it now would hand capacity to a caller that may already
	// have given up and answered for it. Deadlines ascend along the queue,
	// so the first waiter still in time ends the search.
	private function __settle(now:Float):Int {
		var expired:Int = 0;

		while (__head < __queue.length) {
			var permit:ConcurrencyPermit = __queue[__head];

			if (permit.__state != ConcurrencyPermit.WAITING) {
				__head++;
				__dead--;
				continue;
			}
			if (permit.__deadline > now) {
				break;
			}

			__head++;
			queued--;
			expired++;
			__reject(permit, TIMED_OUT);
		}

		__admit();
		__compact();
		return expired;
	}

	// First come, first served, strictly: a request that does not fit
	// stops the ones behind it, even the ones that would.
	private function __admit():Void {
		while (__head < __queue.length) {
			var permit:ConcurrencyPermit = __queue[__head];

			if (permit.__state != ConcurrencyPermit.WAITING) {
				__head++;
				__dead--;
				continue;
			}
			if (inFlight + permit.cost > __limit) {
				break;
			}

			__head++;
			queued--;
			__grant(permit);
		}
	}

	// Keeps the array within about twice the requests actually waiting,
	// whatever the pattern of arrivals and withdrawals.
	private function __compact():Void {
		var length:Int = __queue.length;

		if (__head == length) {
			if (length > 0) {
				__queue.resize(0);
				__head = 0;
				__dead = 0;
			}
			return;
		}

		var wasted:Int = __head + __dead;
		if (wasted > 32 && wasted * 2 > length) {
			var live:Array<ConcurrencyPermit> = [];
			for (i in __head...length) {
				var permit:ConcurrencyPermit = __queue[i];
				if (permit.__state == ConcurrencyPermit.WAITING) {
					live.push(permit);
				}
			}
			__queue = live;
			__head = 0;
			__dead = 0;
		}
	}

	private function __grant(permit:ConcurrencyPermit):Void {
		permit.__state = ConcurrencyPermit.HELD;
		inFlight += permit.cost;
		permit.__onRejected = null;
		permit.__notify = ConcurrencyPermit.NOTIFY_GRANTED;
		__outbox.push(permit);
	}

	private function __reject(permit:ConcurrencyPermit, reason:ConcurrencyRejection):Void {
		permit.__state = ConcurrencyPermit.DONE;
		permit.rejection = reason;
		permit.__onGranted = null;

		if (permit.__onRejected != null) {
			permit.__notify = ConcurrencyPermit.NOTIFY_REJECTED;
			__outbox.push(permit);
		}
	}

	// Delivers outcomes in the order they were decided. Re-entered from a
	// callback it returns at once, and the loop already running picks up
	// whatever that callback decided: outcomes queue behind each other
	// instead of nesting inside each other.
	private function __deliver():Void {
		if (__delivering) {
			return;
		}
		__delivering = true;

		while (__outboxAt < __outbox.length) {
			var permit:ConcurrencyPermit = __outbox[__outboxAt++];
			var notify:Int = permit.__notify;
			var onGranted:ConcurrencyPermit->Void = permit.__onGranted;
			var onRejected:ConcurrencyRejection->Void = permit.__onRejected;

			// Cleared first, so a permit released from inside its own callback
			// sees nothing left to drop, and the callbacks do not outlive the
			// only delivery they will ever get.
			permit.__notify = ConcurrencyPermit.NOTIFY_NONE;
			permit.__onGranted = null;
			permit.__onRejected = null;

			try {
				if (notify == ConcurrencyPermit.NOTIFY_GRANTED) {
					onGranted(permit);
				} else if (notify == ConcurrencyPermit.NOTIFY_REJECTED) {
					onRejected(permit.rejection);
				}
			} catch (e:haxe.Exception) {
				__delivering = false;
				throw e;
			}

			// A long chain of grants, each releasing into the next, would
			// otherwise keep every one it ever delivered until it ends.
			if (__outboxAt >= 1024 && __outboxAt * 2 >= __outbox.length) {
				__outbox = __outbox.slice(__outboxAt);
				__outboxAt = 0;
			}
		}

		__outbox.resize(0);
		__outboxAt = 0;
		__delivering = false;
	}

	private inline function __requireCost(cost:Int):Void {
		if (cost < 1) {
			throw new ArgumentError("A request must cost at least 1.");
		}
	}

	private inline function get_limit():Int {
		return __limit;
	}

	private function set_limit(value:Int):Int {
		if (value < 0) {
			throw new ArgumentError("A concurrency limit cannot be negative.");
		}
		__limit = value;

		if (!closed) {
			__settle(__clock());
		}
		__deliver();
		return value;
	}

	private inline function get_available():Int {
		return inFlight >= __limit ? 0 : __limit - inFlight;
	}
}
