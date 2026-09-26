package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import utest.Assert;

/**
	Deadlines, for the calls a session makes and for the answers its handler
	owes.

	A call with no deadline waited for as long as its connection lasted: a
	peer that took a call and never answered it, a handler whose future
	never completes, held the caller's response for good, and held one of
	its own session's 256 places for calls waiting. A call can now be given a
	deadline, one at a time or as a session's default, and a session can give
	its handler one.

	Runs on the runtime's own clock, pumped.
**/
@:access(crossbyte.rpc.RPCResponse)
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

	override public function afterCall(method:String, requestId:Int, error:Dynamic):Void {
		if (method == "slow") {
			afterCalls.push(method + " " + (error == null ? "ok" : (cast error : RPCError).message));
		}
	}
}
