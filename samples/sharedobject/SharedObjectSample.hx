import crossbyte.ipc.SharedObject;
import haxe.Json;

class SharedObjectSample {
	private static inline var DEFAULT_NAME:String = "crossbyte_sample_sharedobject";

	public static function main():Void {
		if (!SharedObject.isSupported) {
			Sys.println("SharedObject is only supported on native cpp targets.");
			return;
		}

		var args = Sys.args();
		var mode = args.length > 0 ? args[0] : "demo";
		var name = args.length > 1 ? args[1] : DEFAULT_NAME;

		switch (mode) {
			case "demo":
				runDemo(name);
			case "write":
				var message = args.length > 2 ? args[2] : "hello from writer";
				var count = args.length > 3 ? Std.parseInt(args[3]) : 1;
				if (count == null) {
					count = 1;
				}
				runWrite(name, message, count);
			case "read":
				runRead(name);
			default:
				Sys.println("Usage:");
				Sys.println("  SharedObjectSample demo [name]");
				Sys.println("  SharedObjectSample write [name] [message] [count]");
				Sys.println("  SharedObjectSample read [name]");
		}
	}

	private static function runDemo(name:String):Void {
		var writer:SharedObject = null;
		var reader:SharedObject = null;
		try {
			writer = new SharedObject(name, 8192, {message: "hello from writer", count: 1, active: true});
			writer.flush();

			reader = new SharedObject(name, 8192);
			Sys.println("reader initial -> " + Json.stringify(reader.data));

			reader.data.count = reader.data.count + 1;
			reader.data.message = "reader updated shared state";
			reader.flush();

			writer.sync();
			Sys.println("writer after sync -> " + Json.stringify(writer.data));

			writer.clear();
			reader.sync();
			Sys.println("reader after clear -> " + Json.stringify(reader.data));
		} catch (error:Dynamic) {
			if (reader != null) {
				reader.close();
			}
			if (writer != null) {
				writer.close();
			}
			throw error;
		}
		if (reader != null) {
			reader.close();
		}
		if (writer != null) {
			writer.close();
		}
	}

	private static function runWrite(name:String, message:String, count:Int):Void {
		var shared:SharedObject = null;
		try {
			shared = new SharedObject(name, 8192);
			shared.data = {
				message: message,
				count: count,
				updatedAt: Date.now().toString()
			};
			shared.flush();
			Sys.println("wrote -> " + Json.stringify(shared.data));
		} catch (error:Dynamic) {
			if (shared != null) {
				shared.close();
			}
			throw error;
		}
		if (shared != null) {
			shared.close();
		}
	}

	private static function runRead(name:String):Void {
		var shared:SharedObject = null;
		try {
			shared = new SharedObject(name, 8192);
			shared.sync();
			Sys.println("read -> " + Json.stringify(shared.data));
		} catch (error:Dynamic) {
			if (shared != null) {
				shared.close();
			}
			throw error;
		}
		if (shared != null) {
			shared.close();
		}
	}
}
