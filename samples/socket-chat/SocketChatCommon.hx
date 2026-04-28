import crossbyte.io.ByteArray;
import crossbyte.net.Socket;

class SocketChatCommon {
	public static inline var DEFAULT_HOST:String = "127.0.0.1";
	public static inline var DEFAULT_PORT:Int = 19090;
	public static inline var PUMP_INTERVAL:Float = 1 / 60;

	public static function sendFrame(socket:Socket, text:String):Void {
		socket.writeUTF(text);
		socket.flush();
	}

	public static function pumpIncoming(socket:Socket, inbox:ChatInbox, onMessage:String->Void):Void {
		if (socket.bytesAvailable <= 0) {
			return;
		}

		var chunk = new ByteArray();
		socket.readBytes(chunk, 0, socket.bytesAvailable);
		inbox.append(chunk);
		inbox.drain(onMessage);
	}

	public static function sanitizeName(value:String, fallback:String):String {
		if (value == null) {
			return fallback;
		}

		var name = StringTools.trim(value);
		if (name.length == 0) {
			return fallback;
		}

		name = ~/[^A-Za-z0-9_\-]/g.replace(name, "_");
		if (name.length > 20) {
			name = name.substr(0, 20);
		}

		return name.length > 0 ? name : fallback;
	}

	public static function parsePort(args:Array<String>, index:Int, fallback:Int):Int {
		if (args.length <= index) {
			return fallback;
		}

		var parsed = Std.parseInt(args[index]);
		return parsed == null ? fallback : parsed;
	}
}
