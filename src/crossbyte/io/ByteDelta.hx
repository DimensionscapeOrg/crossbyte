package crossbyte.io;

import crossbyte.errors.IOError;

/**
 * Encodes bytes as their difference from a baseline both ends already hold,
 * and rebuilds them from it: the byte half of delta replication.
 *
 * A snapshot that mostly repeats the one a client last acknowledged costs a
 * few bytes for what stayed the same, and the bytes themselves only for
 * what changed. Nothing here knows what the bytes mean -- lay the state out
 * at fixed offsets, with what changes together sitting together, and a
 * tick in which most things held still shrinks to the fields that moved.
 *
 * ```haxe
 * // The server, per client. A null baseline encodes the snapshot whole.
 * var update:ByteArray = ByteDelta.encode(snapshot, sent.get(client.acknowledged));
 *
 * // The client, holding the snapshot the server encoded against.
 * var snapshot:ByteArray = ByteDelta.decode(update, received.get(baselineTick));
 * ```
 *
 * **Format.** The rebuilt length as a varint, then pairs of varints -- bytes
 * to copy from the baseline at the same offset, then bytes carried in the
 * delta -- each pair followed by the bytes it carries, until the length is
 * made up. The end is implied by the length, so a delta can sit inside a
 * larger message.
 *
 * **Untrusted input.** `decode` measures every pair against what is really
 * there before it copies anything, refuses a declared length above its
 * `maxLength` before building anything, and refuses a pair that makes no
 * progress. A hostile delta costs a thrown error, not memory or a hang.
 */
final class ByteDelta {
	/**
	 * Longest result `decode` builds unless told otherwise: 1 MB.
	 */
	public static inline var DEFAULT_MAX_LENGTH:Int = 1 << 20;

	// Ending a run of carried bytes to copy some instead costs a new pair of
	// varints, two bytes at least, so a match shorter than this is cheaper
	// carried along with the bytes around it.
	private static inline var MIN_COPY:Int = 3;

	/**
	 * Encodes `current` as its difference from `baseline`.
	 *
	 * Neither input's `position` moves.
	 *
	 * @param current The bytes to send.
	 * @param baseline The bytes the receiver already holds, or `null` to
	 *        encode `current` whole.
	 * @param output Where to write the delta, at its `position`; a new
	 *        `ByteArray` by default.
	 * @return `output`, or the new `ByteArray`, with the delta written.
	 */
	public static function encode(current:ByteArray, ?baseline:ByteArray, ?output:ByteArray):ByteArray {
		var out:ByteArray = output == null ? new ByteArray() : output;
		var length:Int = current.length;
		var shared:Int = baseline == null ? 0 : (baseline.length < length ? baseline.length : length);

		out.writeVarInt(length);

		var pos:Int = 0;
		while (pos < length) {
			var copy:Int = 0;
			while (pos + copy < shared && current[pos + copy] == baseline[pos + copy]) {
				copy++;
			}

			// Carry bytes until a match long enough to be worth copying.
			var start:Int = pos + copy;
			var end:Int = start;
			while (end < length) {
				if (end < shared && current[end] == baseline[end]) {
					var run:Int = 1;
					while (run < MIN_COPY && end + run < shared && current[end + run] == baseline[end + run]) {
						run++;
					}
					if (run >= MIN_COPY) {
						break;
					}
					end += run;
				} else {
					end++;
				}
			}

			out.writeVarInt(copy);
			out.writeVarInt(end - start);
			// Guarded because writeBytes reads a length of zero as "the rest".
			if (end > start) {
				out.writeBytes(current, start, end - start);
			}
			pos = end;
		}

		return out;
	}

	/**
	 * Rebuilds the bytes a delta was encoded from.
	 *
	 * Reads the delta from its `position`, and leaves `position` just past
	 * it. The baseline's `position` does not move.
	 *
	 * @param delta The delta, at its `position`.
	 * @param baseline The bytes it was encoded against, or `null` if it was
	 *        encoded whole.
	 * @param maxLength Longest result to build; a delta declaring more is
	 *        refused before anything is built.
	 * @return The rebuilt bytes, with `position` at 0.
	 * @throws IOError If the delta is malformed, declares more than
	 *         `maxLength`, or needs more baseline than it was given.
	 * @throws EOFError If the delta ends inside one of its varints.
	 */
	public static function decode(delta:ByteArray, ?baseline:ByteArray, maxLength:Int = DEFAULT_MAX_LENGTH):ByteArray {
		var length:Int = delta.readVarInt();
		if (length < 0 || length > maxLength) {
			throw new IOError('A delta declared a length of $length bytes; the most accepted is $maxLength.');
		}

		var baseLength:Int = baseline == null ? 0 : baseline.length;
		var out:ByteArray = new ByteArray();
		var pos:Int = 0;

		while (pos < length) {
			var copy:Int = delta.readVarInt();
			var carried:Int = delta.readVarInt();

			// Measured against what is left before either is added to
			// anything, so no sum can overflow into a length that passes.
			if (copy < 0 || carried < 0 || copy > length - pos || carried > length - pos - copy) {
				throw new IOError("A delta runs past the length it declared.");
			}
			if (copy == 0 && carried == 0) {
				throw new IOError("A delta pair copied and carried nothing.");
			}
			// Only a copy needs the baseline: past its end -- a snapshot that
			// grew -- a pair that carries everything is exactly right.
			if (copy > 0 && copy > baseLength - pos) {
				throw new IOError("A delta copies past the end of its baseline -- is it the right one?");
			}
			var available:Int = delta.bytesAvailable;
			if (carried > available) {
				throw new IOError("A delta ends inside the bytes it carries.");
			}

			if (copy > 0) {
				out.writeBytes(baseline, pos, copy);
			}
			if (carried > 0) {
				out.writeBytes(delta, delta.position, carried);
				delta.position += carried;
			}
			pos += copy + carried;
		}

		out.position = 0;
		return out;
	}
}
