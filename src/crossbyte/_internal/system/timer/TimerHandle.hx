package crossbyte._internal.system.timer;

/**
	A timer's handle: a number a scheduler gives each timer it arms, counting
	up from zero, so no handle is given twice until 2^31 timers have been
	armed on that scheduler (ten hours at sixty thousand a second), and the
	counter then starts again, past any handle still held by a live timer.
	So a handle kept once its timer has gone names no other timer, and a
	stale `clear()` cancels nothing. Never negative, so never `INVALID`.
**/
enum abstract TimerHandle(Int) from Int to Int {
	public static inline var INVALID:TimerHandle = -1;

	/** The largest handle; the count starts again from zero after it. */
	public static inline var MAX_HANDLE:Int = 0x7FFFFFFF;

	/** How many timers one scheduler can hold at once. */
	public static inline var MAX_TIMERS = 1 << 19;

	public inline function isValid():Bool
		return this != INVALID;
}
