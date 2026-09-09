package crossbyte._internal.native.sys.mac;

/**
 * System queries for macOS.
 *
 * The processor count comes from the POSIX call, the same one the Linux build
 * uses -- `_SC_NPROCESSORS_ONLN` counts the cores currently online, which is
 * what a caller sizing a pool wants.
 *
 * Affinity does not, because macOS does not have it. There is no
 * `sched_setaffinity`, and the nearest thing -- `thread_policy_set` with
 * `THREAD_AFFINITY_POLICY` -- is not the same feature: it is a hint rather
 * than a binding, it is scoped to one thread rather than the process, and it
 * returns `KERN_NOT_SUPPORTED` on Apple silicon. Reporting an empty mask says
 * "this platform cannot answer", which is true; returning a mask the scheduler
 * would quietly ignore would not be.
 */
@:cppInclude("unistd.h")
class MacNativeSystem {
	public static function getProcessorCount():Int {
		var cores:Int = untyped __cpp__("sysconf(_SC_NPROCESSORS_ONLN)");

		return cores > 0 ? cores : 1;
	}

	public static inline function getProcessAffinity():Array<Bool> {
		return [];
	}

	public static inline function hasProcessAffinity(index:Int):Bool {
		return false;
	}

	public static inline function setProcessAffinity(index:Int, value:Bool):Bool {
		return false;
	}

	/**
	 * Null, matching the Linux build. A stable machine identifier is available
	 * through `gethostuuid`, but it is left unimplemented on both rather than
	 * on neither, so the two POSIX targets keep saying the same thing.
	 */
	public static inline function getDeviceId():Null<String> {
		return null;
	}
}
