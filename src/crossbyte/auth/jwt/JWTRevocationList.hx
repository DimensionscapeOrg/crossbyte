package crossbyte.auth.jwt;

import crossbyte.errors.ArgumentError;
#if target.threaded
import sys.thread.Mutex;
#end

/**
 * Tokens refused before their time: the `jti` of each token revoked (on
 * sign-out, a password changed, an account closed), kept until the token
 * would have expired anyway, and then forgotten.
 *
 * `JWT.verify` consults one when it is given one, as `JWT.revocations`, and
 * refuses a token on it as `REVOKED`; `JWT.revoke(token)` checks a token's
 * signature and lists it. It is also usable on its own, with the claims a
 * service has read itself:
 *
 * ```haxe
 * var revoked = new JWTRevocationList();
 * revoked.revoke("token-7", 1893456000); // its jti, and its exp
 * trace(revoked.isRevoked("token-7", 1893456000)); // true
 * ```
 *
 * ## How long, and how many
 *
 * An entry is kept until its token's `exp` plus `leeway`, 60 seconds unless
 * given, which is how long past its `exp` a `JWT` still takes a token: keep
 * it at least the `leeway` of every `JWT` that consults the list, or a
 * revoked token is taken again for the difference. Entries go as their time
 * passes, the soonest first: each `revoke` and `sweep` drops every one whose
 * time has passed, so what the list holds is what is still live. A service
 * revoking rarely calls `sweep()` from a timer for what has passed to be
 * given back sooner.
 *
 * `maxEntries`, 100,000 unless given, bounds how many are held, so a stream
 * of revocations cannot grow it without end. Past it, the entry whose token
 * expires soonest makes room, and the list fails closed: from then on it
 * also refuses every token whose `exp` is no later than that one's, revoked
 * or not, until that time has passed. A revoked token is never taken again;
 * what a full list costs is the tokens nearest their own expiry, ended a
 * little early, and the more revocations past the bound, the younger the
 * tokens it ends. A token without a `jti` is never on the list, and never
 * refused by it.
 *
 * What a revocation costs to hold: its entry (the `jti` and its time) and a
 * place in a map and a heap, about 130 bytes natively besides the `jti`
 * itself, so the default bound holds some 17 MB with 20-character ids.
 * Only tokens that verified reach it through `JWT.revoke`, so what fills it
 * is the tokens a service issued itself. A revocation takes about 120 ns
 * natively, a little more as the list grows (190 ns at 64,000 held), and a
 * check 17 ns.
 *
 * Safe to use from several threads at once, as a `JWT` is: each call takes
 * a lock (on targets with threads), and a check allocates nothing.
 *
 * ## Keeping it
 *
 * The list is in memory: a process that restarts forgets it, and each
 * process verifying tokens keeps its own. To keep revocations, write each one
 * where the service keeps its state as it is made, its `jti` and `exp` (a
 * row, or a key of a key/value store such as `revoked/<jti>` holding the
 * `exp`), and as the service starts, `revoke` each again whose `exp` has
 * not passed; `entries()` gives what the list holds, for a snapshot. Several
 * processes taking the same tokens each `revoke` every revocation, sent to
 * them all (a channel they listen on, or the store read again).
 *
 * ```haxe
 * // Given saved:Array<{tokenId:String, expiresAt:Float}>.
 * var revoked = new JWTRevocationList();
 * for (entry in saved) {
 * 	revoked.revoke(entry.tokenId, entry.expiresAt);
 * }
 * ```
 */
class JWTRevocationList {
	/** `maxEntries` unless given: 100,000, `RateLimiter`'s bound on the clients it tracks. */
	public static inline final DEFAULT_MAX_ENTRIES:Int = 100000;

	/** `leeway` unless given: 60 seconds, a `JWT`'s own. */
	public static inline final DEFAULT_LEEWAY:Int = 60;

	/**
	 * The most entries held at once; past it the list fails closed, as the
	 * class notes say. 0 is no bound, which is safe only where nothing a
	 * peer does can revoke a token.
	 */
	public final maxEntries:Int;

	/** Seconds an entry is kept past its token's `exp`. */
	public final leeway:Int;

	/**
	 * Entries held: every token revoked whose time has not passed, besides
	 * any that have passed since the last `revoke` or `sweep`.
	 */
	public var length(get, never):Int;

	/**
	 * The time of the latest entry dropped to make room, in seconds since
	 * the epoch: a token whose `exp` plus `leeway` is no later is refused,
	 * jti or not on the list. Negative infinity while none has been, or once
	 * that time has passed.
	 */
	@:noCompletion private var __floor:Float = Math.NEGATIVE_INFINITY;

	@:noCompletion private final __entries:Map<String, RevokedToken> = new Map();

	// Every entry, ordered by its time, the soonest first: a binary heap.
	@:noCompletion private final __heap:Array<RevokedToken> = [];

	#if target.threaded
	@:noCompletion private final __lock:Mutex = new Mutex();
	#end

	/**
	 * @param maxEntries The most entries held: 100,000 unless given, 0 for
	 *        no bound.
	 * @param leeway Seconds an entry is kept past its token's `exp`: 60
	 *        unless given.
	 * @throws ArgumentError For a negative `maxEntries` or `leeway`.
	 */
	public function new(maxEntries:Int = DEFAULT_MAX_ENTRIES, leeway:Int = DEFAULT_LEEWAY) {
		if (maxEntries < 0) {
			throw new ArgumentError('JWTRevocationList maxEntries must not be negative ($maxEntries); 0 is no bound.');
		}
		if (leeway < 0) {
			throw new ArgumentError('JWTRevocationList leeway must not be negative ($leeway).');
		}
		this.maxEntries = maxEntries;
		this.leeway = leeway;
	}

	/**
	 * Refuses the token whose `jti` is `tokenId` until its `exp`,
	 * `expiresAt` in seconds since the epoch, has passed by `leeway`: the
	 * time it would have been refused anyway. Revoking one already listed
	 * keeps the later of the two times. Drops every entry whose time has
	 * passed, by the wall clock.
	 *
	 * `revoke(tokenId, expiresAt)` and `revoke(tokenId, expiresAt, now)` are
	 * two functions rather than one taking an optional time, which natively
	 * and on the jvm is boxed on its way in, as `JWT.verify`'s are.
	 *
	 * @return Whether it was listed: `false` for a token whose time has
	 *         passed already, which every `JWT` refuses as expired.
	 * @throws ArgumentError For a null `tokenId`, and an `expiresAt` that is
	 *         not a finite number.
	 */
	public overload extern inline function revoke(tokenId:String, expiresAt:Float):Bool {
		return __revoke(tokenId, expiresAt, __wallClock());
	}

	/**
	 * The same, judging what has passed by `now`, in seconds since the
	 * epoch: for a service that keeps its own clock, and for tests.
	 *
	 * @throws ArgumentError As above, and for a `now` of NaN.
	 */
	public overload extern inline function revoke(tokenId:String, expiresAt:Float, now:Float):Bool {
		return __revoke(tokenId, expiresAt, now);
	}

	/**
	 * Whether the token whose `jti` is `tokenId` and whose `exp` is
	 * `expiresAt` is refused: listed, or among those a full list refuses
	 * (see the class notes). `false` for a null `tokenId`. What `JWT.verify`
	 * asks. Allocates nothing.
	 */
	public function isRevoked(tokenId:Null<String>, expiresAt:Float):Bool {
		if (tokenId == null) {
			return false;
		}
		__acquire();
		// `+ 0.0`, as in `revoke`.
		final refused:Bool = __entries.exists(tokenId) || expiresAt + 0.0 + leeway <= __floor;
		__release();
		return refused;
	}

	/**
	 * Takes `tokenId` off the list, so its token verifies again: one revoked
	 * by mistake. A token refused only because the list was full stays
	 * refused until its time.
	 *
	 * @return Whether it was listed.
	 */
	public function remove(tokenId:String):Bool {
		if (tokenId == null) {
			return false;
		}
		__acquire();
		final entry:Null<RevokedToken> = __entries.get(tokenId);
		if (entry != null) {
			__entries.remove(tokenId);
			__removeAt(entry.index);
		}
		__release();
		return entry != null;
	}

	/**
	 * Drops every entry whose time has passed, by the wall clock, walking
	 * only those.
	 *
	 * `sweep()` and `sweep(now)` are two functions, as `revoke`'s are.
	 *
	 * @return How many went.
	 */
	public overload extern inline function sweep():Int {
		return __sweepLocked(__wallClock());
	}

	/**
	 * Drops every entry whose time had passed at `now`, in seconds since the
	 * epoch.
	 *
	 * @return How many went.
	 * @throws ArgumentError For a `now` of NaN.
	 */
	public overload extern inline function sweep(now:Float):Int {
		return __sweepLocked(now);
	}

	/**
	 * What the list holds, for a snapshot to keep: each entry's `jti` and its
	 * token's `exp`, the soonest to expire first. A copy, so revoking while
	 * walking it is safe.
	 */
	public function entries():Array<{tokenId:String, expiresAt:Float}> {
		__acquire();
		final held:Array<RevokedToken> = __heap.copy();
		__release();
		held.sort((a, b) -> a.until < b.until ? -1 : (a.until > b.until ? 1 : 0));
		return [for (entry in held) {tokenId: entry.tokenId, expiresAt: entry.until - leeway}];
	}

	/** Forgets everything, the fail-closed floor included. */
	public function clear():Void {
		__acquire();
		__entries.clear();
		__heap.resize(0);
		__floor = Math.NEGATIVE_INFINITY;
		__release();
	}

	@:noCompletion private function get_length():Int {
		__acquire();
		final count:Int = __heap.length;
		__release();
		return count;
	}

	@:noCompletion private function __revoke(tokenId:String, expiresAt:Float, now:Float):Bool {
		if (tokenId == null) {
			throw new ArgumentError("A revocation names its token by its jti, and null was given.");
		}
		if (!Math.isFinite(expiresAt)) {
			throw new ArgumentError('A revocation is kept until its token\'s exp, a finite number of seconds, not $expiresAt.');
		}
		if (Math.isNaN(now)) {
			throw new ArgumentError("JWTRevocationList.revoke was given a time of NaN.");
		}
		// `+ 0.0`: on the interpreter a Float given an Int keeps Int
		// arithmetic, and the leeway added to 2147483647 would wrap.
		final until:Float = expiresAt + 0.0 + leeway;
		__acquire();
		__sweep(now);
		if (until < now) {
			__release();
			return false;
		}
		var entry:Null<RevokedToken> = __entries.get(tokenId);
		if (entry != null) {
			if (until > entry.until) {
				entry.until = until;
				__down(entry.index);
			}
		} else {
			entry = new RevokedToken(tokenId, until, __heap.length);
			__entries.set(tokenId, entry);
			__heap.push(entry);
			__up(entry.index);
			if (maxEntries > 0 && __heap.length > maxEntries) {
				__makeRoom();
			}
		}
		__release();
		return true;
	}

	/** Drops the entry whose token expires soonest, and refuses every token expiring no later from now on. */
	@:noCompletion private function __makeRoom():Void {
		final first:RevokedToken = __heap[0];
		if (first.until > __floor) {
			__floor = first.until;
		}
		__entries.remove(first.tokenId);
		__removeAt(0);
	}

	@:noCompletion private function __sweepLocked(now:Float):Int {
		if (Math.isNaN(now)) {
			throw new ArgumentError("JWTRevocationList.sweep was given a time of NaN.");
		}
		__acquire();
		final dropped:Int = __sweep(now);
		__release();
		return dropped;
	}

	/** Under the lock: drops what had passed at `now`, the floor too once it has. */
	@:noCompletion private function __sweep(now:Float):Int {
		var dropped:Int = 0;
		while (__heap.length > 0 && __heap[0].until < now) {
			__entries.remove(__heap[0].tokenId);
			__removeAt(0);
			dropped++;
		}
		if (__floor < now) {
			__floor = Math.NEGATIVE_INFINITY;
		}
		return dropped;
	}

	// ------------------------------------------------------------- the heap

	@:noCompletion private function __removeAt(index:Int):Void {
		final last:RevokedToken = __heap.pop();
		if (index < __heap.length) {
			__heap[index] = last;
			last.index = index;
			__down(index);
			__up(last.index);
		}
	}

	@:noCompletion private function __up(index:Int):Void {
		final entry:RevokedToken = __heap[index];
		while (index > 0) {
			final parent:Int = (index - 1) >> 1;
			final above:RevokedToken = __heap[parent];
			if (above.until <= entry.until) {
				break;
			}
			__heap[index] = above;
			above.index = index;
			index = parent;
		}
		__heap[index] = entry;
		entry.index = index;
	}

	@:noCompletion private function __down(index:Int):Void {
		final count:Int = __heap.length;
		final entry:RevokedToken = __heap[index];
		while (true) {
			final left:Int = index * 2 + 1;
			if (left >= count) {
				break;
			}
			final right:Int = left + 1;
			final child:Int = right < count && __heap[right].until < __heap[left].until ? right : left;
			final below:RevokedToken = __heap[child];
			if (below.until >= entry.until) {
				break;
			}
			__heap[index] = below;
			below.index = index;
			index = child;
		}
		__heap[index] = entry;
		entry.index = index;
	}

	@:noCompletion private inline function __acquire():Void {
		#if target.threaded
		__lock.acquire();
		#end
	}

	@:noCompletion private inline function __release():Void {
		#if target.threaded
		__lock.release();
		#end
	}

	/** Seconds since the epoch by the wall clock, as `JWT` reads it. */
	@:noCompletion private static inline function __wallClock():Float {
		#if sys
		return Sys.time(); // time of day: a token's exp is seconds since the epoch
		#elseif js
		return js.lib.Date.now() / 1000; // time of day: as above
		#else
		return Date.now().getTime() / 1000; // time of day: as above
		#end
	}
}

/** One revoked token: its `jti`, until when it is refused, and its place in the heap. */
@:noCompletion
private class RevokedToken {
	public final tokenId:String;
	public var until:Float;
	public var index:Int;

	public function new(tokenId:String, until:Float, index:Int) {
		this.tokenId = tokenId;
		this.until = until;
		this.index = index;
	}
}
