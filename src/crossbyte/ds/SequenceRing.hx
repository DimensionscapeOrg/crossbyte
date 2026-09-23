package crossbyte.ds;

import crossbyte.errors.ArgumentError;

/**
 * The most recent values filed under a sequence number -- a tick, a packet
 * number, a frame -- and found again by it.
 *
 * It holds a window of `capacity` consecutive numbers ending at the newest
 * one put. Anything older has aged out and reads as `null`, even while its
 * slot is still waiting to be reused, so what `get` answers never depends on
 * which numbers happened to be skipped.
 *
 * Built with delta replication in mind. A server files each snapshot it
 * sends under its tick, and encodes a client's next one against the
 * snapshot that client last acknowledged -- while that is still here. Once
 * it has aged out, `get` says so, and the snapshot goes in full instead:
 *
 * ```haxe
 * var sent = new SequenceRing<ByteArray>(64);
 * sent.put(sim.tick, snapshot);
 *
 * // No baseline, and ByteDelta encodes the snapshot whole.
 * var update:ByteArray = ByteDelta.encode(snapshot, sent.get(client.acknowledged));
 * ```
 *
 * Numbers wrap past `2^31 - 1` and are ordered by the sign of their
 * difference, as `crossbyte.Seq32` orders them, so a ring keyed by a tick
 * counter carries on through the wrap.
 *
 * **Threading.** None.
 */
final class SequenceRing<T> {
	/**
	 * How many consecutive numbers the ring holds: the size asked for,
	 * rounded up to a power of two.
	 */
	public var capacity(default, null):Int;

	/**
	 * The newest number put. Meaningless while `isEmpty()`.
	 */
	public var newest(default, null):Int = 0;

	private var __mask:Int;
	private var __empty:Bool = true;
	private var __sequences:Array<Int>;
	private var __values:Array<Null<T>>;
	private var __present:Array<Bool>;

	/**
	 * @param capacity Consecutive numbers to hold; rounded up to a power of
	 *        two, which is what keeps every slot distinct across the wrap.
	 */
	public function new(capacity:Int) {
		if (capacity < 1 || capacity > 1 << 30) {
			throw new ArgumentError("A ring holds from 1 to 2^30 values.");
		}

		// A power of two, because 2^32 has no other divisors: with any other
		// size, the slot a number lands in would jump at the wrap, and the
		// numbers either side of it could share one.
		var size:Int = 1;
		while (size < capacity) {
			size <<= 1;
		}

		this.capacity = size;
		this.__mask = size - 1;
		this.__sequences = [for (_ in 0...size) 0];
		this.__values = [for (_ in 0...size) null];
		this.__present = [for (_ in 0...size) false];
	}

	/**
	 * Files `value` under `sequence`, replacing whatever was filed there.
	 * A number newer than `newest` moves the window forward to it.
	 *
	 * @return `false`, filing nothing, if `sequence` has already aged out.
	 */
	public function put(sequence:Int, value:T):Bool {
		if (__empty) {
			newest = sequence;
			__empty = false;
		} else {
			var ahead:Int = (sequence - newest) | 0;
			if (ahead > 0) {
				newest = sequence;
			} else if (ahead <= -capacity) {
				return false;
			}
		}

		var slot:Int = sequence & __mask;
		__sequences[slot] = sequence;
		__values[slot] = value;
		__present[slot] = true;
		return true;
	}

	/**
	 * The value filed under `sequence`, or `null` if none was, or it has
	 * aged out of the window.
	 */
	public function get(sequence:Int):Null<T> {
		return __holds(sequence) ? __values[sequence & __mask] : null;
	}

	/**
	 * Whether a value is filed under `sequence` and still in the window.
	 */
	public function has(sequence:Int):Bool {
		return __holds(sequence);
	}

	/**
	 * Whether nothing has been put since the ring was made or cleared.
	 */
	public function isEmpty():Bool {
		return __empty;
	}

	/**
	 * Forgets everything, and lets go of the values it held.
	 */
	public function clear():Void {
		for (i in 0...capacity) {
			__present[i] = false;
			__values[i] = null;
		}
		__empty = true;
		newest = 0;
	}

	private function __holds(sequence:Int):Bool {
		if (__empty) {
			return false;
		}

		// `| 0` so the difference wraps on JavaScript as it does elsewhere.
		var behind:Int = (newest - sequence) | 0;
		if (behind < 0 || behind >= capacity) {
			return false;
		}

		var slot:Int = sequence & __mask;
		return __present[slot] && __sequences[slot] == sequence;
	}
}
