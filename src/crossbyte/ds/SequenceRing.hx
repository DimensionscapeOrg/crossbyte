package crossbyte.ds;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;

/**
 * The most recent values filed under a sequence number (a tick, a packet
 * number, a frame) and found again by it.
 *
 * It holds a window of `capacity` consecutive numbers ending at the newest
 * one put. Anything older has aged out and reads as `null`, even while its
 * slot is still waiting to be reused, so what `get` answers never depends on
 * which numbers happened to be skipped.
 *
 * Built with delta replication in mind. A server files each snapshot it
 * sends under its tick, and encodes a client's next one against the
 * snapshot that client last acknowledged, while that is still here. Once
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
 * It is also a receive window: what a reliable protocol holds past a gap,
 * filed by sequence as it arrives out of order, taken out with `remove` as
 * the gap fills, and acknowledged with `writeBits`: a bit for each number
 * past the next expected, the shape of a selective acknowledgement or a
 * game's ack bitfield. Nothing is hashed, and nothing is copied to answer:
 *
 * ```haxe
 * var held = new SequenceRing<Packet>(512);
 * held.put(packet.sequence, packet); // arrived past a gap
 *
 * while (held.has(expected)) {     // the gap has filled
 * 	deliver(held.get(expected));
 * 	held.remove(expected);
 * 	expected++;
 * }
 *
 * // Bit k of byte i: whether expected + 1 + 8i + k has arrived.
 * var length = held.writeBits(expected + 1, ack, 0, 64);
 * ```
 *
 * A window must fit the ring: with numbers more than `capacity` apart held
 * at once, the older ones age out.
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
	// A bit per slot, set while it holds a value: packed, so `writeBits`
	// reads eight slots at a time.
	private var __present:Bytes;

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
		this.__present = Bytes.alloc((size + 7) >> 3);
		this.__present.fill(0, this.__present.length, 0);
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
		__present.set(slot >> 3, __present.get(slot >> 3) | (1 << (slot & 7)));
		return true;
	}

	/**
	 * Takes out what is filed under `sequence`, and lets go of it. The window
	 * stays where it is: `newest`, and `isEmpty()`, still answer for what
	 * was put.
	 *
	 * @return `false` if nothing was filed under `sequence`, or it had aged
	 *         out.
	 */
	public function remove(sequence:Int):Bool {
		if (!__holds(sequence)) {
			return false;
		}

		var slot:Int = sequence & __mask;
		__present.set(slot >> 3, __present.get(slot >> 3) & ~(1 << (slot & 7)));
		__values[slot] = null;
		return true;
	}

	/**
	 * Writes whether each of the `byteCount * 8` numbers from `from` on is
	 * held, a bit each, lowest first: bit `k` of byte `i` says whether
	 * `from + 8i + k` is, as `has` would answer it. Numbers not held, aged
	 * out or never put write zeroes.
	 *
	 * Eight slots are read at a time, and only a set bit is looked at again
	 * (to check the slot holds that number and not one a ring's length
	 * away), so the cost follows `byteCount` and what is held, not the
	 * ring's size.
	 *
	 * @param from The number bit 0 of the first byte stands for.
	 * @param out Where the bits go, from `at` for `byteCount` bytes.
	 * @return How many bytes up to and including the last that is not zero:
	 *         what an acknowledgement has to carry. `0` when none is held.
	 * @throws RangeError When `at` and `byteCount` do not fit in `out`.
	 */
	public function writeBits(from:Int, out:Bytes, at:Int, byteCount:Int):Int {
		if (out == null) {
			throw new ArgumentError("writeBits needs bytes to write into.");
		}
		if (at < 0 || byteCount < 0 || at > out.length - byteCount) {
			throw new RangeError("writeBits: " + byteCount + " bytes at " + at + " do not fit in " + out.length + ".");
		}

		var used:Int = 0;
		// A slot is a bit of `__present`; slot s holds numbers congruent to s.
		// Bit k of byte i stands for from + 8i + k, in slot (from + 8i + k) &
		// mask: the ring read from `from`'s slot on, across the byte boundary
		// that slot may fall inside.
		var start:Int = from & __mask;
		var ringBytes:Int = capacity >> 3;
		for (i in 0...byteCount) {
			var bits:Int = 0;
			if (!__empty) {
				if (ringBytes > 0) {
					var first:Int = (start >> 3) + i;
					var shift:Int = start & 7;
					var low:Int = __present.get(first & (ringBytes - 1));
					var high:Int = __present.get((first + 1) & (ringBytes - 1));
					bits = ((low >> shift) | (high << (8 - shift))) & 0xFF;
				} else {
					// A ring of fewer than eight: its byte is not a whole turn.
					for (k in 0...8) {
						var slot:Int = (from + (i << 3) + k) & __mask;
						if ((__present.get(slot >> 3) & (1 << (slot & 7))) != 0) {
							bits |= 1 << k;
						}
					}
				}
				if (bits != 0) {
					for (k in 0...8) {
						if ((bits & (1 << k)) != 0 && !__holds((from + (i << 3) + k) | 0)) {
							bits &= ~(1 << k);
						}
					}
				}
			}
			out.set(at + i, bits);
			if (bits != 0) {
				used = i + 1;
			}
		}
		return used;
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
		__present.fill(0, __present.length, 0);
		for (i in 0...capacity) {
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
		return (__present.get(slot >> 3) & (1 << (slot & 7))) != 0 && __sequences[slot] == sequence;
	}
}
