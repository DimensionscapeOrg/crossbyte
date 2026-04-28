package crossbyte._internal.native.sys;

class NativeSystem {
	public static inline function getProcessorCount():Int {
		#if windows
		return crossbyte._internal.native.sys.win.WinNativeSystem.getProcessorCount();
		#elseif linux
		return crossbyte._internal.native.sys.linux.LinuxNativeSystem.getProcessorCount();
		#else
		return 0;
		#end
	}

	public static inline function getProcessAffinity():Array<Bool> {
		#if windows
		return crossbyte._internal.native.sys.win.WinNativeSystem.getProcessAffinity();
		#elseif linux
		return crossbyte._internal.native.sys.linux.LinuxNativeSystem.getProcessAffinity();
		#else
		return [];
		#end
	}

	public static inline function setProcessAffinity(index:Int, value:Bool):Bool {
		#if windows
		return crossbyte._internal.native.sys.win.WinNativeSystem.setProcessAffinity(index, value);
		#elseif linux
		return crossbyte._internal.native.sys.linux.LinuxNativeSystem.setProcessAffinity(index, value);
		#else
		return false;
		#end
	}

	public static inline function hasProcessAffinity(index:Int):Bool {
		#if windows
		return crossbyte._internal.native.sys.win.WinNativeSystem.hasProcessAffinity(index);
		#elseif linux
		return crossbyte._internal.native.sys.linux.LinuxNativeSystem.hasProcessAffinity(index);
		#else
		return false;
		#end
	}

	public static inline function getDeviceId():Null<String> {
		#if windows
		return crossbyte._internal.native.sys.win.WinNativeSystem.getDeviceId();
		#elseif linux
		return crossbyte._internal.native.sys.linux.LinuxNativeSystem.getDeviceId();
		#else
		return null;
		#end
	}
}
