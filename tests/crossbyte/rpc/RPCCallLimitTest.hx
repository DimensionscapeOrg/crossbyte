package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.net.RateLimiter;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import utest.Assert;

/**
	`@:rpcLimit`: a rate limit and a cap on the bytes of a call's arguments,
	per method, checked before the call is dispatched, and its arguments'
	size before they are read.

	Runs on the runtime's clock, which the rate limits read, pumped.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.RPCCommands)
class RPCCallLimitTest extends utest.Test {
	/**
		Pumped once so the clock read is the harness runtime's: a test
		elsewhere makes a runtime of its own and exits it.
	**/
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testACallOverItsMethodsRateIsRefusedAsBusyAndTheRateComesBack():Void {
		final pair = new Pair();
		// Three a second: the bucket starts full.
		for (i in 0...3) {
			Assert.equals(i, pair.commands.limited(i).result, "a call within the rate was refused");
		}
		final refused = pair.commands.limited(3);
		Assert.isTrue(Type.enumEq(Busy, refused.failure), "a call over the rate failed with " + refused.failure);
		Assert.equals(RPCError.RATE_LIMITED_MESSAGE, refused.error);
		Assert.same(["limited 0", "limited 1", "limited 2"], pair.handler.ran, "a refused call ran");
		Assert.same([], pair.reported, "a refusal was reported as a failure");

		// A third of a second gives back one call, and only one.
		pump(0.35);
		Assert.equals(4, pair.commands.limited(4).result, "the rate did not come back");
		Assert.isTrue(Type.enumEq(Busy, pair.commands.limited(5).failure), "more came back than the time allows");

		// A second gives back the whole burst, and no more.
		pump(1.05);
		for (i in 6...9) {
			Assert.equals(i, pair.commands.limited(i).result);
		}
		Assert.isTrue(Type.enumEq(Busy, pair.commands.limited(9).failure), "a bucket refilled past its capacity");
		pair.stillAnswers();
	}

	public function testARefusalReachesAReceiverAsBusy():Void {
		final pair = new Pair();
		final told = new Told();
		for (i in 0...4) {
			pair.commands.limitedThen(i, told);
		}
		Assert.same([0, 1, 2], told.values);
		Assert.equals(1, told.failures.length);
		Assert.isTrue(told.failures.length == 1 && Type.enumEq(Busy, told.failures[0]), "a receiver was told " + told.failures);
	}

	public function testAOneWayCallOverItsRateIsDroppedQuietly():Void {
		final pair = new Pair();
		for (i in 0...4) {
			pair.commands.nudge(i);
		}
		Assert.same(["nudge 0", "nudge 1"], pair.handler.ran, "a one-way call over its rate ran");
		Assert.same([], pair.reported);
		Assert.isFalse(pair.ended, "a refusal ended the connection");
		pump(0.6);
		pair.commands.nudge(9);
		Assert.same(["nudge 0", "nudge 1", "nudge 9"], pair.handler.ran, "the rate of a one-way call did not come back");
	}

	public function testEachSessionHasItsOwnBucket():Void {
		// One handler serving two sessions: each spends its own calls.
		final handler = new LimitHandler();
		final first = new Pair(handler);
		final second = new Pair(handler);
		for (i in 0...3) {
			first.commands.limited(i);
		}
		Assert.isTrue(Type.enumEq(Busy, first.commands.limited(3).failure));
		Assert.equals(10, second.commands.limited(10).result, "one session's calls spent another's");
	}

	public function testArgumentsOverTheCapAreRefusedAsTooLargeBeforeTheyAreRead():Void {
		final pair = new Pair();
		Assert.equals(3, pair.commands.total([1, 1, 1]).result, "arguments within the cap were refused");
		// Five Ints and the count: 21 bytes, over the 16 allowed.
		final refused = pair.commands.total([1, 2, 3, 4, 5]);
		Assert.isTrue(Type.enumEq(TooLarge, refused.failure), "arguments over the cap failed with " + refused.failure);
		Assert.equals(RPCError.TOO_LARGE_MESSAGE, refused.error);
		Assert.isFalse(pair.handler.ran.indexOf("total 15") >= 0, "a call over the cap ran");

		// Not read at all: arguments that could not be read, over the cap,
		// are refused for their size, where reading them would have found
		// them unreadable. A count of 1,000 Ints in 20 bytes.
		final requestId:Int = pair.commands.__nextRequestId();
		final waiting:RPCResponse<Int> = cast pair.commands.__createResponse(RPCOps.opOf("total([i32]):i32"), requestId);
		final call = new ByteArrayOutput(64);
		call.writeByte(RPCWire.FLAG_REQUEST);
		call.writeInt(RPCOps.opOf("total([i32]):i32"));
		call.writeVarUInt(requestId);
		call.writeVarUInt(1000);
		for (_ in 0...18) {
			call.writeByte(0);
		}
		final unreadable:Array<String> = [];
		pair.server.onUnreadableFrame = (op, id, reason) -> unreadable.push(reason);
		pair.link.client.send(frameOf(call));
		Assert.isTrue(Type.enumEq(TooLarge, waiting.failure), "arguments over the cap were read: " + waiting.failure);
		Assert.same([], unreadable, "arguments over the cap were read, and found unreadable");

		// The same 20 bytes to a method with no cap are read, and refused so.
		final readId:Int = pair.commands.__nextRequestId();
		final read:RPCResponse<Int> = cast pair.commands.__createResponse(RPCOps.opOf("count([i32]):i32"), readId);
		final uncapped = new ByteArrayOutput(64);
		uncapped.writeByte(RPCWire.FLAG_REQUEST);
		uncapped.writeInt(RPCOps.opOf("count([i32]):i32"));
		uncapped.writeVarUInt(readId);
		uncapped.writeVarUInt(1000);
		for (_ in 0...18) {
			uncapped.writeByte(0);
		}
		pair.link.client.send(frameOf(uncapped));
		Assert.isTrue(Type.enumEq(UnreadableArguments, read.failure), "the uncapped control was " + read.failure);
		pair.stillAnswers();
	}

	public function testALimitedCallIsRefusedBeforeBeforeCallSeesIt():Void {
		final pair = new Pair(new HookedLimitHandler());
		final hooked:HookedLimitHandler = cast pair.handler;
		pair.commands.total([1, 2, 3, 4, 5]);
		pair.commands.total([1, 2]);
		for (i in 0...4) {
			pair.commands.limited(i);
		}
		Assert.same(["total 9", "limited 4", "limited 4", "limited 4"], hooked.before, "beforeCall saw a call its method's limits refused");
		Assert.same(["total", "limited", "limited", "limited"], hooked.after);
	}

	public function testMethodsWithoutALimitAreUntouched():Void {
		final pair = new Pair();
		for (i in 0...500) {
			if (pair.commands.free(i).result != i) {
				Assert.fail('an unlimited call was refused at $i: ' + pair.commands.free(i).failure);
				return;
			}
		}
		Assert.equals(500, pair.handler.ran.length);
		// Nor do they spend the limited methods' buckets.
		Assert.equals(1, pair.commands.limited(1).result);
	}

	public function testAHandlerWithoutLimitsKeepsNothingForThem():Void {
		final link = LinkedConnection.pair();
		final commands = new LimitCommands();
		final server = new RPCSession(link.server, null, new UnlimitedHandler());
		final client = new RPCSession<LimitCommands>(link.client, commands);
		for (i in 0...10) {
			Assert.equals(i, commands.free(i).result);
		}
		Assert.isNull(server.__limits, "a handler without limits made a session state for them");
		Assert.notNull(client);
	}

	public function testTheClassLimitIsTheDefaultForMethodsWithoutOne():Void {
		final link = LinkedConnection.pair();
		final commands = new LimitCommands();
		final handler = new DefaultLimitHandler();
		final server = new RPCSession(link.server, null, handler);
		final client = new RPCSession<LimitCommands>(link.client, commands);
		// The class's: two a second, for free and for count alike, each its own.
		Assert.equals(1, commands.free(1).result);
		Assert.equals(2, commands.free(2).result);
		Assert.isTrue(Type.enumEq(Busy, commands.free(3).failure), "the class's limit did not apply");
		Assert.equals(0, commands.count([]).result, "one method's calls spent another's");
		// Its own, which replaces the class's.
		for (i in 0...5) {
			Assert.equals(i, commands.limited(i).result, "a method's own limit did not replace the class's");
		}
		// And none at all, taken out of the class's.
		for (i in 0...20) {
			Assert.equals(i * 2, commands.total([i, i]).result, "@:rpcLimit() did not take a method out of the class's limit");
		}
		Assert.notNull(server);
		Assert.notNull(client);
	}

	public function testASubclassAnswersItsParentsMethodsWithTheirLimits():Void {
		final link = LinkedConnection.pair();
		final commands = new LimitCommands();
		final child = new ChildLimitHandler();
		final server = new RPCSession(link.server, null, child);
		final client = new RPCSession<LimitCommands>(link.client, commands);
		for (i in 0...3) {
			Assert.equals(i, commands.limited(i).result);
		}
		Assert.isTrue(Type.enumEq(Busy, commands.limited(3).failure), "the parent's limit was lost in the subclass");
		Assert.isTrue(Type.enumEq(TooLarge, commands.total([1, 2, 3, 4, 5]).failure));
		// A limit the parent wrote with a constant of its own.
		for (i in 0...4) {
			commands.nudge(i);
		}
		Assert.same(["nudge 0", "nudge 1"], child.ran.filter(entry -> StringTools.startsWith(entry, "nudge")), "the parent's own constant was lost");
		// The subclass's own method, under the class limit it declares.
		Assert.equals("hi", commands.greet("hi").result);
		Assert.isTrue(Type.enumEq(Busy, commands.greet("again").failure), "the subclass's class limit did not apply");
		Assert.notNull(server);
		Assert.notNull(client);
	}

	public function testByAddressSpendsFromALimiterTheSessionsShare():Void {
		// Two sessions from one address, 127.0.0.1, sharing four calls a minute.
		final shared = new RateLimiter(4, 60.0);
		final handler = new LimitHandler();
		handler.perClient = shared;
		final first = new Pair(handler);
		final second = new Pair(handler);
		Assert.equals(0, first.commands.byAddress(0).result);
		Assert.equals(1, first.commands.byAddress(1).result);
		Assert.equals(2, second.commands.byAddress(2).result);
		Assert.equals(3, second.commands.byAddress(3).result);
		Assert.isTrue(Type.enumEq(Busy, first.commands.byAddress(4).failure), "the address's calls were not shared");
		Assert.isTrue(Type.enumEq(Busy, second.commands.byAddress(5).failure));
		Assert.equals(0, shared.remaining("127.0.0.1"));

		// No limiter given, none applies.
		handler.perClient = null;
		Assert.equals(6, first.commands.byAddress(6).result);
	}

	public function testAnAddressRefusalSpendsNoneOfTheSessionsOwnRate():Void {
		// A session limit of 2 a second and an address limit of 1 a minute:
		// the address's refusals leave the session's calls where they were.
		final shared = new RateLimiter(1, 60.0);
		final handler = new LimitHandler();
		handler.perClient = shared;
		final pair = new Pair(handler);
		Assert.equals(0, pair.commands.both(0).result);
		Assert.isTrue(Type.enumEq(Busy, pair.commands.both(1).failure));
		Assert.isTrue(Type.enumEq(Busy, pair.commands.both(2).failure));
		shared.reset("127.0.0.1");
		Assert.equals(3, pair.commands.both(3).result, "a call the address refused spent the session's rate");
	}

	public function testAConnectionThatTakesAnotherPeerStartsWithFullBuckets():Void {
		final pair = new Pair();
		for (i in 0...3) {
			pair.commands.limited(i);
		}
		Assert.isTrue(Type.enumEq(Busy, pair.commands.limited(3).failure));
		// What a LocalConnection listening again does.
		pair.server.__epoch++;
		Assert.equals(4, pair.commands.limited(4).result, "a new peer inherited the last one's spent calls");
	}

	public function testAHandlerChangedStartsAfresh():Void {
		final pair = new Pair();
		for (i in 0...3) {
			pair.commands.limited(i);
		}
		Assert.notNull(pair.server.__limits);
		pair.server.handler = new LimitHandler();
		Assert.isNull(pair.server.__limits, "a new handler kept the old one's buckets");
		Assert.equals(3, pair.commands.limited(3).result);
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
		while (elapsed < seconds - 1e-9) {
			runtime.pump(0.05, 0);
			elapsed += 0.05;
		}
	}
}

/** The limits the test's handlers name. **/
class LimitRules {
	public static inline final BURST:Int = 3;
}

private class Pair {
	public final link = LinkedConnection.pair();
	public final commands = new LimitCommands();
	public final handler:LimitHandler;
	public final client:RPCSession<LimitCommands>;
	public final server:RPCSession<Dynamic>;
	public final reported:Array<String> = [];
	public var ended(default, null):Bool = false;

	public function new(?handler:LimitHandler) {
		this.handler = handler != null ? handler : new LimitHandler();
		server = new RPCSession(link.server, null, this.handler);
		client = new RPCSession<LimitCommands>(link.client, commands);
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));
		link.server.onClose = _ -> ended = true;
	}

	public function stillAnswers(?pos:haxe.PosInfos):Void {
		Assert.equals(5, commands.free(5).result, "the session did not answer after it", pos);
	}
}

private class LimitCommands extends RPCCommands {
	public function new() {}

	@:rpc public function limited(value:Int):RPCResponse<Int> {}

	@:rpc public function nudge(value:Int):Void {}

	@:rpc public function total(values:Array<Int>):RPCResponse<Int> {}

	@:rpc public function count(values:Array<Int>):RPCResponse<Int> {}

	@:rpc public function free(value:Int):RPCResponse<Int> {}

	@:rpc public function byAddress(value:Int):RPCResponse<Int> {}

	@:rpc public function both(value:Int):RPCResponse<Int> {}

	@:rpc public function greet(words:String):RPCResponse<String> {}
}

private class LimitHandler extends RPCHandler {
	public final ran:Array<String> = [];
	public var perClient:Null<RateLimiter> = null;

	public function new() {}

	@:rpcLimit(calls = LimitRules.BURST, seconds = 1)
	@:rpc public function limited(value:Int):Int {
		ran.push('limited $value');
		return value;
	}

	// A constant of the handler's own, which is still being built as its
	// limits are read.
	public static inline final NUDGES:Int = 2;

	@:rpcLimit(calls = NUDGES, seconds = NUDGES / 4)
	@:rpc public function nudge(value:Int):Void {
		ran.push('nudge $value');
	}

	// A count and up to three Ints.
	@:rpcLimit(bytes = 16)
	@:rpc public function total(values:Array<Int>):Int {
		var sum = 0;
		for (value in values) {
			sum += value;
		}
		ran.push('total $sum');
		return sum;
	}

	@:rpc public function count(values:Array<Int>):Int {
		return values.length;
	}

	@:rpc public function free(value:Int):Int {
		ran.push('free $value');
		return value;
	}

	@:rpcLimit(byAddress = perClient)
	@:rpc public function byAddress(value:Int):Int {
		return value;
	}

	@:rpcLimit(calls = 2, seconds = 1, byAddress = perClient)
	@:rpc public function both(value:Int):Int {
		return value;
	}

	@:rpc public function greet(words:String):String {
		return words;
	}
}

/** Sees every call that reaches beforeCall, and every one that finished. **/
private class HookedLimitHandler extends LimitHandler {
	public final before:Array<String> = [];
	public final after:Array<String> = [];

	public function new() {
		super();
	}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		before.push(method + " " + payloadSize);
		return null;
	}

	override public function afterCall(method:String, requestId:Int, error:Null<haxe.Exception>):Void {
		after.push(method);
	}
}

private class UnlimitedHandler extends RPCHandler {
	public function new() {}

	@:rpc public function free(value:Int):Int {
		return value;
	}
}

/** Two a second for every method without a limit of its own. **/
@:rpcLimit(calls = 2, seconds = 1)
private class DefaultLimitHandler extends RPCHandler {
	public function new() {}

	@:rpc public function free(value:Int):Int {
		return value;
	}

	@:rpc public function count(values:Array<Int>):Int {
		return values.length;
	}

	@:rpcLimit(calls = 5)
	@:rpc public function limited(value:Int):Int {
		return value;
	}

	@:rpcLimit()
	@:rpc public function total(values:Array<Int>):Int {
		var sum = 0;
		for (value in values) {
			sum += value;
		}
		return sum;
	}
}

/** One a second for its own method; its parent's keep their limits. **/
@:rpcLimit(calls = 1)
private class ChildLimitHandler extends LimitHandler {
	public function new() {
		super();
	}

	override public function greet(words:String):String {
		return words;
	}
}

private class Told implements RPCIntReceiver {
	public final values:Array<Int> = [];
	public final failures:Array<RPCFailure> = [];

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		values.push(value);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		failures.push(failure);
	}
}
