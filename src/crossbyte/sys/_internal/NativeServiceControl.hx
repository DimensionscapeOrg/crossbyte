package crossbyte.sys._internal;

#if cpp
@:buildXml('<include name="${haxelib:crossbyte}/src/crossbyte/sys/_internal/NativeServiceControlBuild.xml"/>')
@:include("./NativeServiceControl.h")
extern class NativeServiceControl {
	/** Attach is still in flight; the dispatcher has neither been given a ServiceMain nor failed. */
	public static inline var PENDING:Int = 0;

	/** Running under the Service Control Manager. */
	public static inline var ATTACHED:Int = 1;

	/** An ordinary console process: nothing started this through the SCM. */
	public static inline var NOT_A_SERVICE:Int = 2;

	/** No SCM on this platform, or the handshake failed outright. */
	public static inline var UNAVAILABLE:Int = 3;

	@:native("crossbyte_service_attach")
	public static function attach(serviceName:cpp.ConstCharStar):Bool;

	@:native("crossbyte_service_attach_state")
	public static function attachState():Int;

	@:native("crossbyte_service_report_stop_pending")
	public static function reportStopPending(waitHintMs:Int):Void;

	@:native("crossbyte_service_report_stopped")
	public static function reportStopped(exitCode:Int):Void;

	@:native("crossbyte_service_simulate_stop")
	public static function simulateStop():Void;
}
#else
extern class NativeServiceControl {}
#end
