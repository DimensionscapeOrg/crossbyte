package crossbyte.utils;

/**
 * ...
 * @author Christopher Speciale
 */
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
