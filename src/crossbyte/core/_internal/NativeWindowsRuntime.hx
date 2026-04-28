package crossbyte.core._internal;

@:buildXml("
<files id='haxe'>
	<compilerflag value='-I../../src/crossbyte/core/_internal'/>
	<file name='../../src/crossbyte/core/_internal/NativeWindowsRuntime.cpp' if='windows'>
		<depend name='../../src/crossbyte/core/_internal/NativeWindowsRuntime.h'/>
	</file>
</files>
<target id='haxe'>
	<lib name='Winmm.lib' if='windows'/>
</target>
")
@:include("NativeWindowsRuntime.h")
extern class NativeWindowsRuntime {
	@:native("crossbyte_windows_begin_timing_period") public static function beginTimingPeriod(milliseconds:Int):Void;
	@:native("crossbyte_windows_end_timing_period") public static function endTimingPeriod(milliseconds:Int):Void;
	@:native("crossbyte_windows_set_high_priority_process") public static function setHighPriorityProcess():Void;
	@:native("crossbyte_windows_get_current_thread_id") public static function getCurrentThreadId():Int;
	@:native("crossbyte_windows_set_thread_priority") public static function setThreadPriority(threadId:Int, priority:Int):Void;
}
