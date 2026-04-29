import crossbyte.core.HostApplication;
import crossbyte.events.StatusEvent;
import crossbyte.ipc.SharedChannel;

class SharedChannelSample extends HostApplication {
	private static inline var DEFAULT_NAME:String = "crossbyte_sample_sharedchannel";

	public static function main():Void {
		#if !cpp
		Sys.println("SharedChannel is only supported on native cpp targets.");
		return;
		#end

		var app = new SharedChannelSample();
		app.run(Sys.args());
	}

	public function new() {
		super();
	}

	private function run(args:Array<String>):Void {
		if (!SharedChannel.isSupported) {
			Sys.println("SharedChannel is only supported on native cpp targets.");
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
				Sys.println("  SharedChannelSample demo [name]");
				Sys.println("  SharedChannelSample listen [name]");
				Sys.println("  SharedChannelSample send [name] [message] [value]");
		}
	}

	private function runDemo(name:String):Void {
		var server = new SharedChannel();
		var sender = new SharedChannel();
		var receiver = new SampleReceiver();
		server.client = receiver;
		server.connect(name);
		sender.addEventListener(StatusEvent.STATUS, event -> {
			Sys.println('send status -> level=${event.level} code=${event.code}');
		});

		Sys.sleep(0.05);
		sender.send(name, "receive", {message: "hello from demo", value: 42});

		var deadline = Sys.time() + 2.0;
		while (!receiver.received && Sys.time() < deadline) {
			advance(1 / 60, 0);
			Sys.sleep(0.01);
		}

		if (!receiver.received) {
			server.close();
			sender.close();
			throw "SharedChannel demo timed out waiting for the receiver.";
		}

		Sys.println("SharedChannel demo completed.");
		Sys.println('received -> "${receiver.message}" (${receiver.value})');

		server.close();
		sender.close();
	}

	private function runListener(name:String):Void {
		var server = new SharedChannel();
		var receiver = new SampleReceiver();
		server.client = receiver;
		server.connect(name);

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
		var sender = new SharedChannel();
		sender.addEventListener(StatusEvent.STATUS, event -> {
			Sys.println('send status -> level=${event.level} code=${event.code}');
		});
		sender.send(name, "receive", {message: message, value: value});
		advance(1 / 60, 0);
		Sys.sleep(0.05);
		sender.close();
	}
}

private class SampleReceiver {
	public var received:Bool = false;
	public var message:String = null;
	public var value:Int = 0;

	public function new() {}

	public function receive(payload:Dynamic):Void {
		received = true;
		this.message = Std.string(Reflect.field(payload, "message"));
		var rawValue:Dynamic = Reflect.field(payload, "value");
		this.value = rawValue == null ? 0 : Std.int(rawValue);
	}

	public function reset():Void {
		received = false;
		message = null;
		value = 0;
	}
}
