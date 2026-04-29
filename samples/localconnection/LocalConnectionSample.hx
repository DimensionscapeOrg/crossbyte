import crossbyte.core.HostApplication;
import crossbyte.io.ByteArray;
import crossbyte.ipc.LocalConnection;

class LocalConnectionSample extends HostApplication {
	private static inline var DEFAULT_NAME:String = "crossbyte_sample_localconnection";

	public static function main():Void {
		#if !cpp
		Sys.println("LocalConnection is only supported on native cpp targets.");
		return;
		#end

		var app = new LocalConnectionSample();
		app.run(Sys.args());
	}

	public function new() {
		super();
	}

	private function run(args:Array<String>):Void {
		if (!LocalConnection.isSupported) {
			Sys.println("LocalConnection is only supported on native cpp targets.");
			return;
		}

		var mode = args.length > 0 ? args[0] : "demo";
		var name = args.length > 1 ? args[1] : DEFAULT_NAME;

		switch (mode) {
			case "demo":
				runDemo(name);
			case "listen":
				runListener(name);
			case "send":
				var message = args.length > 2 ? args[2] : "hello from sender";
				var value = args.length > 3 ? Std.parseInt(args[3]) : 42;
				if (value == null) {
					value = 42;
				}
				runSender(name, message, value);
			default:
				Sys.println("Usage:");
				Sys.println("  LocalConnectionSample demo [name]");
				Sys.println("  LocalConnectionSample listen [name]");
				Sys.println("  LocalConnectionSample send [name] [message] [value]");
		}
	}

	private function runDemo(name:String):Void {
		var server = new LocalConnection();
		var client = new LocalConnection();
		var receiver = new SampleReceiver();
		server.readEnabled = true;
		server.onData = input -> receiver.receive(input.readUTF(), input.readInt());
		server.listen(name);
		client.connect(name);

		var deadline = Sys.time() + 2.0;
		while ((!server.connected || !client.connected) && Sys.time() < deadline) {
			advance(1 / 60, 0);
			Sys.sleep(0.01);
		}

		client.send(makePayload("hello from demo", 42));

		deadline = Sys.time() + 2.0;
		while (!receiver.received && Sys.time() < deadline) {
			advance(1 / 60, 0);
			Sys.sleep(0.01);
		}

		if (!receiver.received) {
			server.close();
			client.close();
			throw "LocalConnection demo timed out waiting for the receiver.";
		}

		Sys.println("LocalConnection demo completed.");
		Sys.println('received -> "${receiver.message}" (${receiver.value})');

		server.close();
		client.close();
	}

	private function runListener(name:String):Void {
		var server = new LocalConnection();
		var receiver = new SampleReceiver();
		server.readEnabled = true;
		server.onData = input -> receiver.receive(input.readUTF(), input.readInt());
		server.listen(name);

		Sys.println('Listening on "$name". Press Ctrl+C to stop.');
		while (true) {
			advance(1 / 60, 0);
			if (receiver.received) {
				Sys.println('received -> "${receiver.message}" (${receiver.value})');
				receiver.reset();
			}
			Sys.sleep(0.05);
		}
	}

	private function runSender(name:String, message:String, value:Int):Void {
		var client = new LocalConnection();
		client.connect(name);
		client.send(makePayload(message, value));
		advance(1 / 60, 0);
		Sys.sleep(0.05);
		client.close();
	}

	private static function makePayload(message:String, value:Int):ByteArray {
		var payload = new ByteArray();
		payload.writeUTF(message);
		payload.writeInt(value);
		payload.position = 0;
		return payload;
	}
}

private class SampleReceiver {
	public var received:Bool = false;
	public var message:String = null;
	public var value:Int = 0;

	public function new() {}

	public function receive(message:String, value:Int):Void {
		received = true;
		this.message = message;
		this.value = value;
	}

	public function reset():Void {
		received = false;
		message = null;
		value = 0;
	}
}
