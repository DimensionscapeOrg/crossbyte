package crossbyte._internal.native.sys;

#if windows
typedef NativeSystem = crossbyte._internal.native.sys.win.WinNativeSystem;
#elseif linux
typedef NativeSystem = crossbyte._internal.native.sys.linux.LinuxNativeSystem;
#else
class NativeSystem {
	extern private static function getProcessorCount():Int;

	extern private static function getProcessAffinity():Array<Bool>;

	extern private static function setProcessAffinity(index:Int, value:Bool):Bool;

	extern private static function hasProcessAffinity(index:Int):Bool;

	extern private static function getDeviceId():Null<String>;
}
#end
