package crossbyte.rpc;

import crossbyte.errors.IllegalOperationError;
import crossbyte.net.NetConnection;
import crossbyte.net.Reason;
import utest.Assert;

/**
	Calls that cannot go fail at once; none is left waiting on an answer
	that cannot come.

	A request made after its connection has ended fails, over local IPC,
	whose send reports a closed connection to `onError` rather than
	throwing, and over TCP, where the send would otherwise throw out of the
	call and leave its response waiting. Commands with no session must not
	dereference a null connection (on hxcpp in release, a crash). And an
	application's own connection, wrapped as a `NetConnection` a second time
	after a session was made on it, keeps the session's hold on its close,
	so the calls waiting on it fail when it does.
**/
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc.RPCSession)
class RPCUnsendableCallTest extends utest.Test {
	public function testARequestOnAConnectionThatHasEndedFailsAtOnce():Void {
		var link = LinkedConnection.pair();
		var commands = new SendCommands();
		var session = new RPCSession<SendCommands>(link.client, commands);
		link.client.close();
		var sentBefore = link.client.sent;

		var compiled = commands.join("lobby");
		var runtime:RPCResponse<Dynamic> = session.request(10, []);

		for (call in [compiled, cast runtime]) {
			Assert.isTrue(call.completed, "a call on an ended connection was left waiting");
			Assert.stringContains("RPC connection closed", call.error);
			Assert.isTrue(Type.enumEq(Reason.Closed, call.cause), "the cause is not the reason it ended: " + call.cause);
		}
		Assert.equals(sentBefore, link.client.sent, "a call was sent on a connection that had ended");
		Assert.isNull(commands.__pendingResponse);
		Assert.isNull(session.__runtimePendingResponse);
	}

	public function testAOneWayCallOnAConnectionThatHasEndedIsDropped():Void {
		var link = LinkedConnection.pair();
		link.client.strictSend = true;
		var commands = new SendCommands();
		var session = new RPCSession<SendCommands>(link.client, commands);
		link.client.close();

		commands.notice("gone");
		session.call(11, []);

		Assert.pass("a one-way call on an ended connection threw");
	}

	public function testARequestWhoseSendThrowsFailsAtOnce():Void {
		var link = LinkedConnection.pair();
		var commands = new SendCommands();
		var session = new RPCSession<SendCommands>(link.client, commands);
		link.client.failSends = true;

		var compiled = commands.join("lobby");
		var runtime:RPCResponse<Dynamic> = session.request(12, []);

		for (call in [compiled, cast runtime]) {
			Assert.isTrue(call.completed, "a call whose send threw was left waiting");
			Assert.stringContains("could not be sent", call.error);
			Assert.equals("send failed", call.cause);
		}
		Assert.isNull(commands.__pendingResponse, "the call is still waiting under its id");
		Assert.isNull(session.__runtimePendingResponse);
	}

	public function testCommandsWithNoSessionFailRatherThanCrash():Void {
		var commands = new SendCommands();

		var request = commands.join("lobby");
		Assert.isTrue(request.completed);
		Assert.isTrue(Std.isOfType(request.cause, IllegalOperationError), "not refused for having no session: " + request.error);
		Assert.raises(() -> commands.notice("nobody"), IllegalOperationError);
	}

	public function testAnArgumentThatCannotBeSentLeavesNothingWaiting():Void {
		var link = LinkedConnection.pair();
		var session = new RPCSession(link.client);
		// An object: the runtime lane carries null, Bool, Int, Float, String
		// and Bytes.
		var args:Array<Dynamic> = [{value: 1}];

		Assert.raises(() -> session.request(13, args));

		Assert.isNull(session.__runtimePendingResponse, "a call that was never sent is waiting");
		Assert.isNull(session.__runtimePendingResponses);
	}

	public function testWrappingAConnectionAgainKeepsTheSessionsHoldOnItsClose():Void {
		var link = LinkedConnection.pair();
		var commands = new SendCommands();
		var session = new RPCSession<SendCommands>(link.client, commands);
		var waiting = commands.join("lobby");
		var heard = false;

		// A second NetConnection of the same connection, as an application
		// setting its callback naturally makes.
		(link.client : NetConnection).onClose = _ -> heard = true;
		link.client.close();

		Assert.isTrue(heard, "the application's onClose did not run");
		Assert.isTrue(waiting.completed, "the session did not hear the connection end");
	}

	public function testAnAnswerForAConnectionItsHandlerClosedIsDropped():Void {
		var link = LinkedConnection.pair();
		link.server.strictSend = true;
		var commands = new SendCommands();
		var client = new RPCSession<SendCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new ClosingHandler());
		var reported:Array<String> = [];
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));

		commands.leave("lobby");

		Assert.same([], reported, "answering a connection its handler had closed was taken for the handler failing");
	}
}

private class SendCommands extends RPCCommands {
	public function new() {}

	@:rpc public function join(room:String):RPCResponse<Int> {}

	@:rpc public function notice(text:String):Void {}

	@:rpc public function leave(room:String):RPCResponse<Bool> {}
}

private class ClosingHandler extends RPCHandler {
	public function new() {}

	@:rpc public function join(room:String):Int {
		return 1;
	}

	@:rpc public function notice(text:String):Void {}

	@:rpc public function leave(room:String):Bool {
		session.connection.close();
		return true;
	}
}
