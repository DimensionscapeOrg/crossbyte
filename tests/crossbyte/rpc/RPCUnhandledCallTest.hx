package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.Bytes;
import utest.Assert;

/**
	Calls the other side cannot take: none of them may end the connection
	or leave a caller waiting on one that is up.

	A runtime call to a session with no runtime handlers gets the error
	answer the guide promises, rather than ending that session's connection
	with the frame taken for garbage by the reader for a compiled handler.
	A compiled request to a session with no handler is answered, not
	dropped with its caller left waiting on a connection that stays up. A
	frame over the limit is refused as it is sent, not sent to end the
	connection on the other side and fail every call waiting on it; and the
	limit is a setting.
**/
class RPCUnhandledCallTest extends utest.Test {
	public function testARuntimeCallToASessionWithNoRuntimeHandlersIsAnswered():Void {
		var fixture = new Fixture();

		var runtime:RPCResponse<Dynamic> = fixture.client.request(100, ["hello"]);
		Assert.isTrue(runtime.completed, "the runtime call was never answered");
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, runtime.error);
		fixture.client.call(101, ["one-way"]);

		Assert.same([], fixture.serverEnded, "a runtime call ended the connection");
		Assert.equals(1, fixture.commands.join("lobby").result, "a compiled call after it was not answered");
	}

	public function testARequestToASessionWithNoHandlerIsAnswered():Void {
		// The server calls its client, whose session has commands and no
		// handler: a server pushing to a client that answers nothing.
		var link = LinkedConnection.pair();
		var clientSide = new RPCSession<UnhandledCommands>(link.client, new UnhandledCommands());
		var serverCommands = new UnhandledCommands();
		var serverSide = new RPCSession<UnhandledCommands>(link.server, serverCommands);
		var ended = endingOf(link.client);

		var asked = serverCommands.join("lobby");
		serverCommands.notice("one-way, and dropped");

		Assert.isTrue(asked.completed, "the call was left waiting on a connection that is up");
		Assert.equals(RPCError.NO_HANDLER_MESSAGE, asked.error);
		Assert.isTrue(Std.isOfType(asked.cause, RPCError));
		Assert.isFalse(ended.value, "the connection ended");
	}

	public function testARuntimeOnlySessionAnswersACompiledRequest():Void {
		var link = LinkedConnection.pair();
		var runtimeOnly = new RPCSession(link.server);
		runtimeOnly.register(900, args -> null);
		var commands = new UnhandledCommands();
		var client = new RPCSession<UnhandledCommands>(link.client, commands);

		Assert.equals(RPCError.NO_HANDLER_MESSAGE, commands.join("lobby").error);
	}

	public function testACallOverTheFrameLimitFailsBeforeItIsSent():Void {
		var fixture = new Fixture();
		var small = fixture.commands.store(Bytes.alloc(16));
		Assert.equals(16, small.result);
		var sentBefore = fixture.link.client.sent;

		var big = fixture.commands.store(Bytes.alloc(RPCHandler.MAX_FRAME_LEN + 1));

		Assert.isTrue(big.completed, "an oversized call was left waiting");
		Assert.isTrue(Std.isOfType(big.cause, ArgumentError), "not refused as too large: " + big.error);
		Assert.stringContains("frame limit", big.error);
		Assert.equals(sentBefore, fixture.link.client.sent, "an oversized call was sent");
		Assert.same([], fixture.serverEnded, "the other side's connection ended");
		Assert.equals(32, fixture.commands.store(Bytes.alloc(32)).result);
	}

	public function testAOneWayCallOverTheFrameLimitThrows():Void {
		var fixture = new Fixture();
		var sentBefore = fixture.link.client.sent;

		Assert.raises(() -> fixture.commands.drop(Bytes.alloc(RPCHandler.MAX_FRAME_LEN + 1)), ArgumentError);
		Assert.raises(() -> fixture.client.call(102, [Bytes.alloc(RPCHandler.MAX_FRAME_LEN + 1)]), ArgumentError);

		Assert.equals(sentBefore, fixture.link.client.sent, "an oversized call was sent");
		Assert.same([], fixture.serverEnded);
	}

	public function testARuntimeRequestOverTheFrameLimitFailsBeforeItIsSent():Void {
		var fixture = new Fixture();
		var big:RPCResponse<Dynamic> = fixture.client.request(103, [Bytes.alloc(RPCHandler.MAX_FRAME_LEN + 1)]);
		Assert.isTrue(Std.isOfType(big.cause, ArgumentError), "not refused as too large: " + big.error);
		Assert.same([], fixture.serverEnded);
	}

	public function testAnAnswerOverTheFrameLimitIsNotSent():Void {
		// Refused as it is sent, not sent for the receiving side to end its
		// connection over.
		var fixture = new Fixture();
		var reported:Array<String> = [];
		fixture.server.onHandlerError = (op, method, error) -> reported.push(method);
		var clientEnded = endingOf(fixture.link.client);

		var answer = fixture.commands.blob(RPCHandler.MAX_FRAME_LEN + 1);

		// Its caller is told it was too large, which says which limit.
		Assert.isTrue(Type.enumEq(RPCFailure.TooLarge, answer.failure), "an oversized answer was sent, or never answered: " + answer.failure);
		Assert.stringContains("frame limit", answer.error);
		Assert.same(["blob"], reported, "the handler's oversized answer was not reported");
		Assert.isFalse(clientEnded.value, "the caller's connection ended");
		Assert.equals(4, fixture.commands.blob(4).result.length);
	}

	public function testTheFrameLimitIsTheSessions():Void {
		var fixture = new Fixture();
		fixture.client.maxFrameLength = 1024;
		var refused = fixture.commands.store(Bytes.alloc(2048));
		Assert.isTrue(Std.isOfType(refused.cause, ArgumentError), "the session's own limit was not the one kept");

		// The receiving side refuses a frame past its limit, and the
		// connection goes on.
		fixture.client.maxFrameLength = 0;
		fixture.server.maxFrameLength = 1024;
		var past = fixture.commands.store(Bytes.alloc(2048));
		Assert.isTrue(Type.enumEq(RPCFailure.TooLarge, past.failure), "a frame past the reader's limit failed as " + past.failure);
		Assert.stringContains("maxFrameLength", past.error);
		Assert.same([], fixture.serverEnded, "a frame past the reader's limit ended its connection");
		Assert.equals(4, fixture.commands.blob(4).result.length);
	}

	public function testAFrameWithFlagsNoFrameHasIsPassedOver():Void {
		// Flags that are neither a call nor an answer (an error that answers
		// nothing) are not taken for a one-way call with the method run, and do
		// not end the connection. A kind of frame a later release adds is
		// passed over, the session told.
		var fixture = new Fixture();
		var passed:Array<String> = [];
		fixture.server.onUnreadableFrame = (op, requestId, reason) -> passed.push(reason);
		var payload = new crossbyte.io.ByteArrayOutput(32);
		payload.writeByte(RPCWire.FLAG_ERROR);
		payload.writeInt(crossbyte.rpc._internal.RPCOps.opOf("notice(utf8)"));
		payload.writeVarUTF("text");
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		fixture.link.client.send(frame);
		Assert.equals(0, fixture.handler.notices, "a frame that is neither a call nor an answer ran a method");
		Assert.same([], fixture.serverEnded, "a frame that is neither a call nor an answer ended the connection");
		Assert.same(["a frame of a kind this session does not know, flags 0x04"], passed);
		Assert.equals(1, fixture.commands.join("lobby").result, "the connection did not answer after it");
	}

	public function testACallForAMethodThisSideHasNotGotIsAnsweredAndTheConnectionStays():Void {
		// A rolling deploy: a client built with a method its server does not
		// have yet. The request is answered saying so and the one-way call is
		// dropped, the server told of both; neither ends the connection, nor
		// fails every call waiting on it.
		var fixture = new Fixture();
		var passed:Array<String> = [];
		fixture.server.onUnreadableFrame = (op, requestId, reason) -> passed.push(requestId + " " + reason);
		var newer = new NewerCommands();
		var link = LinkedConnection.pair();
		var client = new RPCSession<NewerCommands>(link.client, newer);
		var server = new RPCSession(link.server, null, fixture.handler);
		server.onUnreadableFrame = fixture.server.onUnreadableFrame;
		var ended = endingOf(link.server);

		var asked = newer.trade("sword");
		newer.wave();

		Assert.isTrue(asked.completed, "a call for a method the server has not got was left waiting");
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, asked.error);
		Assert.isTrue(Std.isOfType(asked.cause, RPCError), "not answered as the server's refusal: " + asked.cause);
		Assert.isFalse(ended.value, "a call for a method the server has not got ended the connection");
		Assert.equals(2, passed.length);
		Assert.stringContains(asked.requestId + " no method answers op 0x", passed[0]);
		Assert.stringContains("0 no method answers op 0x", passed[1]);
		// The methods both have still work.
		Assert.equals(1, newer.join("lobby").result);
	}

	/** Whether `connection` has been closed or has failed. **/
	private static function endingOf(connection:LinkedConnection):{value:Bool} {
		var ended = {value: false};
		connection.onClose = _ -> ended.value = true;
		connection.onError = _ -> ended.value = true;
		return ended;
	}
}

private class Fixture {
	public final link = LinkedConnection.pair();
	public final commands = new UnhandledCommands();
	public final handler = new UnhandledHandler();
	public final client:RPCSession<UnhandledCommands>;
	public final server:RPCSession<Dynamic>;
	public final serverEnded:Array<String> = [];

	public function new() {
		client = new RPCSession<UnhandledCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
		server.connection.onClose = reason -> serverEnded.push(Std.string(reason));
		server.connection.onError = reason -> serverEnded.push(Std.string(reason));
	}
}

private class UnhandledCommands extends RPCCommands {
	public function new() {}

	@:rpc public function join(room:String):RPCResponse<Int> {}

	@:rpc public function notice(text:String):Void {}

	@:rpc public function store(blob:Bytes):RPCResponse<Int> {}

	@:rpc public function drop(blob:Bytes):Void {}

	@:rpc public function blob(size:Int):RPCResponse<Bytes> {}
}

/** A client built after the server: two methods the server has not got. **/
private class NewerCommands extends RPCCommands {
	public function new() {}

	@:rpc public function join(room:String):RPCResponse<Int> {}

	@:rpc public function trade(item:String):RPCResponse<Int> {}

	@:rpc public function wave():Void {}
}

private class UnhandledHandler extends RPCHandler {
	public var notices:Int = 0;

	public function new() {}

	@:rpc public function join(room:String):Int {
		return 1;
	}

	@:rpc public function notice(text:String):Void {
		notices++;
	}

	@:rpc public function store(blob:Bytes):Int {
		return blob.length;
	}

	@:rpc public function drop(blob:Bytes):Void {}

	@:rpc public function blob(size:Int):Bytes {
		return Bytes.alloc(size);
	}
}
