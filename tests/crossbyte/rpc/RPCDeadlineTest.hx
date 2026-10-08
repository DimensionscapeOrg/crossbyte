package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.test.Require;
import utest.Assert;

/**
	Deadlines, for the calls a session makes and for the answers its handler
	owes.

	A call with no deadline waits for as long as its connection lasts: a
	peer that takes a call and never answers it (a handler whose future
	never completes) holds the caller's response for good, and holds one of
	its own session's 256 places for calls waiting. A call can be given a
	deadline, one at a time or as a session's default, and a session can
	give its handler one.

	Runs on the runtime's own clock, pumped.
**/
@:access(crossbyte.rpc.RPCResponse)
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc._internal.RPCDeadlines)
class RPCDeadlineTest extends utest.Test {
	/**
		Pumped once so its timers are the harness runtime's: a test elsewhere
		makes a runtime of its own and exits it, and until this one pumps, a
		timer set on this thread goes to that one and never fires.
	**/
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testACallPastItsDeadlineFailsAndTheConnectionStaysUp():Void {
		var fixture = new Fixture();
		var waiting = fixture.commands.slow("a").timeout(1000);

		pump(0.75);
		Assert.isFalse(waiting.completed, "failed before its deadline");
		pump(0.5);

		Assert.isTrue(waiting.completed, "outlived its deadline");
		Assert.isTrue(Std.isOfType(waiting.cause, RPCTimeoutError), "not failed as a timeout: " + waiting.cause);
		Assert.stringContains("timed out", waiting.error);
		Assert.same([], fixture.closes, "a slow answer closed the connection");

		// The connection still answers, and the answer arriving late completes
		// nothing.
		Assert.equals(5, fixture.commands.quick(5).result);
		fixture.handler.pending.get("a").complete("late");
		Assert.isFalse(waiting.succeeded, "a call that timed out was completed after all");
		Assert.isTrue(Std.isOfType(waiting.cause, RPCTimeoutError));
	}

	public function testASessionsDeadlineAppliesToEveryCallOnBothLanes():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		// A runtime handler that never answers.
		fixture.server.register(800, args -> new Completer<Dynamic>().future);
		var compiled = fixture.commands.slow("b");
		var runtime:RPCResponse<Dynamic> = fixture.client.request(800, []);

		pump(1.25);

		Assert.isTrue(Std.isOfType(compiled.cause, RPCTimeoutError));
		Assert.isTrue(Std.isOfType(runtime.cause, RPCTimeoutError), "a runtime call outlived the session's deadline");
	}

	public function testACallsOwnDeadlineReplacesTheSessions():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 500;
		var longer = fixture.commands.slow("c").timeout(3000);
		var none = fixture.commands.slow("d").timeout(0);

		pump(2);
		Assert.isFalse(longer.completed, "held to the session's deadline, not its own");
		Assert.isFalse(none.completed, "a call with no deadline failed");
		pump(1.25);
		Assert.isTrue(Std.isOfType(longer.cause, RPCTimeoutError));
		Assert.isFalse(none.completed);
	}

	public function testACallAnsweredInTimeKeepsItsAnswer():Void {
		var fixture = new Fixture();
		var answered = fixture.commands.slow("e").timeout(1000);
		fixture.handler.pending.get("e").complete("in time");

		pump(2);

		Assert.equals("in time", answered.result);
		Assert.isTrue(answered.succeeded);
		Assert.isTrue(answered.__deadline == crossbyte._internal.system.timer.TimerHandle.INVALID, "a timer was left for an answered call");
	}

	public function testACallWithNoDeadlineArmsNothing():Void {
		var fixture = new Fixture();
		var waiting = fixture.commands.slow("f");
		Assert.isTrue(waiting.__deadline == crossbyte._internal.system.timer.TimerHandle.INVALID);
		pump(5);
		Assert.isFalse(waiting.completed);
	}

	public function testAHandlerThatDoesNotAnswerInTimeIsAnsweredForAndFreesItsPlace():Void {
		var fixture = new Fixture();
		fixture.server.handlerTimeout = 1000;
		var waiting = fixture.commands.slow("g");
		Assert.equals(1, fixture.server.callsWaiting);

		pump(1.25);

		Assert.equals(RPCError.TIMEOUT_MESSAGE, waiting.error, "the caller was not told the handler timed out");
		Assert.equals(0, fixture.server.callsWaiting, "the call still holds its place");
		Assert.equals(1, fixture.reported.length, "the handler timing out was not reported");
		Assert.same(["slow " + RPCError.TIMEOUT_MESSAGE], fixture.handler.afterCalls);

		// The future completing late answers nothing, and settles nothing twice.
		fixture.handler.pending.get("g").complete("too late");
		Assert.equals(RPCError.TIMEOUT_MESSAGE, waiting.error);
		Assert.equals(0, fixture.server.callsWaiting);
		Assert.equals(1, fixture.handler.afterCalls.length);
	}

	public function testARuntimeHandlerThatDoesNotAnswerInTimeIsAnsweredFor():Void {
		var fixture = new Fixture();
		fixture.server.handlerTimeout = 1000;
		var never = new Completer<Dynamic>();
		fixture.server.register(801, args -> never.future);
		var waiting:RPCResponse<Dynamic> = fixture.client.request(801, []);
		Assert.equals(1, fixture.server.callsWaiting);

		pump(1.25);

		Assert.equals(RPCError.TIMEOUT_MESSAGE, waiting.error);
		Assert.equals(0, fixture.server.callsWaiting);
	}

	public function testAHandlerAnsweringInTimeIsUntouchedByItsDeadline():Void {
		var fixture = new Fixture();
		fixture.server.handlerTimeout = 1000;
		var waiting = fixture.commands.slow("h");
		fixture.handler.pending.get("h").complete("done");
		pump(2);
		Assert.equals("done", waiting.result);
		Assert.same([], fixture.reported);
	}

	// ---- one queue of deadlines a session, for its callTimeout ----

	public function testCallsUnderTheSessionsDeadlineFailInTheOrderMadeEachAtItsOwnTime():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		fixture.server.register(802, args -> new Completer<Dynamic>().future);
		var failed:Array<String> = [];
		fixture.commands.slow("i").then(_ -> {}, _ -> failed.push("first"));
		pump(0.5);
		fixture.client.request(802, []).then(_ -> {}, _ -> failed.push("second"));
		fixture.commands.slow("j").then(_ -> {}, _ -> failed.push("third"));

		pump(0.75);
		Assert.same(["first"], failed, "a call failed before its own deadline, or not at it");
		pump(0.5);
		Assert.same(["first", "second", "third"], failed);
	}

	public function testACallAnsweredLeavesTheQueueAndTheOthersKeepTheirDeadlines():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		var first = fixture.commands.slow("k");
		var second = fixture.commands.slow("l");
		var third = fixture.commands.slow("m");
		fixture.handler.pending.get("l").complete("answered");
		Assert.isTrue(second.__deadline == crossbyte._internal.system.timer.TimerHandle.INVALID, "an answered call kept its deadline");
		// Let go of at once, though a call made before it still waits.
		Assert.equals(2, fixture.client.__deadlines.__live, "the queue still holds a call that was answered");
		fixture.handler.pending.get("k").complete("answered too");
		Assert.equals(1, fixture.client.__deadlines.__live);

		pump(1.25);
		Assert.equals("answered too", first.result);
		Assert.equals("answered", second.result);
		Assert.isTrue(Std.isOfType(third.cause, RPCTimeoutError), "the call left waiting outlived its deadline");
	}

	public function testLoweringTheSessionsDeadlineHoldsTheNextCallToTheLowerOne():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 2000;
		var longer = fixture.commands.slow("n");
		fixture.client.callTimeout = 500;
		var shorter = fixture.commands.slow("o");

		pump(0.75);
		Assert.isTrue(Std.isOfType(shorter.cause, RPCTimeoutError), "a call made after the deadline was lowered waited for the call before it");
		Assert.isFalse(longer.completed);
		pump(1.5);
		Assert.isTrue(Std.isOfType(longer.cause, RPCTimeoutError));
	}

	public function testACallMadeAsAnotherTimesOutGetsADeadlineOfItsOwn():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		var again:Null<RPCResponse<String>> = null;
		fixture.commands.slow("p").then(_ -> {}, _ -> again = fixture.commands.slow("q"));

		pump(1.25);
		final made = Require.notNull(again, "the first call did not time out");
		Assert.isFalse(made.completed);
		pump(1.25);
		Assert.isTrue(Std.isOfType(made.cause, RPCTimeoutError), "a call made while the queue was failing calls was left without a deadline");
	}

	public function testStoppingFailsTheCallsOnceAndLaterCallsStillHaveDeadlines():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		var before = [fixture.commands.slow("r"), fixture.commands.slow("s")];
		fixture.client.stop();
		for (call in before) {
			Assert.equals("RPC session stopped", call.error);
			Assert.isTrue(call.__deadline == crossbyte._internal.system.timer.TimerHandle.INVALID);
		}
		var after = fixture.commands.slow("t");

		pump(1.25);
		for (call in before) {
			Assert.equals("RPC session stopped", call.error, "a stopped call was failed again at its deadline");
		}
		Assert.isTrue(Std.isOfType(after.cause, RPCTimeoutError), "a call made after stop had no deadline");
	}

	public function testManyCallsBehindASlowOneKeepTheirDeadlinesAsTheQueueGrows():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		fixture.server.maxCallsWaiting = 1000;
		var slow = fixture.commands.slow("first");
		// Each call left waiting followed by one answered as it is made, which
		// leaves its place empty: the queue closes those up as it grows, and
		// the calls waiting move to new places.
		var quick:Array<RPCResponse<Int>> = [];
		var waiting:Array<RPCResponse<String>> = [];
		for (i in 0...300) {
			waiting.push(fixture.commands.slow("w" + i));
			quick.push(fixture.commands.quick(i));
		}
		// Half of those answered, from the back.
		for (i in 0...150) {
			fixture.handler.pending.get("w" + (299 - i)).complete("ok");
		}

		pump(1.25);
		Assert.isTrue(Std.isOfType(slow.cause, RPCTimeoutError));
		var wrong:Int = 0;
		for (i in 0...300) {
			if (quick[i].result != i || quick[i].__deadline != crossbyte._internal.system.timer.TimerHandle.INVALID) {
				wrong++;
			}
		}
		Assert.equals(0, wrong, "a call answered at once was not left alone");
		var answered:Int = 0;
		var timedOut:Int = 0;
		for (i in 0...300) {
			if (waiting[i].succeeded) {
				answered++;
			} else if (Std.isOfType(waiting[i].cause, RPCTimeoutError) && i < 150) {
				timedOut++;
			}
		}
		Assert.equals(150, answered);
		Assert.equals(150, timedOut, "a call left waiting did not time out, or one answered did");
	}

	// ---- and one for its handlerTimeout ----

	public function testHandlerDeadlinesFallDueInOrderAndOneAnsweredLeaves():Void {
		var fixture = new Fixture();
		fixture.server.handlerTimeout = 1000;
		var first = fixture.commands.slow("u");
		pump(0.5);
		var second = fixture.commands.slow("v");
		var third = fixture.commands.slow("x");
		fixture.handler.pending.get("v").complete("in time");
		Assert.equals(2, fixture.server.callsWaiting);

		pump(0.75);
		Assert.equals(RPCError.TIMEOUT_MESSAGE, first.error);
		Assert.equals("in time", second.result);
		Assert.isFalse(third.completed, "a handler's deadline fell due early");
		pump(0.5);
		Assert.equals(RPCError.TIMEOUT_MESSAGE, third.error);
		Assert.equals(0, fixture.server.callsWaiting);
	}

	public function testLoweringTheHandlerTimeoutHoldsTheNextCallToTheLowerOne():Void {
		var fixture = new Fixture();
		fixture.server.handlerTimeout = 2000;
		var longer = fixture.commands.slow("y");
		fixture.server.handlerTimeout = 500;
		var shorter = fixture.commands.slow("z");

		pump(0.75);
		Assert.equals(RPCError.TIMEOUT_MESSAGE, shorter.error, "a call that came after the timeout was lowered waited for the one before it");
		Assert.isFalse(longer.completed);
		pump(1.5);
		Assert.equals(RPCError.TIMEOUT_MESSAGE, longer.error);
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

private class Fixture {
	public final commands = new DeadlineCommands();
	public final handler = new DeadlineHandler();
	public final client:RPCSession<DeadlineCommands>;
	public final server:RPCSession<Dynamic>;
	public final closes:Array<String> = [];
	public final reported:Array<String> = [];

	public function new() {
		var link = LinkedConnection.pair();
		client = new RPCSession<DeadlineCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));
		client.connection.onClose = reason -> closes.push(Std.string(reason));
	}
}

private class DeadlineCommands extends RPCCommands {
	public function new() {}

	@:rpc public function slow(key:String):RPCResponse<String> {}

	@:rpc public function quick(value:Int):RPCResponse<Int> {}
}

private class DeadlineHandler extends RPCHandler {
	public final pending = new Map<String, Completer<String>>();
	public final afterCalls:Array<String> = [];

	public function new() {}

	@:rpc public function slow(key:String):Future<String> {
		var completer = new Completer<String>();
		pending.set(key, completer);
		return completer.future;
	}

	@:rpc public function quick(value:Int):Int {
		return value;
	}

	override public function afterCall(method:String, requestId:Int, error:Null<haxe.Exception>):Void {
		if (method == "slow") {
			afterCalls.push(method + " " + (error == null ? "ok" : (cast error : RPCError).message));
		}
	}
}
