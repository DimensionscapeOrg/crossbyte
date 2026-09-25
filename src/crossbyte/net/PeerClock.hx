package crossbyte.net;

import crossbyte.errors.ArgumentError;
import haxe.ds.Vector;

/**
 * Where a peer's clock stands against this one: what time it is there now,
 * and how sure of that this side can be.
 *
 * Built from exchanges the application makes itself, in whatever messages it
 * already sends. This side notes when it asked, the peer answers with the
 * time it read on its own clock, and this side notes when the answer came
 * back:
 *
 * ```haxe
 * // This side, now and then:
 * var ping = new ByteArray();
 * ping.writeDouble(haxe.Timer.stamp());
 * session.send(ping, 0, 0, UNRELIABLE);
 *
 * // The peer, on receiving that as `asked`: the time it was sent, and its own.
 * var pong = new ByteArray();
 * pong.writeDouble(asked.readDouble());
 * pong.writeDouble(haxe.Timer.stamp());
 * peerSession.send(pong, 0, 0, UNRELIABLE);
 *
 * // This side, on receiving that as `answer`:
 * var sentAt = answer.readDouble();
 * var peerTime = answer.readDouble();
 * clock.sample(sentAt, peerTime, haxe.Timer.stamp());
 * var peerNow = clock.now();
 * ```
 *
 * Unreliable, because a ping that had to be resent measures the resend. And
 * the two clocks need share nothing: each is whatever its side reads, and
 * `haxe.Timer.stamp()` on both is the usual choice, since it does not jump
 * when someone sets the time of day.
 *
 * One exchange places the peer's reading somewhere between the ask and the
 * answer, so the estimate takes the middle and is out by at most half the
 * round trip, which is `error`. What makes a round trip long is mostly
 * waiting in a queue, and usually on one leg more than the other, so the
 * estimate is taken from whichever exchange of the last `window` had the
 * shortest round trip: it has the smallest bound and the least room for
 * that lopsidedness. The rest are kept only to fall back on when that one
 * grows old. Old matters, because two clocks drift apart by up to a few
 * parts in ten thousand; sampling often enough that the window spans
 * seconds, not minutes, keeps that below the error bound.
 *
 * The estimate moves in steps, whenever a better exchange arrives. Something
 * that must not step -- a simulation's clock, an animation -- should ease
 * towards `now()` rather than follow it.
 *
 * **Threading.** None.
 */
final class PeerClock {
	/** How many of the latest exchanges the estimate is chosen from. **/
	public final window:Int;

	/** `true` once an exchange has been taken, and until `reset`. **/
	public var synced(get, never):Bool;

	/**
	 * Seconds to add to this side's clock to read the peer's: the peer's
	 * time is `local + offset`. Zero until synced.
	 */
	public var offset(default, null):Float = 0;

	/**
	 * The round trip of the exchange the estimate comes from, in seconds: the
	 * shortest in the window. -1 until synced.
	 */
	public var roundTrip(default, null):Float = -1;

	/**
	 * How far `offset` can be from the truth, in seconds: half of
	 * `roundTrip`, since the peer read its clock somewhere within it.
	 * Infinite until synced.
	 */
	public var error(default, null):Float = Math.POSITIVE_INFINITY;

	/**
	 * How much one round trip differs from the next, in seconds, smoothed as
	 * RFC 3550 smooths interarrival jitter. Over every exchange, not only
	 * the window. Zero until there have been two.
	 */
	public var jitter(default, null):Float = 0;

	/** How many exchanges the window holds, up to `window`. **/
	public var samples(default, null):Int = 0;

	@:noCompletion private final __clock:() -> Float;

	// The window, as a ring: each exchange's round trip and the offset it
	// gives, the slot the next one goes in, and the slot of the shortest.
	@:noCompletion private final __roundTrips:Vector<Float>;
	@:noCompletion private final __offsets:Vector<Float>;
	@:noCompletion private var __next:Int = 0;
	@:noCompletion private var __best:Int = -1;
	@:noCompletion private var __lastRoundTrip:Float = -1;

	/**
	 * @param window How many of the latest exchanges to choose among, from
	 *        1. More survives longer bursts of queueing; fewer follows drift
	 *        more closely.
	 * @param clock This side's clock in seconds; `haxe.Timer.stamp` unless
	 *        given. Read only by `now`.
	 * @throws ArgumentError If `window` is less than 1.
	 */
	public function new(window:Int = 16, ?clock:() -> Float) {
		if (window < 1) {
			throw new ArgumentError('A window holds at least one exchange, not $window.');
		}
		this.window = window;
		__clock = clock != null ? clock : haxe.Timer.stamp;
		__roundTrips = new Vector(window);
		__offsets = new Vector(window);
	}

	/**
	 * Takes one exchange.
	 *
	 * @param sentAt This side's clock when it asked.
	 * @param peerTime The peer's clock when it answered.
	 * @param receivedAt This side's clock when the answer arrived.
	 * @return Whether the estimate changed: this exchange was the shortest
	 *         yet, or the shortest before it left the window. `false` too for
	 *         an exchange that cannot have happened -- an answer before its
	 *         question, or a time that is not a finite number -- which is not
	 *         taken.
	 */
	public function sample(sentAt:Float, peerTime:Float, receivedAt:Float):Bool {
		var roundTrip:Float = receivedAt - sentAt;
		// A NaN fails every comparison, so this refuses those too; and a
		// finite difference means both of its ends were finite.
		if (!(roundTrip >= 0) || !Math.isFinite(roundTrip) || !Math.isFinite(peerTime)) {
			return false;
		}

		if (__lastRoundTrip >= 0) {
			var difference:Float = roundTrip - __lastRoundTrip;
			if (difference < 0) {
				difference = -difference;
			}
			jitter += (difference - jitter) / 16;
		}
		__lastRoundTrip = roundTrip;

		var at:Int = __next;
		__roundTrips[at] = roundTrip;
		__offsets[at] = peerTime - (sentAt + receivedAt) / 2;
		__next = at + 1 == window ? 0 : at + 1;
		if (samples < window) {
			samples++;
		}

		if (__best == at) {
			// The shortest was the oldest, and this one just took its place.
			__best = __shortest();
		} else if (__best < 0 || roundTrip <= __roundTrips[__best]) {
			// Ties go to the newer, whose offset has had less time to drift.
			__best = at;
		}

		var was:Float = offset;
		var wasRoundTrip:Float = this.roundTrip;
		offset = __offsets[__best];
		this.roundTrip = __roundTrips[__best];
		error = this.roundTrip / 2;
		return offset != was || this.roundTrip != wasRoundTrip;
	}

	/** The peer's clock now, as best this side can tell. **/
	public inline function now():Float {
		return __clock() + offset;
	}

	/** A time on this side's clock, on the peer's. **/
	public inline function toPeer(localTime:Float):Float {
		return localTime + offset;
	}

	/** A time on the peer's clock, on this side's. **/
	public inline function toLocal(peerTime:Float):Float {
		return peerTime - offset;
	}

	/** Forgets every exchange, as when the peer is a different one. **/
	public function reset():Void {
		offset = 0;
		roundTrip = -1;
		error = Math.POSITIVE_INFINITY;
		jitter = 0;
		samples = 0;
		__next = 0;
		__best = -1;
		__lastRoundTrip = -1;
	}

	private inline function get_synced():Bool {
		return __best >= 0;
	}

	// The slot of the shortest round trip held, the newest of any tie. Walked
	// oldest first, so a later equal one replaces an earlier.
	private function __shortest():Int {
		var best:Int = -1;
		var start:Int = samples < window ? 0 : __next;
		for (i in 0...samples) {
			var slot:Int = start + i;
			if (slot >= window) {
				slot -= window;
			}
			if (best < 0 || __roundTrips[slot] <= __roundTrips[best]) {
				best = slot;
			}
		}
		return best;
	}
}
