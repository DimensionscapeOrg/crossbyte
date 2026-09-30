package crossbyte.ds;

/**
 * A 32-bit opaque handle that encodes both an index and a generation length.
 * Used to safely reference entries in a SlotMap, guarding against use-after-free bugs.
 *
 * The bit partition is **fixed**:
 * - lower `INDEX_BITS` bits store the index
 * - the next `GEN_BITS` bits store the generation
 * - the sign bit is never set, so a handle is never negative and never
 *   `INVALID`
 *
 * The generation was eight bits, so a handle kept after its entry died -- a
 * missile's target, a last attacker -- resolved to whatever took its slot 256
 * reuses later, and with the free list handing the same slot back first, 256
 * reuses come in seconds. It is eleven now, as `TimerHandle`'s was widened
 * for exactly this: a stale handle has to outlive 2048 reuses of its slot to
 * alias. The index gives up the bits, so a map holds at most 1,048,576
 * entries.
 *
 * A handle is not an `Int` of its own accord. It converted to one silently,
 * so a handle passed where an id belongs -- `grid.set(entity.handle, x, y)`
 * for `grid.set(entity.slot, ...)` -- compiled, and worked until the slot's
 * first reuse made the handle 1,048,576 or more, when `SpatialGrid` and
 * `InterestSet` grew their arrays to fit it: 117 MB by the third reuse. The
 * slot is `index()`; the whole handle, to write down and read back, is
 * `toInt()`, and an `Int` still becomes a handle when assigned to one.
 */
@:forward
abstract SlotHandle(Int) from Int {
	public static inline final INVALID:SlotHandle = new SlotHandle(-1);

	/** Number of bits used for the index portion (fixed). */
	public static inline final INDEX_BITS:Int = 20;

	/** Bitmask for extracting the index portion. */
	public static inline var INDEX_MASK:Int = (1 << INDEX_BITS) - 1;

	/** Number of bits used for the generation portion: what is left below the sign bit. */
	public static inline var GEN_BITS:Int = 31 - INDEX_BITS;

	/**
		Bitmask for the generation portion.

		A generation counts reuses of one slot and there are only `GEN_BITS`
		of it, so it has to be kept inside that on the way in. A counter
		allowed past the mask makes a handle whose generation reads as the
		truncated value while the slot still holds the untruncated one, and
		the two never compare equal again -- so the slot can never be freed.
	**/
	public static inline var GEN_MASK:Int = (1 << GEN_BITS) - 1;

	/**
	 * Creates a new SlotHandle
	 *
	 */
	public inline function new(v:Int) {
		this = v;
	}

	/**
	 * The handle as the `Int` it is stored as, for writing it down; assigning
	 * that `Int` to a `SlotHandle` reads it back.
	 */
	public inline function toInt():Int {
		return this;
	}

	/**
	 * Extract the **index** portion of this handle.
	 *
	 * @return The index (lower `INDEX_BITS` bits).
	 */
	public inline function index():Int {
		return this & INDEX_MASK;
	}

	/**
	 * Extract the **generation** portion of this handle.
	 *
	 * @return The generation (upper `GEN_BITS` bits).
	 */
	public inline function gen():Int {
		return (this >>> INDEX_BITS) & GEN_MASK;
	}

	/**
	 * Constructs a new handle from the given index and generation.
	 *
	 * @param index The slot index (must fit within `INDEX_BITS`).
	 * @param gen The generation count (must fit within `GEN_BITS`).
	 * @return A SlotHandle encoding both values.
	 */
	public static inline function make(index:Int, gen:Int):SlotHandle {
		return new SlotHandle(((gen & GEN_MASK) << INDEX_BITS) | (index & INDEX_MASK));
	}
}
