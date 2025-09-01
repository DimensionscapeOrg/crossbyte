package crossbyte._internal.system.timer;

enum abstract TimerHandle(Int) from Int to Int {
	public static inline var GEN_BITS = 8;
	public static inline var GEN_MASK = (1 << GEN_BITS) - 1;
	public static inline var ID_SHIFT = GEN_BITS;
	public static inline var INVALID:TimerHandle = -1;

	public inline function new(id:Int, gen:Int):TimerHandle {
		this = ((id << ID_SHIFT) | (gen & GEN_MASK));
	}

	public inline function id():Int
		return this >>> ID_SHIFT;

	public inline function gen():Int
		return this & GEN_MASK;

	public inline function isValid():Bool
		return this != INVALID;
}
