package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import utest.Assert;

/**
	Each refusal the protocol makes has its own `RPCFailure`, so a caller
	switches on what refused its call rather than comparing its message with
	`RPCError`'s: on a future (`RPCResponse.failure`) and on a receiver alike,
	on both lanes, and passed on by a handler that answers with a refused call.

	Before, every one of them was `Refused(message)`, the message one of
	`RPCError`'s constants, and a handler refusing with one of those words was
	the same as the session refusing.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.RPCCommands)
class RPCRefusalTest extends utest.Test {
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testAMethodTheOtherSideHasNotGotIsUnknownMethod():Void {
		final pair = new Pair();
		final response = pair.commands.missing();
		pair.commands.missingThen(pair.told);
		Assert.isTrue(Type.enumEq(UnknownMethod, response.failure), "an unknown method's failure was " + response.failure);
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, response.error);
		Assert.isTrue(Std.isOfType(response.cause, RPCError));
		Assert.isTrue(Type.enumEq(UnknownMethod, pair.told.failures[0]), "a receiver was told " + pair.told.failures[0]);
		pair.stillAnswers();
	}

	public function testArgumentsThatDoNotReadAreUnreadableArguments():Void {
		final pair = new Pair();
		// A call to `quick(i32):i32` whose Int is cut short.
		final requestId:Int = pair.commands.__nextRequestId();
		final waiting:RPCResponse<Int> = cast pair.commands.__createResponse(RPCOps.opOf("quick(i32):i32"), requestId);
		final call = new ByteArrayOutput(32);
		call.writeByte(RPCWire.FLAG_REQUEST);
		call.writeInt(RPCOps.opOf("quick(i32):i32"));
		call.writeVarUInt(requestId);
		call.writeByte(7);
		pair.link.client.send(frameOf(call));
		Assert.isTrue(Type.enumEq(UnreadableArguments, waiting.failure), "unreadable arguments' failure was " + waiting.failure);
		Assert.equals(RPCError.UNREADABLE_MESSAGE, waiting.error);
		pair.stillAnswers();
	}

	public function testACallPastTheCallsWaitingIsBusy():Void {
		final pair = new Pair();
		pair.server.maxCallsWaiting = 1;
		final first = pair.commands.slow("a");
		final second = pair.commands.slow("b");
		pair.commands.slowThen("c", pair.told);
		Assert.isFalse(first.completed);
		Assert.isTrue(Type.enumEq(Busy, second.failure), "a call past the limit failed as " + second.failure);
		Assert.equals(RPCError.BUSY_MESSAGE, second.error);
		Assert.isTrue(Type.enumEq(Busy, pair.told.failures[0]));
		pair.handler.pending.get("a").complete("done");
		Assert.equals("done", first.result);
		pair.stillAnswers();
	}

	public function testACallToASessionWithNoHandlerIsNoHandler():Void {
		final link = LinkedConnection.pair();
		final commands = new RefusalCommands();
		final told = new Told();
		final client = new RPCSession<RefusalCommands>(link.client, commands);
		final server = new RPCSession(link.server, new RefusalCommands());
		final response = commands.quick(1);
		commands.quickThen(2, told);
		Assert.isTrue(Type.enumEq(NoHandler, response.failure), "a call with nothing to answer it failed as " + response.failure);
		Assert.equals(RPCError.NO_HANDLER_MESSAGE, response.error);
		Assert.isTrue(Type.enumEq(NoHandler, told.failures[0]));
	}

	public function testAHandlerOutOfTimeIsHandlerTimedOut():Void {
		final pair = new Pair();
		pair.server.handlerTimeout = 200;
		final response = pair.commands.slow("d");
		pair.commands.slowThen("e", pair.told);
		pump(0.5);
		Assert.isTrue(Type.enumEq(HandlerTimedOut, response.failure), "a handler out of time failed its caller as " + response.failure);
		Assert.equals(RPCError.TIMEOUT_MESSAGE, response.error);
		Assert.isFalse(Std.isOfType(response.cause, RPCTimeoutError), "the caller's own deadline did not pass");
		Assert.isTrue(Type.enumEq(HandlerTimedOut, pair.told.failures[0]));
		pair.stillAnswers();
	}

	public function testAHandlerThrowingIsHandlerFailed():Void {
		final pair = new Pair();
		final response = pair.commands.boom();
		pair.commands.boomThen(pair.told);
		Assert.isTrue(Type.enumEq(HandlerFailed, response.failure), "a handler throwing failed its caller as " + response.failure);
		Assert.equals(RPCError.INTERNAL_MESSAGE, response.error);
		Assert.isTrue(Type.enumEq(HandlerFailed, pair.told.failures[0]));
		Assert.equals(2, pair.reported.length, "the throws were not reported where they happened");
		pair.stillAnswers();
	}

	public function testAHandlerRefusingIsRefusedWithItsWords():Void {
		final pair = new Pair();
		final response = pair.commands.refuse("No room.");
		pair.commands.refuseThen("No room.", pair.told);
		Assert.isTrue(Type.enumEq(Refused("No room."), response.failure));
		Assert.isTrue(Type.enumEq(Refused("No room."), pair.told.failures[0]));
		pair.stillAnswers();
	}

	public function testAHandlerRefusingWithTheProtocolsWordsIsStillRefused():Void {
		// What refused it decides, not what it says: a handler saying it is
		// busy is the handler's refusal.
		final pair = new Pair();
		final response = pair.commands.refuse(RPCError.BUSY_MESSAGE);
		pair.commands.refuseThen(RPCError.UNKNOWN_METHOD_MESSAGE, pair.told);
		Assert.isTrue(Type.enumEq(Refused(RPCError.BUSY_MESSAGE), response.failure), "a handler's refusal failed as " + response.failure);
		Assert.isTrue(Type.enumEq(Refused(RPCError.UNKNOWN_METHOD_MESSAGE), pair.told.failures[0]));
	}

	public function testABeforeCallRefusalIsRefused():Void {
		final pair = new Pair();
		pair.handler.refuseAll = "Not now.";
		final response = pair.commands.quick(1);
		Assert.isTrue(Type.enumEq(Refused("Not now."), response.failure), "beforeCall's refusal failed as " + response.failure);
	}

	public function testAHandlerAnsweringWithARefusedCallPassesTheRefusalOn():Void {
		// client -> hub -> backend, whose session has its limit reached: the
		// hub answers with the backend's answer, and its caller is told Busy.
		final backendLink = LinkedConnection.pair();
		final backendHandler = new RefusalHandler();
		final backendSession = new RPCSession(backendLink.server, null, backendHandler);
		backendSession.maxCallsWaiting = 1;
		final toBackend = new RefusalCommands();
		final backendClient = new RPCSession<RefusalCommands>(backendLink.client, toBackend);
		final hub = new RefusalHandler();
		hub.forwardTo = toBackend;
		final link = LinkedConnection.pair();
		final commands = new RefusalCommands();
		final client = new RPCSession<RefusalCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, hub);

		final holding = toBackend.slow("hold");
		final forwarded = commands.forward("x");
		Assert.isFalse(holding.completed);
		Assert.isTrue(Type.enumEq(Busy, forwarded.failure), "a forwarded refusal failed as " + forwarded.failure);
		Assert.equals(RPCError.BUSY_MESSAGE, forwarded.error);
	}

	public function testRuntimeRefusalsAreTypedToo():Void {
		final pair = new Pair();
		final unknown:RPCResponse<Dynamic> = pair.client.request(900, [1]);
		Assert.isTrue(Type.enumEq(UnknownMethod, unknown.failure), "an unregistered runtime op failed as " + unknown.failure);

		pair.server.register(901, args -> throw "runtime boom");
		final failed:RPCResponse<Dynamic> = pair.client.request(901, []);
		Assert.isTrue(Type.enumEq(HandlerFailed, failed.failure), "a runtime handler throwing failed as " + failed.failure);

		pair.server.register(902, args -> throw new RPCError("Nope."));
		final refused:RPCResponse<Dynamic> = pair.client.request(902, []);
		Assert.isTrue(Type.enumEq(Refused("Nope."), refused.failure));

		final waiting = new Completer<Dynamic>();
		pair.server.maxCallsWaiting = 1;
		pair.server.register(903, args -> waiting.future);
		final held:RPCResponse<Dynamic> = pair.client.request(903, []);
		final busy:RPCResponse<Dynamic> = pair.client.request(903, []);
		Assert.isFalse(held.completed);
		Assert.isTrue(Type.enumEq(Busy, busy.failure), "a runtime call past the limit failed as " + busy.failure);
		waiting.complete(1);

		pair.server.beforeRuntimeCall = (op, requestId, size) -> op == 904 ? new RPCError("Closed.") : null;
		final closed:RPCResponse<Dynamic> = pair.client.request(904, []);
		Assert.isTrue(Type.enumEq(Refused("Closed."), closed.failure));
	}

	public function testAnErrorAnswerWithNoCodeIsTheHandlersRefusal():Void {
		// As a peer from before the codes frames one, and as a later version's
		// code this one does not know reads: the handler's own, with its words.
		final pair = new Pair();
		for (code in [-1, 99]) {
			final requestId:Int = pair.commands.__nextRequestId();
			final waiting:RPCResponse<Int> = cast pair.commands.__createResponse(RPCOps.opOf("quick(i32):i32"), requestId);
			final answer = new ByteArrayOutput(64);
			answer.writeByte(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR);
			answer.writeInt(RPCOps.opOf("quick(i32):i32"));
			answer.writeVarUInt(requestId);
			answer.writeVarUTF(RPCError.BUSY_MESSAGE);
			if (code >= 0) {
				answer.writeVarUInt(code);
			}
			pair.link.server.send(frameOf(answer));
			Assert.isTrue(Type.enumEq(Refused(RPCError.BUSY_MESSAGE), waiting.failure), 'code $code failed as ' + waiting.failure);
		}
		pair.stillAnswers();
	}

	public function testAnErrorAnswersCodeIsReadWithinItsFrame():Void {
		// A message whose length runs past its frame is an answer that does
		// not read, not a code taken from the next frame.
		final pair = new Pair();
		final requestId:Int = pair.commands.__nextRequestId();
		final waiting:RPCResponse<Int> = cast pair.commands.__createResponse(RPCOps.opOf("quick(i32):i32"), requestId);
		final answer = new ByteArrayOutput(64);
		answer.writeByte(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR);
		answer.writeInt(RPCOps.opOf("quick(i32):i32"));
		answer.writeVarUInt(requestId);
		answer.writeVarUInt(40);
		answer.writeByte(65);
		pair.link.server.send(frameOf(answer));
		switch (waiting.failure) {
			case Unreadable(_):
				Assert.pass();
			case other:
				Assert.fail("a message past its frame failed as " + other);
		}
		pair.stillAnswers();
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
			runtime.pump(0.05, 0);
			elapsed += 0.05;
		}
	}
}

private class Pair {
	public final link = LinkedConnection.pair();
	public final commands = new RefusalCommands();
	public final handler = new RefusalHandler();
	public final told = new Told();
	public final client:RPCSession<RefusalCommands>;
	public final server:RPCSession<Dynamic>;
	public final reported:Array<String> = [];

	public function new() {
		client = new RPCSession<RefusalCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));
	}

	public function stillAnswers(?pos:haxe.PosInfos):Void {
		Assert.equals(5, commands.quick(5).result, "the session did not answer after it", pos);
	}
}

private class RefusalCommands extends RPCCommands {
	public function new() {}

	@:rpc public function refuse(words:String):RPCResponse<Int> {}

	@:rpc public function boom():RPCResponse<Int> {}

	@:rpc public function missing():RPCResponse<Int> {}

	@:rpc public function slow(key:String):RPCResponse<String> {}

	@:rpc public function quick(value:Int):RPCResponse<Int> {}

	@:rpc public function forward(key:String):RPCResponse<String> {}
}

private class RefusalHandler extends RPCHandler {
	public final pending = new Map<String, Completer<String>>();
	public var refuseAll:Null<String> = null;
	public var forwardTo:Null<RefusalCommands> = null;

	public function new() {}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		return refuseAll != null ? new RPCError(refuseAll) : null;
	}

	@:rpc public function refuse(words:String):Int {
		throw new RPCError(words);
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

	@:rpc public function forward(key:String):Future<String> {
		return forwardTo.slow(key);
	}
}

private class Told implements RPCIntReceiver implements RPCStringReceiver {
	public final failures:Array<RPCFailure> = [];

	public function new() {}

	public function onInt(call:Int, value:Int):Void {}

	public function onString(call:Int, value:String):Void {}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		failures.push(failure);
	}
}
