package crossbyte.sys._internal;

#if cpp
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/sys/_internal/NativeLifecycleBuild.xml"/>')
@:include("./NativeLifecycle.h")
extern class NativeLifecycle {
	@:native("crossbyte_lifecycle_install")
	public static function install():Bool;

	@:native("crossbyte_lifecycle_request_shutdown")
	public static function requestShutdown():Void;

	@:native("crossbyte_lifecycle_is_shutdown_requested")
	public static function isShutdownRequested():Bool;

	@:native("crossbyte_lifecycle_reset")
	public static function reset():Void;

	#if windows
	// Tests only; see NativeLifecycle.h.
	@:native("crossbyte_lifecycle_deliver_console_event")
	public static function deliverConsoleEvent(controlType:Int, closeWaitMs:Int):Bool;

	@:native("crossbyte_lifecycle_holding")
	public static function holding():Int;

	@:native("crossbyte_lifecycle_force_service_session_for_test")
	public static function forceServiceSessionForTest(inServiceSession:Int):Void;

	@:native("crossbyte_lifecycle_load_user32_for_test")
	public static function loadUser32ForTest():Bool;

	@:native("crossbyte_lifecycle_session_window_ready")
	public static function sessionWindowReady():Bool;

	@:native("crossbyte_lifecycle_deliver_session_end")
	public static function deliverSessionEnd(closeWaitMs:Int):Int;
	#else
	// Tests only; see NativeLifecycle.h.
	@:native("crossbyte_lifecycle_raise_for_test")
	public static function raiseForTest(signal:Int):Bool;

	@:native("crossbyte_lifecycle_ignore_for_test")
	public static function ignoreForTest(signal:Int, ignored:Bool):Bool;

	@:native("crossbyte_lifecycle_uninstall_for_test")
	public static function uninstallForTest():Void;
	#end
}
#else
extern class NativeLifecycle {}
#end
