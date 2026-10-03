/**
	Process CPU time split into user and kernel, and pinning to a set of
	CPUs, for the realtime performance harnesses. Windows hxcpp only; other
	targets fall back to `Sys.cpuTime()` and do not pin.
**/
#if (cpp && windows)
@:cppFileCode('
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
static double perfcpu_seconds(FILETIME f) {
	unsigned long long t = (((unsigned long long)f.dwHighDateTime) << 32) | f.dwLowDateTime;
	return ((double)t) / 10000000.0;
}
static double perfcpu_read(int which) {
	FILETIME c, e, k, u;
	if (!GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u)) return 0;
	return which == 0 ? perfcpu_seconds(u) : perfcpu_seconds(k);
}
')
#end
class PerfCpu {
	public static function user():Float {
		#if (cpp && windows)
		return untyped __cpp__("perfcpu_read(0)");
		#else
		return Sys.cpuTime();
		#end
	}

	public static function kernel():Float {
		#if (cpp && windows)
		return untyped __cpp__("perfcpu_read(1)");
		#else
		return 0;
		#end
	}

	/** Pins this process to the CPUs in `mask` (bit n = CPU n). **/
	public static function pin(mask:Int):Bool {
		#if (cpp && windows)
		return untyped __cpp__("SetProcessAffinityMask(GetCurrentProcess(), (DWORD_PTR)(unsigned int){0}) != 0", mask);
		#else
		return false;
		#end
	}
}
