package crossbyte.timer;

/**
	`CLOCK_MONOTONIC`, read independently of `haxe.Timer.stamp()`, so that
	`ClockTest` can hold native Linux and macOS to it.

	A file of its own because the C below has preprocessor lines, and the
	suite's coverage check, which reads a test class's conditionals off the
	start of each line, would take them for Haxe's.
**/
#if cpp
@:cppFileCode("
#ifndef HX_WINDOWS
#include <time.h>
#endif

static double crossbyte_probe_monotonic() {
#ifdef HX_WINDOWS
	return -1;
#else
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (double)now.tv_sec + (double)now.tv_nsec * 1e-9;
#endif
}
")
#end
class MonotonicProbe {
	/**
		Seconds on `CLOCK_MONOTONIC`, or -1 where `stamp()` is not meant to be
		that clock: Windows natively, where it is QueryPerformanceCounter, and
		every target but cpp.
	**/
	public static function read():Float {
		#if cpp
		return untyped __cpp__("crossbyte_probe_monotonic()");
		#else
		return -1;
		#end
	}
}
