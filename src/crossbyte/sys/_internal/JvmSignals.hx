package crossbyte.sys._internal;

#if (java || jvm)
/**
	The JVM's own signal hook, which every HotSpot-derived JVM ships in
	`jdk.unsupported`. A handler set here replaces the JVM's default, which
	for SIGTERM and SIGINT is to run shutdown hooks and halt, too late and
	too abruptly for a service to drain. `ProcessLifecycle` uses it to latch a
	shutdown request instead, the same thing its native handlers do.
**/
@:native("sun.misc.Signal")
extern class JvmSignal {
	function new(name:String):Void;
	static function handle(signal:JvmSignal, handler:JvmSignalHandler):JvmSignalHandler;
	static function raise(signal:JvmSignal):Void;
	function getName():String;
}

@:native("sun.misc.SignalHandler")
extern interface JvmSignalHandler {
	function handle(signal:JvmSignal):Void;
}
#end
