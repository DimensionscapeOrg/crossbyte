package crossbyte.net;

/**
 * One request's claim on a `ConcurrencyLimiter`: waiting for capacity,
 * holding it, or finished with it.
 *
 * `release()` is the only thing to call on it, and it is right in every
 * state. It frees capacity the claim holds, withdraws a request still
 * waiting, and does nothing once the claim has ended -- so a connection can
 * release its claim when it closes without first asking what became of it,
 * and a second release cannot hand out capacity that was only returned once.
 *
 * Once released, a claim hears nothing more: a grant or refusal already
 * decided but not yet delivered is dropped rather than delivered late.
 */
@:allow(crossbyte.net.ConcurrencyLimiter)
final class ConcurrencyPermit {
	private static inline var WAITING:Int = 0;
	private static inline var HELD:Int = 1;
	private static inline var DONE:Int = 2;

	private static inline var NOTIFY_NONE:Int = 0;
	private static inline var NOTIFY_GRANTED:Int = 1;
	private static inline var NOTIFY_REJECTED:Int = 2;

	/**
	 * Capacity this claim asked for, in the limiter's units.
	 */
	public var cost(default, null):Int;

	/**
	 * Whether the claim holds capacity right now.
	 */
	public var held(get, never):Bool;

	/**
	 * Whether the claim is still waiting for capacity.
	 */
	public var waiting(get, never):Bool;

	/**
	 * Why the request was refused, or `null` if it was not.
	 */
	public var rejection(default, null):Null<ConcurrencyRejection> = null;

	private var __limiter:ConcurrencyLimiter;
	private var __state:Int;
	private var __notify:Int = NOTIFY_NONE;
	private var __deadline:Float = 0;
	private var __onGranted:ConcurrencyPermit->Void;
	private var __onRejected:ConcurrencyRejection->Void;

	private function new(limiter:ConcurrencyLimiter, cost:Int, state:Int, ?onGranted:ConcurrencyPermit->Void,
			?onRejected:ConcurrencyRejection->Void) {
		this.__limiter = limiter;
		this.cost = cost;
		this.__state = state;
		this.__onGranted = onGranted;
		this.__onRejected = onRejected;
	}

	/**
	 * Ends the claim: frees the capacity it holds, or withdraws it from the
	 * queue, or -- if it had already ended -- does nothing.
	 *
	 * @return `true` if this call freed capacity or withdrew a waiting
	 *         request, `false` if the claim had already ended.
	 */
	public function release():Bool {
		return __limiter.__release(this);
	}

	private inline function __finish():Void {
		__state = DONE;
		__notify = NOTIFY_NONE;
		__onGranted = null;
		__onRejected = null;
	}

	private inline function get_held():Bool {
		return __state == HELD;
	}

	private inline function get_waiting():Bool {
		return __state == WAITING;
	}
}
