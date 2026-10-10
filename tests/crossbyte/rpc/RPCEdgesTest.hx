package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.net.Reason;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import utest.Assert;

/**
	Each way a call can go wrong, as its caller meets it: through a future
	and through a receiver, each ends in a typed result (`RPCResponse.failure`
	and `RPCReceiver.onFailure` alike, an `RPCFailure`), and the session goes
	on answering where its connection is still up.

	Before, a future's caller could tell a cancelled or stopped call only by
	the text of its `error`, whose words were private to the session: its
	`cause` was null.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.RPCCommands)
class RPCEdgesTest extends utest.Test {
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testAHandlerRefusingIsRefusedWordForWord():Void {
		final edge = new Edge();
		final response = edge.commands.refuse();
		edge.commands.refuseThen(edge.told);
		Assert.isTrue(Type.enumEq(RPCFailure.Refused("No room."), response.failure), "a refusal's failure was " + response.failure);
		Assert.isTrue(Std.isOfType(response.cause, RPCError));
		Assert.isTrue(Type.enumEq(RPCFailure.Refused("No room."), edge.told.failures[0]));
		edge.stillAnswers();
	}

	public function testAHandlerThrowingIsAnInternalErrorToItsCaller():Void {
		final edge = new Edge();
		final response = edge.commands.boom();
		Assert.isTrue(Type.enumEq(RPCFailure.HandlerFailed, response.failure));
		Assert.equals(1, edge.reported.length, "the throw was not reported where it happened");
		Assert.stringContains("boom", edge.reported[0]);
		edge.stillAnswers();
	}

	public function testAMethodTheOtherSideHasNotGotIsUnknownThere():Void {
		final edge = new Edge();
		final response = edge.commands.missing();
		edge.commands.missingThen(edge.told);
		Assert.isTrue(Type.enumEq(RPCFailure.UnknownMethod, response.failure));
		Assert.isTrue(Type.enumEq(RPCFailure.UnknownMethod, edge.told.failures[0]));
		edge.stillAnswers();
	}

	public function testAHelloOfAnotherVersionIsHeardAndRefusesNothing():Void {
		final edge = new Edge();
		final hello = new ByteArrayOutput(32);
		hello.writeByte(RPCWire.FLAG_RESPONSE);
		hello.writeInt(RPCWire.HELLO_OP);
		hello.writeVarUInt(0);
		hello.writeVarUInt(2);
		hello.writeVarUInt(0);
		hello.writeInt(0);
		hello.writeInt(0);
		edge.link.server.send(frameOf(hello));
		Assert.equals(2, edge.client.peerVersion);
		Assert.equals(0, edge.client.peerCapabilities, "a capability the later peer did not declare");
		edge.stillAnswers();
	}

	public function testAPeerThatGoesMidCallFailsTheCallWithItsReason():Void {
		final edge = new Edge();
		final response = edge.commands.slow("a");
		edge.commands.slowThen("b", edge.told);
		edge.link.client.peerLeft();
		Assert.isTrue(Type.enumEq(RPCFailure.Disconnected(Reason.Closed), response.failure), "a call whose peer went failed as " + response.failure);
		Assert.isTrue(Type.enumEq(RPCFailure.Disconnected(Reason.Closed), edge.told.failures[0]));
		// The connection is gone, so a call now fails as it is made, saying why.
		Assert.isTrue(Type.enumEq(RPCFailure.Disconnected(Reason.Closed), edge.commands.quick(1).failure));
	}

	public function testADeadlinePassingWithTheAnswerInFlightTimesOut():Void {
		final edge = new Edge();
		final response = edge.commands.withTimeout(250).slow("c");
		edge.commands.withTimeout(250).slowThen("d", edge.told);
		pump(0.5);
		edge.handler.pending.get("c").complete("late");
		edge.handler.pending.get("d").complete("late");
		Assert.isTrue(Type.enumEq(RPCFailure.TimedOut, response.failure));
		Assert.isTrue(Std.isOfType(response.cause, RPCTimeoutError));
		Assert.isTrue(Type.enumEq(RPCFailure.TimedOut, edge.told.failures[0]));
		Assert.same([], edge.told.answers, "an answer arriving after its deadline was taken");
		edge.stillAnswers();
	}

	public function testACancelledCallIsCancelledEitherWay():Void {
		final edge = new Edge();
		final response = edge.commands.slow("e");
		final call:Int = edge.commands.slowThen("f", edge.told);
		Assert.isTrue(edge.client.cancelCall(response.requestId));
		Assert.isTrue(edge.client.cancelCall(call));
		Assert.isTrue(Type.enumEq(RPCFailure.Cancelled, response.failure), "a cancelled future's failure was " + response.failure);
		Assert.isTrue(Type.enumEq(RPCFailure.Cancelled, edge.told.failures[0]));
		edge.stillAnswers();
	}

	public function testAStoppedSessionsCallsAreStopped():Void {
		final edge = new Edge();
		final response = edge.commands.slow("g");
		edge.client.stop();
		Assert.isTrue(Type.enumEq(RPCFailure.Stopped, response.failure), "a stopped call's failure was " + response.failure);
		edge.stillAnswers();
	}

	public function testArgumentsThatDoNotReadAreUnreadableThere():Void {
		final edge = new Edge();
		// A call to `quick(i32):i32` whose Int is cut short.
		final requestId:Int = edge.commands.__nextRequestId();
		final waiting = edge.commands.__createResponse(RPCOps.opOf("quick(i32):i32"), requestId);
		final call = new ByteArrayOutput(32);
		call.writeByte(RPCWire.FLAG_REQUEST);
		call.writeInt(RPCOps.opOf("quick(i32):i32"));
		call.writeVarUInt(requestId);
		call.writeByte(7);
		edge.link.client.send(frameOf(call));
		Assert.isTrue(Type.enumEq(RPCFailure.UnreadableArguments, (cast waiting : RPCResponse<Int>).failure));
		edge.stillAnswers();
	}

	public function testAFrameWhoseLengthCannotBeTrustedEndsTheConnection():Void {
		final edge = new Edge();
		final response = edge.commands.slow("h");
		final garbage = new ByteArray();
		garbage.writeInt(-5);
		garbage.writeInt(0);
		garbage.writeInt(0);
		garbage.position = 0;
		edge.link.server.send(garbage);
		switch (response.failure) {
			case Disconnected(Error(why)):
				Assert.stringContains("Invalid RPC frame length", why);
			case other:
				Assert.fail("a call on a connection whose framing was lost failed as " + other);
		}
	}

	public function testAnArgumentOverTheFrameLimitIsUnsent():Void {
		final edge = new Edge();
		edge.client.maxFrameLength = 64;
		final big = StringTools.lpad("", "x", 100);
		final response = edge.commands.echo(big);
		edge.commands.echoThen(big, edge.told);
		switch (response.failure) {
			case Unsent(_):
				Assert.isTrue(Std.isOfType(response.cause, ArgumentError));
			case other:
				Assert.fail("an oversized call failed as " + other);
		}
		switch (edge.told.failures[0]) {
			case Unsent(_):
				Assert.pass();
			case other:
				Assert.fail("an oversized receiver call failed as " + other);
		}
		edge.stillAnswers();
	}

	public function testAnAnsweredCallHasNoFailure():Void {
		final edge = new Edge();
		Assert.isNull(edge.commands.quick(3).failure);
		Assert.isNull(edge.commands.slow("i").failure, "a call still waiting has a failure");
	}

	private static function frameOf(payload:ByteArrayOutput):ByteArray {
		final frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}

	private static function pump(seconds:Float):Void {
		final runtime = CrossByte.current();
		var elapsed = 0.0;
		while (elapsed < seconds) {
			runtime.pump(0.25, 0);
			elapsed += 0.25;
		}
	}
}

private class Edge {
	public final link = LinkedConnection.pair();
	public final commands = new EdgeCommands();
	public final handler = new EdgeHandler();
	public final told = new EdgeReceiver();
	public final client:RPCSession<EdgeCommands>;
	public final server:RPCSession<Dynamic>;
	public final reported:Array<String> = [];

	public function new() {
		client = new RPCSession<EdgeCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));
	}

	/** The session answers a call after whatever went wrong. **/
	public function stillAnswers(?pos:haxe.PosInfos):Void {
		Assert.equals(5, commands.quick(5).result, "the session did not answer after it", pos);
	}
}

private class EdgeCommands extends RPCCommands {
	public function new() {}

	@:rpc public function refuse():RPCResponse<Int> {}

	@:rpc public function boom():RPCResponse<Int> {}

	@:rpc public function missing():RPCResponse<Int> {}

	@:rpc public function slow(key:String):RPCResponse<String> {}

	@:rpc public function quick(value:Int):RPCResponse<Int> {}

	@:rpc public function echo(text:String):RPCResponse<String> {}
}

private class EdgeHandler extends RPCHandler {
	public final pending = new Map<String, Completer<String>>();

	public function new() {}

	@:rpc public function refuse():Int {
		throw new RPCError("No room.");
	}

	@:rpc public function boom():Int {
		throw "boom";
	}

	@:rpc public function slow(key:String):Future<String> {
		final completer = new Completer<String>();
		pending.set(key, completer);
		return completer.future;
	}

	@:rpc public function quick(value:Int):Int {
		return value;
	}

	@:rpc public function echo(text:String):String {
		return text;
	}
}

private class EdgeReceiver implements RPCIntReceiver implements RPCStringReceiver {
	public final failures:Array<RPCFailure> = [];
	public final answers:Array<String> = [];

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		answers.push(Std.string(value));
	}

	public function onString(call:Int, value:String):Void {
		answers.push(value);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		failures.push(failure);
	}
}
