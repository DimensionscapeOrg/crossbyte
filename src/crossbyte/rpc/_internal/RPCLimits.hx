package crossbyte.rpc._internal;

import crossbyte.net.RateLimiter;
import haxe.ds.Vector;

/**
	What a session keeps for its handler's `@:rpcLimit` rate limits: a token
	bucket for each rate-limited method, and the key its remote address is
	limited under. Made at the session's first rate-limited call, and again
	when its connection takes another peer (a `LocalConnection` listening
	again), which starts with full buckets of its own; let go when the
	session's handler changes, since another handler numbers its methods
	another way.

	A bucket is two numbers in one `Vector<Float>`, which natively and on
	the jvm holds them unboxed: the tokens spent, and when that was last
	brought up to date. Spent rather than left, so a bucket starts full at
	zero. They refill as `RateLimiter`'s do, continuously, a stalled or
	backwards clock minting nothing, and on the runtime's clock, as the
	session's deadlines are.
**/
@:noCompletion
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.Timer)
class RPCLimits {
	/** The life of its session's connection these were made for: `RPCSession.__epoch`. **/
	public final epoch:Int;

	/** For each rate-limited method, at twice its slot, the tokens spent, and after them when they were. **/
	public final buckets:Vector<Float>;

	/** The key the session's remote address is limited under, found the first time it is asked for. **/
	public var addressKey:Null<String> = null;

	public function new(epoch:Int, slots:Int) {
		this.epoch = epoch;
		buckets = new Vector<Float>(slots * 2);
		// Filled, since a vector is not on every target.
		for (i in 0...slots * 2) {
			buckets[i] = 0.0;
		}
	}

	/**
		Whether `session` may make a call to the method of rate-limit slot
		`slot` (of `slots` in its handler; -1 for one limited by address
		only), spending a token from its bucket of `capacity`, which refills
		`perSecond`, and one from `byAddress`'s bucket for the session's
		remote address when that is given. Neither is spent when the other
		refuses. Allocates nothing once the session's state is made.
	**/
	public static function allow(session:Null<RPCSession<Dynamic, Dynamic>>, slot:Int, slots:Int, capacity:Float, perSecond:Float,
			byAddress:Null<RateLimiter>):Bool {
		if (session == null) {
			return true;
		}
		var limits:Null<RPCLimits> = session.__limits;
		if (limits == null || limits.epoch != session.__epoch || limits.buckets.length < slots * 2) {
			limits = session.__limits = new RPCLimits(session.__epoch, slots);
		}
		if (slot < 0) {
			return byAddress == null || byAddress.tryAcquire(limits.keyOf(session));
		}
		final buckets:Vector<Float> = limits.buckets;
		final at:Int = slot << 1;
		final now:Float = clock();
		var spent:Float = buckets[at];
		final since:Float = now - buckets[at + 1];
		if (since > 0) {
			spent -= since * perSecond;
			if (spent < 0) {
				spent = 0;
			}
			buckets[at + 1] = now;
		}
		if (spent + 1 > capacity || (byAddress != null && !byAddress.tryAcquire(limits.keyOf(session)))) {
			buckets[at] = spent;
			return false;
		}
		buckets[at] = spent + 1;
		return true;
	}

	/** The key `session`'s remote address is limited under, as `RateLimiter.addressKey` gives it: an IPv6 address by its /64. **/
	public function keyOf(session:RPCSession<Dynamic, Dynamic>):String {
		var key:Null<String> = addressKey;
		if (key == null) {
			final connection = session.__connection;
			key = addressKey = RateLimiter.addressKey(connection != null ? connection.remoteAddress : null);
		}
		return key;
	}

	/**
		The runtime's clock, which `pump` and the loop advance, as the
		session's deadlines read it: a load and a call where `haxe.Timer.stamp()`
		asks the system. The system's monotonic clock on a thread with no
		runtime.
	**/
	static inline function clock():Float {
		final time:Float = crossbyte.Timer.tryGetTime();
		return time >= 0.0 ? time : haxe.Timer.stamp();
	}
}
