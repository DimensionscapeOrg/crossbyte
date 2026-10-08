import crossbyte.rpc.Float32;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;
import crossbyte.rpc.RPCStruct;
import crossbyte.rpc.UInt8;

class RPCGreeterSample {
	public static function main():Void {
		var link = LoopbackConnection.pair();
		link.client.bufferInbound = true;
		var commands = new GreeterCommands();
		var handler = new GreeterHandler();

		new RPCSession<GreeterCommands>(link.client, commands);
		new RPCSession(link.server, null, handler);

		var greeting:String = null;
		var total:Int = -1;
		var resultEvents = 0;

		commands.announce("client", "crossbyte rpc says hi");
		commands.getGreeting("Chris").then(value -> greeting = value);

		// A structure, an enum and an array, with no packing by hand.
		var visitor = new Visitor();
		visitor.name = "Chris";
		visitor.mood = Cheerful;
		visitor.level = 3;
		visitor.position = [1.5, -2.0];
		var welcome:String = null;
		commands.welcome(visitor).then(value -> welcome = value);

		var sumResponse = commands.add(7, 35);
		sumResponse.addEventListener(RPCResponse.RESULT, _ -> resultEvents++);
		sumResponse.then(value -> total = value);
		link.client.flushBufferedReads();

		if (handler.lastAnnouncement != "client: crossbyte rpc says hi") {
			throw 'Unexpected one-way RPC payload: ${handler.lastAnnouncement}';
		}

		if (greeting != "Hello, Chris!") {
			throw 'Unexpected greeting response: $greeting';
		}

		if (welcome != "Welcome, Chris (level 3, cheerful) at 1.5,-2") {
			throw 'Unexpected welcome response: $welcome';
		}

		if (total != 42) {
			throw 'Unexpected add() result: $total';
		}

		if (resultEvents != 1) {
			throw 'Expected exactly one RPC result event, got $resultEvents';
		}

		Sys.println("RPC sample completed.");
		Sys.println('announce -> ${handler.lastAnnouncement}');
		Sys.println('getGreeting -> $greeting');
		Sys.println('welcome -> $welcome');
		Sys.println('add -> $total');
	}
}

private interface GreeterContract {
	function announce(sender:String, message:String):Void;
	function getGreeting(name:String):String;
	function welcome(visitor:Visitor):String;
	function add(a:Int, b:Int):Int;
}

enum Mood {
	Calm;
	Cheerful;
}

/** Sent as its fields, by name order: level (1 byte), mood (1), name, position (two 4-byte floats). **/
class Visitor implements RPCStruct {
	public var name:String = "";
	public var mood:Mood = Calm;
	public var level:UInt8 = 0;
	public var position:Array<Float32> = [];

	public function new() {}
}

@:rpcContract(GreeterContract)
private class GreeterCommands extends RPCCommands {
	public function new() {}
}

private class GreeterHandler extends RPCHandler implements GreeterContract {
	public var lastAnnouncement:String = null;

	public function new() {}

	public function announce(sender:String, message:String):Void {
		lastAnnouncement = '$sender: $message';
	}

	public function getGreeting(name:String):String {
		return 'Hello, $name!';
	}

	public function welcome(visitor:Visitor):String {
		return 'Welcome, ${visitor.name} (level ${visitor.level}, ' + (visitor.mood == Cheerful ? "cheerful" : "calm") + ') at '
			+ [for (p in visitor.position) (p : Float)].join(",");
	}

	public function add(a:Int, b:Int):Int {
		return a + b;
	}
}
