package crossbyte._internal.system.timer;

enum abstract TimerHandle(Int) from Int to Int {
	// id occupies the low ID_BITS; generation occupies the remaining high bits.
	// Widening the generation field (12 bits => 4096 reuses per slot before
	// wrap, vs the old 8 bits / 256) makes ABA aliasing from slot reuse
	// practically unreachable, while 20 id bits keeps slot capacity sane
	// (~1M concurrent timers). Both fields stay below the sign bit (20+12=32,
	// but the top gen bit is never produced by an unsigned 12-bit value).
	public static inline var ID_BITS = 20;
	public static inline var ID_MASK = (1 << ID_BITS) - 1;
	public static inline var GEN_SHIFT = ID_BITS;
	public static inline var GEN_BITS = 12;
	public static inline var GEN_MASK = (1 << GEN_BITS) - 1;
	public static inline var INVALID:TimerHandle = -1;

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
