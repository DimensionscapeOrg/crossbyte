package crossbyte._internal.native.sys.linux;

/**
 * ...
 * @author Christopher Speciale
 */
@:cppInclude("sched.h")
class NativeSystem {
	private static function getProcessorCount():Int {
		var cores:Int = untyped __cpp__("sysconf(_SC_NPROCESSORS_ONLN);");

		return cores > 0 ? cores : 1;
	};

	private static function getProcessAffinity():Array<Bool> {
		untyped __cpp__("
			cpu_set_t cpuSet;
			CPU_ZERO(&cpuSet);
			
			int success = sched_getaffinity(0, sizeof(cpu_set_t), &cpuSet);
		");

		if (untyped __cpp__("success") < 0) {
			return [];
		}
		// TODO: only get hProcess once for all functions and cache it
		untyped __cpp__("Array<bool> affinity = Array_obj<bool>::__new(0);");

		var numCores:Int = getProcessorCount();
		for (i in 0...numCores) {
			untyped __cpp__("
				uint32_t bit = 1 << i;
				bool isSet = CPU_ISSET(i, &cpuSet) != 0;

				affinity[i] = isSet;
			");
		}

		return untyped __cpp__("affinity");
	}

	private static function hasProcessAffinity(index:Int):Bool {
		untyped __cpp__("
			cpu_set_t cpuSet;
			CPU_ZERO(&cpuSet);			

			uint32_t success = sched_getaffinity(0, sizeof(cpu_set_t), &cpuSet);
		");

		// TODO: throw an error if success is false instead
		if (untyped __cpp__("success") < 0) {
			return false;
		}

		return untyped __cpp__("CPU_ISSET(index, &cpuSet) != 0;");
	}

	private static function setProcessAffinity(index:Int, value:Bool):Bool {
		untyped __cpp__("
			cpu_set_t cpuSet;
			CPU_ZERO(&cpuSet);
			uint32_t processAffinityMask;
			uint32_t systemAffinityMask;

			uint32_t success = sched_getaffinity(0, sizeof(cpu_set_t), &cpuSet);;
		");

		if (untyped __cpp__("success") < 0) {
			return false;
		}

		if (value) {
			untyped __cpp__("CPU_SET(index, &cpuSet)");
		} else {
			untyped __cpp__("CPU_CLR(index, &cpuSet)");
		}

		return untyped __cpp__("sched_setaffinity(0, sizeof(cpu_set_t), & cpuSet)") > -1;
	}
}
