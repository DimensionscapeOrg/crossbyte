package crossbyte._internal.system;

/**
	The sleep behind `crossbyte.sys.System.sleep`, alone in its module.

	The library's own waits call this rather than `System`, whose module
	reaches `java.*` on the jvm. Some of the library is typed in a jvm build's
	macro context, `RPCCommands` has macro functions and imports the network
	stack, and Haxe defines `jvm` there too, so a path from the runtime to
	`System` failed the build with "You cannot access the java package while in
	a macro".

	Not in a browser, as `System.sleep` is not: a page cannot block a thread,
	and `Sys.sleep` does not exist there, which failed the browser build of
	the whole library.
**/
#if !(js && !nodejs)
class Sleep {
	#if (eval && !macro)
	private static var __windows:Null<Bool> = null;
	#end

	/** See `crossbyte.sys.System.sleep`. **/
	public static function sleep(seconds:Float):Void {
		if (!(seconds > 0)) {
			seconds = 0;
		}
		#if (eval && !macro)
		if (__windows == null) {
			__windows = Sys.systemName() == "Windows";
		}
		if (__windows) {
			// Less than a millisecond is Sleep(0) there: the thread yields,
			// as a sleep of nothing does elsewhere.
			sys.net.Socket.select([], [], [], seconds > 0 ? seconds : 0.0001);
			return;
		}
		#end
		Sys.sleep(seconds);
	}
}
#end
