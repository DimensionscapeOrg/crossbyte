package crossbyte.rpc;

import utest.Assert;

/**
	A contract may name its methods and arguments what it likes: the names
	the generated code uses for itself do not take them.

	A handler method named `input` or `requestId` was called through the
	generated decoder's parameter of that name, and the build failed at the
	user's method with "crossbyte.io.ByteArrayInput cannot be called"; a
	commands argument named `requestId` was a duplicate parameter, and one
	named `framed` was written as the frame itself. Found building a game
	server whose contract had an `input` method.
**/
class RPCMethodNamesTest extends utest.Test {
	public function testMethodsAndArgumentsNamedAsTheGeneratedCodesOwnStillWork():Void {
		var link = LinkedConnection.pair();
		var commands = new NamesCommands();
		var handler = new NamesHandler();
		var client = new RPCSession<NamesCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);

		var sum:Null<Int> = null;
		commands.input(2, 3, 4).then(v -> sum = v);
		var echoed:Null<String> = null;
		commands.requestId("x").then(v -> echoed = v);
		commands.framed(7, 8);
		var answered:Null<Int> = null;
		commands.response(5).then(v -> answered = v);

		Assert.equals(9, sum, "a method named input, with arguments named framed and requestId");
		Assert.equals("x!", echoed, "a method named requestId, with an argument named input");
		Assert.same([7, 8], handler.seen, "a one-way method named framed");
		Assert.equals(6, answered, "a method and an argument named response");
		client.close();
		server.close();
	}
}

interface NamesContract {
	function input(framed:Int, requestId:Int, receiver:Int):Int;
	function requestId(input:String):String;
	function framed(framed:Int, op:Int):Void;
	function response(response:Int):Int;
}

@:rpcContract(NamesContract)
private class NamesCommands extends RPCCommands {
	public function new() {}
}

private class NamesHandler extends RPCHandler implements NamesContract {
	public var seen:Array<Int> = [];

	public function new() {}

	public function input(framed:Int, requestId:Int, receiver:Int):Int {
		return framed + requestId + receiver;
	}

	public function requestId(input:String):String {
		return input + "!";
	}

	public function framed(framed:Int, op:Int):Void {
		seen.push(framed);
		seen.push(op);
	}

	public function response(response:Int):Int {
		return response + 1;
	}
}
