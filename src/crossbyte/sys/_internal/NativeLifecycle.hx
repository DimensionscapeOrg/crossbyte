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

	@:native("crossbyte_lifecycle_console_handlers_holding")
	public static function consoleHandlersHolding():Int;
	#end
}
#else
extern class NativeLifecycle {}
#end
