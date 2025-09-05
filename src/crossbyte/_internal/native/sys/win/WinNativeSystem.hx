package crossbyte._internal.native.sys.win;

/**
 * ...
 * @author Christopher Speciale
 */
@:cppInclude("Windows.h")
@:cppInclude("Winbase.h")
@:cppInclude("Winreg.h")
@:cppInclude("string")
@:cppInclude("algorithm")
@:cppInclude("cwctype")
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
			DWORD_PTR bit = ((DWORD_PTR)1) << index;
			if (value) {
				affinityMask = processAffinityMask | bit;
			} else {
				affinityMask = processAffinityMask & ~bit;
			}

			success = SetProcessAffinityMask(hProcess, affinityMask);
		");

		return untyped __cpp__("success");
	}

	public static function getDeviceId():Null<String> {
		var result:Null<String> = null;

		untyped __cpp__("{
			// Read HKLM\\SOFTWARE\\Microsoft\\Cryptography\\MachineGuid
			const wchar_t* kSubkey = L\"SOFTWARE\\\\Microsoft\\\\Cryptography\";
			const wchar_t* kValue  = L\"MachineGuid\";
			wchar_t wbuf[256];
			wbuf[0] = 0; // IMPORTANT: avoid `{0}` so hxcpp doesn't substitute
			DWORD  size = sizeof(wbuf);
			DWORD  type = 0;

			LONG r = RegGetValueW(
				HKEY_LOCAL_MACHINE,
				kSubkey,
				kValue,
				RRF_RT_REG_SZ,
				&type,
				(void*)wbuf,
				&size
			);

			::String hxOut = null();

			if (r == ERROR_SUCCESS) {
				// Normalize: strip braces + uppercase
				std::wstring guid(wbuf);
				if (!guid.empty() && guid.front() == L'{') guid.erase(guid.begin());
				if (!guid.empty() && guid.back()  == L'}') guid.pop_back();
				for (size_t i = 0; i < guid.size(); ++i) {
					guid[i] = (wchar_t)towupper((wint_t)guid[i]);
				}

				// Convert to UTF-8
				int need = WideCharToMultiByte(
					CP_UTF8, 0,
					guid.c_str(), (int)guid.size(),
					nullptr, 0, nullptr, nullptr
				);
				if (need > 0) {
					std::string utf8((size_t)need, '\\0');
					WideCharToMultiByte(
						CP_UTF8, 0,
						guid.c_str(), (int)guid.size(),
						&utf8[0], need, nullptr, nullptr
					);
					hxOut = ::String(utf8.c_str());
				}
			}

			{0} = hxOut; // write result back into the Haxe var
		}", result);

		return result;
	}
}
