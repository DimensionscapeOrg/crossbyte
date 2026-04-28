package crossbyte.utils;

/** Minimal logging helper used by runtime and sample code. */
class Logger {
	public static function info(message:String):Void {
		Sys.println("[INFO] " + message);
	}

	public static function error(message:String):Void {
		Sys.println("[ERROR] " + message);
	}

	public static function separator():Void{
		Sys.println("-------------------------------------");
	}
}
