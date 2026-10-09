package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.rpc._internal.RPCWire;
import utest.Assert;

/**
	A caller's deadline and its cancellations reach the handler answering
	it, as gRPC's do: a handler can read when its caller stops waiting, and
	one answering later learns that its caller has stopped, so it can stop
	too, rather than finish work nobody will read and hold its place among
	the calls waiting until its own `handlerTimeout`.

	Before, nothing of either crossed the wire: a caller that cancelled or
	timed out simply dropped the answer when it came.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.LinkedConnection)
class RPCCallControlTest extends utest.Test {
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testAHandlerReadsTheDeadlineItsCallerGave():Void {
		final fixture = new ControlFixture();
		fixture.client.callTimeout = 5000;
		Assert.equals(4, fixture.commands.measure().result, "the call was not answered");
		final seen = fixture.handler.seen[0];
		Assert.isTrue(seen.deadline > 0, "the caller's deadline did not arrive");
		Assert.isTrue(seen.timeLeft > 4000 && seen.timeLeft <= 5000, "a deadline of 5,000 ms arrived as " + seen.timeLeft + " ms left");

		fixture.commands.withTimeout(0).measure();
		Assert.equals(0.0, fixture.handler.seen[1].deadline, "a call with no deadline arrived with one");
		Assert.equals(-1, fixture.handler.seen[1].timeLeft);

		fixture.commands.withTimeout(250).measure();
		Assert.isTrue(fixture.handler.seen[2].timeLeft <= 250 && fixture.handler.seen[2].timeLeft > 0);
		Assert.isNull(fixture.handler.currentCall, "a call was left current between calls");
	}

	public function testACallerCancellingTellsAHandlerAnsweringLater():Void {
		final fixture = new ControlFixture();
		final response = fixture.commands.slow("a");
		final call = fixture.handler.calls.get("a");
		Assert.notNull(call, "the handler did not see its call");
		var told:Int = 0;
		call.onCancel = () -> told++;
		Assert.equals(1, fixture.server.callsWaiting);
		final sentBefore:Int = fixture.link.server.sent;

		Assert.isTrue(fixture.client.cancelCall(response.requestId));

		Assert.isTrue(call.cancelled, "the handler was not told its caller cancelled");
		Assert.equals(RPCFailure.Cancelled, call.reason);
		Assert.equals(1, told);
		Assert.equals(0, fixture.server.callsWaiting, "a cancelled call kept its place among the calls waiting");
		Assert.same(["slow " + RPCError.CANCELLED_MESSAGE], fixture.handler.afterCalls);
		Assert.same([], fixture.reported, "a caller's cancel was reported as a failure here");

		// The answer coming after all goes nowhere.
		fixture.handler.pending.get("a").complete("late");
		Assert.equals(sentBefore, fixture.link.server.sent, "an answer was sent to a caller that had cancelled");
		Assert.equals(1, told);
		Assert.same(["slow " + RPCError.CANCELLED_MESSAGE], fixture.handler.afterCalls, "afterCall was told twice");
	}

	public function testACallersDeadlinePassingEndsTheCallOnTheHandlersSide():Void {
		final fixture = new ControlFixture();
		final receiver = new ControlReceiver();
		fixture.commands.withTimeout(500).slowThen("b", receiver);
		final call = fixture.handler.calls.get("b");
		final sentBefore:Int = fixture.link.server.sent;

		pump(0.75);

		Assert.same(["timed out"], receiver.told);
		Assert.isTrue(call.cancelled, "the handler outlived its caller's deadline");
		Assert.equals(RPCFailure.TimedOut, call.reason);
		Assert.equals(0, fixture.server.callsWaiting);
		Assert.equals(sentBefore, fixture.link.server.sent, "a call whose caller stopped waiting was answered");
		Assert.same([], fixture.reported);
		Assert.equals(1, fixture.handler.afterCalls.length);
	}

	public function testADeadlineGivenAfterTheCallCancelsItOnThePeerWhenItPasses():Void {
		final fixture = new ControlFixture();
		final response = fixture.commands.slow("c").timeout(500);
		final call = fixture.handler.calls.get("c");
		Assert.equals(0.0, call.deadline, "a deadline given after the call went arrived with it");

		pump(0.75);

		Assert.isTrue(Std.isOfType(response.cause, RPCTimeoutError));
		Assert.isTrue(call.cancelled, "the peer was not told the call had timed out");
		Assert.equals(RPCFailure.Cancelled, call.reason);
		Assert.equals(0, fixture.server.callsWaiting);
	}

	public function testTheSoonerOfTheCallersDeadlineAndHandlerTimeoutEndsIt():Void {
		final fixture = new ControlFixture();
		fixture.server.handlerTimeout = 1000;
		final longer = fixture.commands.withTimeout(5000).slow("d");
		final shorter = fixture.commands.withTimeout(250).slow("e");

		pump(0.5);
		Assert.equals(RPCFailure.TimedOut, fixture.handler.calls.get("e").reason);
		Assert.isFalse(fixture.handler.calls.get("d").cancelled, "the handler's own timeout fell due early");
		Assert.isTrue(Std.isOfType(shorter.cause, RPCTimeoutError));
		pump(0.75);
		// handlerTimeout's: the caller is still waiting, and is answered so.
		Assert.equals(RPCError.TIMEOUT_MESSAGE, longer.error);
		Assert.equals(RPCFailure.TimedOut, fixture.handler.calls.get("d").reason);
		Assert.equals(1, fixture.reported.length, "handlerTimeout passing was not reported, or the caller's deadline was");
	}

	public function testTheConnectionEndingTellsAHandlerAnsweringLater():Void {
		final fixture = new ControlFixture();
		fixture.commands.slow("f");
		final call = fixture.handler.calls.get("f");
		fixture.link.server.peerLeft();

		Assert.isTrue(call.cancelled, "a handler was not told its caller's connection ended");
		switch (call.reason) {
			case Disconnected(_):
				Assert.pass();
			case other:
				Assert.fail("ended as " + other);
		}
	}

	public function testARuntimeHandlerSeesItsCallsDeadlineAndItsCancel():Void {
		final fixture = new ControlFixture();
		var call:Null<RPCCall> = null;
		fixture.server.register(900, args -> {
			call = fixture.server.currentCall;
			return new Completer<Dynamic>().future;
		});
		fixture.client.callTimeout = 400;
		final response:RPCResponse<Dynamic> = fixture.client.request(900, []);
		Assert.notNull(call);
		Assert.isTrue(call.timeLeft > 0 && call.timeLeft <= 400, "a runtime call's deadline did not arrive: " + call.timeLeft + " " + call.deadline + " " + fixture.client.peerCapabilities);
		Assert.isNull(fixture.server.currentCall, "a call was left current between calls");

		pump(0.5);
		Assert.isTrue(Std.isOfType(response.cause, RPCTimeoutError));
		Assert.isTrue(call.cancelled);
		Assert.equals(0, fixture.server.callsWaiting);
	}

	public function testAPeerThatDoesNotSayItReadsThemIsSentNeither():Void {
		final fixture = new ControlFixture();
		// As a peer whose hello declares no such capability.
		fixture.client.peerCapabilities = 0;
		fixture.client.callTimeout = 5000;
		fixture.link.server.bufferInbound = true;
		final response = fixture.commands.slow("g");
		fixture.client.cancelCall(response.requestId);
		final frames = fixture.link.server.__pendingInputs;
		Assert.equals(1, frames.length, "a cancel went to a peer that does not read one");
		final frame:ByteArray = frames[0];
		frame.position = 4;
		Assert.equals(RPCWire.FLAG_REQUEST, frame.readUnsignedByte(), "a deadline went to a peer that does not read one");
		fixture.link.server.bufferInbound = false;
		fixture.link.server.flushBufferedReads();
		Assert.equals(0.0, fixture.handler.calls.get("g").deadline);
	}

	public function testACallThatNeverReadsItsCallMakesNone():Void {
		final fixture = new ControlFixture();
		fixture.client.callTimeout = 5000;
		Assert.equals(3, fixture.commands.quick(3).result);
		Assert.isNull(fixture.server.__currentCall);
	}

	private static function pump(seconds:Float):Void {
		var runtime = CrossByte.current();
		var elapsed = 0.0;
		while (elapsed < seconds) {
			runtime.pump(0.25, 0);
			elapsed += 0.25;
		}
	}
}

private class ControlFixture {
	public final link = LinkedConnection.pair();
	public final commands = new ControlCommands();
	public final handler = new ControlHandler();
	public final client:RPCSession<ControlCommands>;
	public final server:RPCSession<Dynamic>;
	public final reported:Array<String> = [];

	public function new() {
		client = new RPCSession<ControlCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));
	}
}

private class ControlCommands extends RPCCommands {
	public function new() {}

	@:rpc public function slow(key:String):RPCResponse<String> {}

	@:rpc public function quick(value:Int):RPCResponse<Int> {}

	@:rpc public function measure():RPCResponse<Int> {}
}

private class ControlHandler extends RPCHandler {
	public final pending = new Map<String, Completer<String>>();
	public final calls = new Map<String, RPCCall>();
	public final seen:Array<RPCCall> = [];
	public final afterCalls:Array<String> = [];

	public function new() {}

	@:rpc public function slow(key:String):Future<String> {
		calls.set(key, currentCall);
		final completer = new Completer<String>();
		pending.set(key, completer);
		return completer.future;
	}

	@:rpc public function quick(value:Int):Int {
		return value;
	}

	@:rpc public function measure():Int {
		seen.push(currentCall);
		return 4;
	}

	override public function afterCall(method:String, requestId:Int, error:Null<haxe.Exception>):Void {
		if (method == "slow") {
			afterCalls.push(method + " " + (error == null ? "ok" : error.message));
		}
	}
}

private class ControlReceiver implements RPCStringReceiver {
	public final told:Array<String> = [];

	public function new() {}

	public function onString(call:Int, value:String):Void {
		told.push(value);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		told.push(failure == TimedOut ? "timed out" : Std.string(failure));
	}
}
