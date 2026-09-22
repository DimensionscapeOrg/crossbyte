package crossbyte.ds;

/**
 * A 32-bit opaque handle that encodes both an index and a generation length.
 * Used to safely reference entries in a SlotMap, guarding against use-after-free bugs.
 *
 * The bit partition is **fixed**:
 * - lower `INDEX_BITS` bits store the index
 * - upper `GEN_BITS`  bits store the generation
 *
 */
@:forward
abstract SlotHandle(Int) from Int to Int {
	public static inline final INVALID:SlotHandle = new SlotHandle(-1);

	/** Number of bits used for the index portion (fixed). */
	public static inline final INDEX_BITS:Int = 24;

	/** Bitmask for extracting the index portion. */
	public static inline var INDEX_MASK:Int = (1 << INDEX_BITS) - 1;

	/** Number of bits used for the generation portion. */
	public static inline var GEN_BITS:Int = 32 - INDEX_BITS;

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
		return this >>> INDEX_BITS;
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
