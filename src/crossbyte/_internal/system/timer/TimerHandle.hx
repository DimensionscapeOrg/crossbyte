package crossbyte._internal.system.timer;

enum abstract TimerHandle(Int) from Int to Int {
	// id occupies the low ID_BITS; generation the GEN_BITS above it; the sign
	// bit is never used. A 12-bit generation (4096 reuses of a slot before it
	// wraps, against the 256 of the 8 bits it replaced) makes ABA aliasing
	// from slot reuse practically unreachable.
	//
	// The id had 20 bits, which put the generation's top bit in the sign bit:
	// from a slot's 2048th reuse every handle was negative, against what this
	// comment then said, and a live handle could equal INVALID. 19 id bits
	// still allow 524,288 timers alive at once on one runtime; a scheduler
	// asked for more says so rather than handing out ids that alias.
	public static inline var ID_BITS = 19;
	public static inline var ID_MASK = (1 << ID_BITS) - 1;
	public static inline var GEN_SHIFT = ID_BITS;
	public static inline var GEN_BITS = 12;
	public static inline var GEN_MASK = (1 << GEN_BITS) - 1;
	public static inline var INVALID:TimerHandle = -1;

	/** How many timers one scheduler can hold at once. */
	public static inline var MAX_TIMERS = 1 << ID_BITS;

	public inline function new(id:Int, gen:Int):TimerHandle {
		this = (((gen & GEN_MASK) << GEN_SHIFT) | (id & ID_MASK));
	}

	public inline function id():Int
		return this & ID_MASK;

	public inline function gen():Int
		return (this >>> GEN_SHIFT) & GEN_MASK;

	public inline function isValid():Bool
		return this != INVALID;
}
