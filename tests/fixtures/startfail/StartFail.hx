import crossbyte.core.ServerApplication;
import crossbyte.events.Event;

/**
	A server whose startup fails, or that ends with the code it is given:
	UncaughtErrorTest runs it to see what the process exits with.
**/
class StartFail extends ServerApplication {
	static function main():Void {
		new StartFail();
	}

	function new() {
		super();
		addEventListener(Event.INIT, _ -> {
			#if startfail_exit
			crossbyte.core.CrossByte.current().exit(Std.parseInt(haxe.macro.Compiler.getDefine("startfail_exit")));
			#else
			throw "the database would not open";
			#end
		});
	}
}
