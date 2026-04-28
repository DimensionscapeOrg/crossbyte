import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;

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

		if (total != 42) {
			throw 'Unexpected add() result: $total';
		}

		if (resultEvents != 1) {
			throw 'Expected exactly one RPC result event, got $resultEvents';
		}

		Sys.println("RPC sample completed.");
		Sys.println('announce -> ${handler.lastAnnouncement}');
		Sys.println('getGreeting -> $greeting');
		Sys.println('add -> $total');
	}
}

private interface GreeterContract {
	function announce(sender:String, message:String):Void;
	function getGreeting(name:String):String;
	function add(a:Int, b:Int):Int;
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

	public function add(a:Int, b:Int):Int {
		return a + b;
	}
}
