package crossbyte._internal.native.sys.win;

/**
 * ...
 * @author Christopher Speciale
 */
@:cppInclude("Windows.h")
@:cppInclude("Winbase.h")
class WinNativeSystem {
	private static function getProcessorCount():Int {
		untyped __cpp__("
			HANDLE hProcess = GetCurrentProcess();
			SYSTEM_INFO systemInfo;
			GetSystemInfo(&systemInfo);
		");

		return untyped __cpp__("systemInfo.dwNumberOfProcessors;");
	};

	private static function getProcessAffinity():Array<Bool> {
		untyped __cpp__("
			HANDLE hProcess = GetCurrentProcess();

			DWORD_PTR processAffinityMask;
			DWORD_PTR systemAffinityMask;

			BOOL success = GetProcessAffinityMask(hProcess, &processAffinityMask, &systemAffinityMask);
		");

		if (!untyped __cpp__("success")) {
			return [];
		}
		// TODO: only get hProcess once for all functions and cache it
		untyped __cpp__("Array<BOOL> affinity = Array_obj<BOOL>::__new(0);");

		var numCores:Int = getProcessorCount();
		for (i in 0...numCores) {
			untyped __cpp__("
				DWORD bit = 1 << i;
				BOOL isSet = (processAffinityMask & bit) != 0;

				affinity[i] = isSet;
			");
		}

		return untyped __cpp__("affinity");
	}

	private static function hasProcessAffinity(index:Int):Bool {
		untyped __cpp__("
			HANDLE hProcess = GetCurrentProcess();
			DWORD_PTR processAffinityMask;
			DWORD_PTR systemAffinityMask;

			BOOL success = GetProcessAffinityMask(hProcess, &processAffinityMask, &systemAffinityMask);
		");

		// TODO: throw an error if success is false instead
		if (!untyped __cpp__("success")) {
			return false;
		}

		untyped __cpp__("
			DWORD bit = 1 << index;
			BOOL isSet = (processAffinityMask & bit) != 0;
		");

		return untyped __cpp__("isSet");
	}

	private static function setProcessAffinity(index:Int, value:Bool):Bool {
		untyped __cpp__("
			HANDLE hProcess = GetCurrentProcess();
			DWORD_PTR processAffinityMask;
			DWORD_PTR systemAffinityMask;

			BOOL success = GetProcessAffinityMask(hProcess, &processAffinityMask, &systemAffinityMask);
		");

		if (!untyped __cpp__("success")) {
			return false;
		}

		untyped __cpp__("
			DWORD_PTR affinityMask;
			DWORD bit = 1 << index;
			if (value) {
				affinityMask = processAffinityMask | bit;
			} else {
				affinityMask = processAffinityMask & ~bit;
			}

			success = SetProcessAffinityMask(hProcess, affinityMask);
		");

		return untyped __cpp__("success");
	}
}
