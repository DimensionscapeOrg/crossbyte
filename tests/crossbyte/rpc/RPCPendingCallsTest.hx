package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.rpc._internal.RPCPendingCalls;
import utest.Assert;

/**
	The calls waiting on their answers, past a caller's first: a ring
	indexed by request id. Each must be found again by its id whatever else
	waits beside it: calls in flight by the hundred, answered in any order,
	and a slow one that a ring's length of later calls has passed.
**/
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc._internal.RPCPendingCalls)
class RPCPendingCallsTest extends utest.Test {
	public function testACallIsFoundByItsIdAndOnlyOnce():Void {
		var calls = new RPCPendingCalls();
		var responses = [for (id in 1...9) new RPCResponse<Dynamic>(id, 1)];
		for (response in responses) {
			calls.put(response.requestId, response);
		}
		Assert.equals(8, calls.count);
		Assert.isTrue(calls.has(5));
		Assert.isFalse(calls.has(9));
		Assert.equals(responses[4], calls.take(5));
		Assert.isNull(calls.take(5), "a call was found again after it was taken");
		Assert.isFalse(calls.has(5));
		Assert.equals(7, calls.count);
	}

	public function testACallAWholeRingBehindMovesAsideAndIsStillFound():Void {
		var calls = new RPCPendingCalls();
		var slow = new RPCResponse<Dynamic>(3, 1);
		calls.put(3, slow);
		// Its place, sixteen calls later, with the ring nearly empty.
		var later = new RPCResponse<Dynamic>(19, 1);
		calls.put(19, later);
		Assert.equals(16, calls.__calls.length, "the ring grew for one call in the way");
		Assert.isTrue(calls.has(3));
		Assert.isTrue(calls.has(19));
		Assert.equals(later, calls.take(19));
		Assert.equals(slow, calls.take(3));
		Assert.equals(0, calls.count);
	}

	public function testTheRingGrowsWhileHalfOfItWaits():Void {
		var calls = new RPCPendingCalls();
		var responses = [for (id in 1...41) new RPCResponse<Dynamic>(id, 1)];
		for (response in responses) {
			calls.put(response.requestId, response);
		}
		Assert.isTrue(calls.__calls.length >= 64, "forty calls in flight shared a ring of " + calls.__calls.length);
		var lost:Int = 0;
		for (response in responses) {
			if (calls.take(response.requestId) != response) {
				lost++;
			}
		}
		Assert.equals(0, lost);
		Assert.equals(0, calls.count);
	}

	public function testFailingThemAllFailsEachOnce():Void {
		var calls = new RPCPendingCalls();
		var responses = [for (id in 1...30) new RPCResponse<Dynamic>(id * 16, 1)];
		for (response in responses) {
			calls.put(response.requestId, response);
		}
		var failures:Int = 0;
		for (response in responses) {
			response.then(_ -> {}, _ -> failures++);
		}
		calls.failAll("gone", null);
		Assert.equals(responses.length, failures);
		Assert.equals(0, calls.count);
		for (response in responses) {
			Assert.equals("gone", response.error);
		}
	}

	public function testHundredsInFlightAnsweredFromTheBackEachGetItsOwnAnswer():Void {
		var fixture = new Fixture();
		var calls = [for (i in 0...300) fixture.commands.echo(i)];
		var completers = fixture.handler.waiting.copy();
		completers.reverse();
		for (completer in completers) {
			completer.complete(-1);
		}
		var wrong:Int = 0;
		for (i in 0...300) {
			if (!calls[i].succeeded || calls[i].result != i) {
				wrong++;
			}
		}
		Assert.equals(0, wrong, "a call was answered with another's answer, or not at all");
		Assert.isNull(fixture.commands.__pendingResponse);
		Assert.equals(0, fixture.commands.__pendingResponses.count);
	}

	public function testASlowCallStillGetsItsAnswerAfterThousandsAnsweredPastIt():Void {
		var fixture = new Fixture();
		// The first waits in a field of its own; the second, in the ring.
		var first = fixture.commands.echo(1);
		var slow = fixture.commands.echo(2);
		var quick = 0;
		for (i in 0...5000) {
			fixture.commands.now(i).then(value -> if (value == i) quick++);
		}
		Assert.equals(5000, quick);
		Assert.isFalse(slow.completed);
		for (completer in fixture.handler.waiting) {
			completer.complete(-1);
		}
		Assert.equals(1, first.result);
		Assert.equals(2, slow.result, "a call that waited past a ring's length of others was lost");
	}

	public function testIdsWrappingPastTheTopAreStillMatched():Void {
		var fixture = new Fixture();
		fixture.commands.__requestIdSeed = 0x7FFFFFFF - 20;
		var calls = [for (i in 0...40) fixture.commands.echo(i)];
		for (completer in fixture.handler.waiting) {
			completer.complete(-1);
		}
		var wrong:Int = 0;
		for (i in 0...40) {
			if (calls[i].result != i) {
				wrong++;
			}
		}
		Assert.equals(0, wrong);
		Assert.isTrue(fixture.commands.__requestIdSeed > 0 && fixture.commands.__requestIdSeed < 100, "the ids did not wrap");
	}
}

private class Fixture {
	public final commands = new PendingCommands();
	public final handler = new PendingHandler();
	public final client:RPCSession<PendingCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		var link = LinkedConnection.pair();
		client = new RPCSession<PendingCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
		// Hundreds of calls wait on this side at once.
		server.maxCallsWaiting = 1000;
	}
}

private class PendingCommands extends RPCCommands {
	public function new() {}

	@:rpc public function echo(value:Int):RPCResponse<Int> {}

	@:rpc public function now(value:Int):RPCResponse<Int> {}
}

private class PendingHandler extends RPCHandler {
	/** Each call to `echo` waiting, answered with its own value when completed. **/
	public final waiting:Array<{complete:Int->Void}> = [];

	public function new() {}

	@:rpc public function echo(value:Int):Future<Int> {
		var completer = new Completer<Int>();
		waiting.push({complete: _ -> completer.complete(value)});
		return completer.future;
	}

	@:rpc public function now(value:Int):Int {
		return value;
	}
}
