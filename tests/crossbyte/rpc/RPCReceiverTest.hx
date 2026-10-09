package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.net.Reason;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.Bytes;
import utest.Assert;

/** A structure an answer can be. **/
typedef ReceiverSpot = {
	x:Int,
	y:Int
}

/** An enum with arguments an answer can be. **/
enum ReceiverMood {
	Calm;
	Angry(level:Int);
}

/** An enum abstract over Int, which a receiver takes as an Int. **/
enum abstract ReceiverColour(Int) to Int {
	var Red = 1;
	var Green = 2;
}

/** The methods a contract-mode commands class calls. **/
interface ReceiverContract {
	function total(a:Int, b:Int):Int;
	function label(id:Int):String;
}

/**
	Calls made with a receiver (`joinThen(..., receiver)`) rather than for an
	`RPCResponse`: every kind of answer arrives typed through its receiver,
	every way a call can end is told through `onFailure` exactly once, and
	the calls the commands keep for them are used again without mixing one
	call's answer into another's.
**/
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc.RPCSession)
class RPCReceiverTest extends utest.Test {
	/** Pumped once so its timers are the harness runtime's; see RPCDeadlineTest. **/
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testEveryKindOfAnswerArrivesThroughItsReceiver():Void {
		var fixture = new Fixture();
		var heard = new Heard();
		var c = fixture.commands;

		var calls:Array<Int> = [];
		calls.push(c.addThen(2, 40, heard));
		calls.push(c.halfThen(5, heard));
		calls.push(c.oddThen(3, heard));
		calls.push(c.nameThen(7, heard));
		calls.push(c.smallThen(-5, heard));
		calls.push(c.byteThen(200, heard));
		calls.push(c.shortThen(-300, heard));
		calls.push(c.wordThen(60000, heard));
		calls.push(c.unsignedThen(7, heard));
		calls.push(c.singleThen(1.5, heard));
		calls.push(c.colourThen(2, heard));

		Assert.same([
			'${calls[0]} int 42',
			'${calls[1]} float 2.5',
			'${calls[2]} bool true',
			'${calls[3]} string player 7',
			'${calls[4]} int -5',
			'${calls[5]} int 200',
			'${calls[6]} int -300',
			'${calls[7]} int 60000',
			'${calls[8]} int 7',
			'${calls[9]} float 3',
			'${calls[10]} int 2'
		], heard.log);
		Assert.equals(calls.length, distinct(calls), "two calls had one id");

		// Objects, and Null<T> of a number, through RPCValueReceiver.
		var spots = new Values<ReceiverSpot>();
		var spotCall = c.spotThen(3, spots);
		Assert.equals(spotCall, spots.calls[0]);
		Assert.equals(3, spots.values[0].x);
		Assert.equals(6, spots.values[0].y);

		var lists = new Values<Array<Int>>();
		c.listThen(3, lists);
		Assert.same([[0, 1, 2]], lists.values);

		var moods = new Values<ReceiverMood>();
		c.moodThen(0, moods);
		c.moodThen(4, moods);
		Assert.same([Calm, Angry(4)], moods.values);

		var blobs = new Values<Bytes>();
		c.blobThen(3, blobs);
		Assert.equals("abc", blobs.values[0].toString());

		var maybes = new Values<Null<Int>>();
		c.maybeThen(true, maybes);
		c.maybeThen(false, maybes);
		Assert.same([9, null], maybes.values);

		Assert.same([], heard.failures);
	}

	public function testTheContractModeAndAnInheritingCommandsClassHaveThem():Void {
		var link = LinkedConnection.pair();
		var commands = new ContractCommands();
		var client = new RPCSession<ContractCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new ContractHandler());
		var heard = new Heard();
		var call = commands.totalThen(20, 22, heard);
		commands.labelThen(5, heard);
		Assert.same(['$call int 42', '${call + 1} string label 5'], heard.log);

		var link2 = LinkedConnection.pair();
		var more = new MoreCommands();
		var client2 = new RPCSession<MoreCommands>(link2.client, more);
		var server2 = new RPCSession(link2.server, null, new MoreHandler());
		var heard2 = new Heard();
		more.addThen(1, 2, heard2);
		more.tripleThen(5, heard2);
		Assert.same(['1 int 3', '2 int 15'], heard2.log);
	}

	public function testAReceiverCanCallAgainFromItsAnswer():Void {
		// Told after its call is back among the kept ones: the next call is
		// made in it, and the two answers stay apart.
		var fixture = new Fixture();
		var chain = new Chain(fixture.commands, 5);
		fixture.commands.addThen(0, 1, chain);
		Assert.same([1, 2, 3, 4, 5], chain.values);
		Assert.equals(1, fixture.commands.__freeCount, "the calls made one after another took more than one kept call");
	}

	public function testAnErrorAnswerIsRefusedWithItsMessage():Void {
		var fixture = new Fixture();
		var heard = new Heard();
		var refused = fixture.commands.refuseThen(1, heard);
		var broken = fixture.commands.breakThen(1, heard);
		var missing = fixture.commands.missingThen(1, heard);

		Assert.same([refused, broken, missing], heard.failureCalls);
		Assert.same([
			Refused("not today"),
			Refused(RPCError.INTERNAL_MESSAGE),
			Refused(RPCError.UNKNOWN_METHOD_MESSAGE)
		], heard.failures);
		Assert.same([], heard.log);

		// The connection is still up.
		fixture.commands.addThen(1, 1, heard);
		Assert.same(['${missing + 1} int 2'], heard.log);
	}

	public function testACallPastItsDeadlineTimesOutAndALateAnswerIsDropped():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		var heard = new Heard();
		var call = fixture.commands.slowThen("a", heard);

		pump(0.75);
		Assert.same([], heard.failures, "failed before its deadline");
		pump(0.5);
		Assert.same([TimedOut], heard.failures);
		Assert.same([call], heard.failureCalls);

		fixture.handler.pending.get("a").complete("late");
		Assert.same([], heard.log, "an answer after the deadline was handed over");
		Assert.isTrue(fixture.link.client.open, "a slow answer closed the connection");
		fixture.commands.addThen(2, 3, heard);
		Assert.equals(1, heard.log.length);
	}

	public function testDeadlinesFallDueInOrderAmongFutureCalls():Void {
		// Receiver calls and futures share the session's one queue of deadlines.
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		var heard = new Heard();
		var first = fixture.commands.slowThen("a", heard);
		var future = fixture.commands.slow("b");
		pump(0.5);
		var second = fixture.commands.slowThen("c", heard);
		fixture.handler.pending.get("a").complete("first");

		pump(0.75);
		Assert.same(['$first string first'], heard.log);
		Assert.isTrue(Std.isOfType(future.cause, RPCTimeoutError), "the future between them did not time out");
		Assert.same([], heard.failures, "the second timed out with the future before it");
		pump(0.5);
		Assert.same([second], heard.failureCalls);
		Assert.same([TimedOut], heard.failures);
	}

	public function testACancelledCallIsToldSoAndItsAnswerDropped():Void {
		var fixture = new Fixture();
		fixture.client.callTimeout = 1000;
		var heard = new Heard();
		var call = fixture.commands.slowThen("a", heard);

		Assert.isTrue(fixture.client.cancelCall(call));
		Assert.same([Cancelled], heard.failures);
		Assert.same([call], heard.failureCalls);
		Assert.isFalse(fixture.client.cancelCall(call), "cancelled twice");
		Assert.isFalse(fixture.client.cancelCall(12345), "a call nobody made was cancelled");

		fixture.handler.pending.get("a").complete("late");
		pump(1.5);
		Assert.same([], heard.log, "a cancelled call's answer was handed over");
		Assert.equals(1, heard.failures.length, "a cancelled call was told again at its deadline");

		// A future's call can be cancelled by its id as well.
		var future = fixture.commands.slow("b");
		Assert.isTrue(fixture.client.cancelCall(future.requestId));
		Assert.isTrue(future.completed);
		Assert.isFalse(future.succeeded);
		Assert.equals("RPC call cancelled", future.error);
	}

	public function testCallsWaitingAreToldWhenTheConnectionEndsOrTheSessionStops():Void {
		var fixture = new Fixture();
		var heard = new Heard();
		var a = fixture.commands.slowThen("a", heard);
		var b = fixture.commands.slowThen("b", heard);
		var future = fixture.commands.slow("c");
		fixture.client.stop();
		Assert.same([a, b], heard.failureCalls);
		Assert.same([Stopped, Stopped], heard.failures);
		Assert.equals("RPC session stopped", future.error);

		var c = fixture.commands.slowThen("d", heard);
		var d = fixture.commands.slowThen("e", heard);
		fixture.link.client.close();
		Assert.same([a, b, c, d], heard.failureCalls);
		Assert.same([Stopped, Stopped, Disconnected(Closed), Disconnected(Closed)], heard.failures);

		// Made after the connection ended: told before the call returns.
		var e = fixture.commands.addThen(1, 2, heard);
		Assert.same([a, b, c, d, e], heard.failureCalls);
		Assert.same(Disconnected(Closed), heard.failures[4]);
		Assert.same([], heard.log);
	}

	public function testACallThatCannotGoIsUnsent():Void {
		var fixture = new Fixture();
		var heard = new Heard();
		fixture.client.maxFrameLength = 64;
		var big = fixture.commands.echoThen([for (_ in 0...100) "x"].join(""), heard);
		Assert.same([big], heard.failureCalls);
		Assert.isTrue(heard.failures[0].match(Unsent(_)), "not unsent: " + heard.failures[0]);
		fixture.client.maxFrameLength = 0;

		fixture.link.client.failSends = true;
		var refused = fixture.commands.addThen(1, 2, heard);
		Assert.same([big, refused], heard.failureCalls);
		Assert.isTrue(heard.failures[1].match(Unsent(_)), "not unsent: " + heard.failures[1]);
		fixture.link.client.failSends = false;

		var unbound = new ReceiverCommands();
		var lone = unbound.addThen(1, 2, heard);
		Assert.same([big, refused, lone], heard.failureCalls);
		Assert.isTrue(heard.failures[2].match(Unsent(_)), "not unsent: " + heard.failures[2]);
		Assert.equals(0, fixture.commands.__pendingResponses == null ? 0 : fixture.commands.__pendingResponses.count);
	}

	public function testAnAnswerThatDoesNotReadIsUnreadable():Void {
		var fixture = new Fixture();
		var heard = new Heard();
		var call = fixture.commands.slowThen("a", heard);
		// An answer with no String in it.
		var payload = new ByteArrayOutput(16);
		payload.writeByte(RPCWire.FLAG_RESPONSE);
		payload.writeInt(crossbyte.rpc._internal.RPCOps.opOf("slow(utf8):utf8"));
		payload.writeVarUInt(call);
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		fixture.link.server.send(frame);

		Assert.same([call], heard.failureCalls);
		Assert.isTrue(heard.failures[0].match(Unreadable(_)), "not unreadable: " + heard.failures[0]);
		Assert.isTrue(fixture.link.client.open);
	}

	public function testAReceiverThatThrowsIsContained():Void {
		var fixture = new Fixture();
		var thrower = new Thrower();
		fixture.commands.addThen(1, 2, thrower);
		fixture.commands.refuseThen(1, thrower);
		Assert.equals(2, thrower.told);
		Assert.isTrue(fixture.link.client.open, "a receiver's throw ended the connection");
		var heard = new Heard();
		fixture.commands.addThen(3, 4, heard);
		Assert.equals(1, heard.log.length);
	}

	public function testANullReceiverIsRefusedBeforeAnythingWaits():Void {
		var fixture = new Fixture();
		var refused:Dynamic = null;
		var sentBefore = fixture.link.client.sent;
		try {
			fixture.commands.addThen(1, 2, null);
		} catch (error:ArgumentError) {
			refused = error;
		}
		Assert.notNull(refused, "a call with no receiver went");
		Assert.isNull(fixture.commands.__pendingResponse);
		Assert.equals(sentBefore, fixture.link.client.sent, "a call with no receiver was sent");
		var heard = new Heard();
		fixture.commands.addThen(1, 2, heard);
		Assert.equals(1, heard.log.length);
	}

	public function testManyCallsInFlightAreEachAnsweredOnce():Void {
		// More than the ring holds, answered out of order, made with receivers
		// and futures together; then again, on the calls kept from the first
		// round.
		var fixture = new Fixture();
		// The handler holds every one of them waiting.
		fixture.server.maxCallsWaiting = 4000;
		var heard = new Heard();
		for (round in 0...2) {
			heard.log.splice(0, heard.log.length);
			var calls:Array<Int> = [];
			var futures:Array<RPCResponse<String>> = [];
			for (i in 0...3000) {
				if (i % 3 == 0) {
					futures.push(fixture.commands.slow('$round/$i'));
				} else {
					calls.push(fixture.commands.slowThen('$round/$i', heard));
				}
			}
			Assert.equals(3000, fixture.commands.__pendingResponses.count + (fixture.commands.__pendingResponse == null ? 0 : 1));
			// Answered backwards.
			var i = 2999;
			while (i >= 0) {
				fixture.handler.pending.get('$round/$i').complete('$i');
				i--;
			}
			Assert.equals(2000, heard.log.length);
			var expected = [for (i in 0...3000) if (i % 3 != 0) i];
			var told = [for (line in heard.log) Std.parseInt(line.split(" ")[2])];
			told.sort((a, b) -> a - b);
			Assert.same(expected, told, 'round $round: an answer went to the wrong call, or twice');
			for (line in heard.log) {
				var parts = line.split(" ");
				var call = Std.parseInt(parts[0]);
				var index = calls.indexOf(call);
				Assert.isTrue(index >= 0, 'round $round: told of a call never made: $line');
			}
			for (k in 0...futures.length) {
				Assert.equals('${k * 3}', futures[k].result);
			}
			Assert.same([], heard.failures);
			Assert.isTrue(fixture.commands.__freeCount <= 1024, "kept more calls than it keeps");
		}
	}

	public function testTheFutureApiIsAsItWas():Void {
		var fixture = new Fixture();
		var response = fixture.commands.add(20, 22);
		Assert.isTrue(response.completed);
		Assert.isTrue(response.succeeded);
		Assert.equals(42, response.result);
		var heardThen:Array<Int> = [];
		response.then(value -> heardThen.push(value));
		Assert.same([42], heardThen);

		var refused = fixture.commands.refuse(1);
		Assert.equals("not today", refused.error);
		Assert.isTrue(Std.isOfType(refused.cause, RPCError));

		var name = fixture.commands.name(7);
		Assert.equals("player 7", name.result);
		var half = fixture.commands.half(5);
		Assert.equals(2.5, half.result);
		Assert.isTrue(fixture.commands.odd(3).result);
	}

	private static function pump(seconds:Float):Void {
		var runtime = CrossByte.current();
		var elapsed = 0.0;
		while (elapsed < seconds) {
			runtime.pump(0.25, 0);
			elapsed += 0.25;
		}
	}

	private static function distinct(values:Array<Int>):Int {
		var seen = new Map<Int, Bool>();
		for (value in values) {
			seen.set(value, true);
		}
		return Lambda.count(seen);
	}
}

private class Fixture {
	public final link = LinkedConnection.pair();
	public final commands = new ReceiverCommands();
	public final handler = new ReceiverHandler();
	public final client:RPCSession<ReceiverCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<ReceiverCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

/** Every answer and failure it is told, in order. **/
private class Heard implements RPCIntReceiver implements RPCFloatReceiver implements RPCBoolReceiver implements RPCStringReceiver {
	public final log:Array<String> = [];
	public final failures:Array<RPCFailure> = [];
	public final failureCalls:Array<Int> = [];

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		log.push('$call int $value');
	}

	public function onFloat(call:Int, value:Float):Void {
		log.push('$call float $value');
	}

	public function onBool(call:Int, value:Bool):Void {
		log.push('$call bool $value');
	}

	public function onString(call:Int, value:String):Void {
		log.push('$call string $value');
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		failureCalls.push(call);
		failures.push(failure);
	}
}

private class Values<T> implements RPCValueReceiver<T> {
	public final calls:Array<Int> = [];
	public final values:Array<T> = [];
	public final failures:Array<RPCFailure> = [];

	public function new() {}

	public function onValue(call:Int, value:T):Void {
		calls.push(call);
		values.push(value);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		failures.push(failure);
	}
}

/** Adds one each time it is answered, until it has `limit` answers. **/
private class Chain implements RPCIntReceiver {
	public final values:Array<Int> = [];

	final commands:ReceiverCommands;
	final limit:Int;

	public function new(commands:ReceiverCommands, limit:Int) {
		this.commands = commands;
		this.limit = limit;
	}

	public function onInt(call:Int, value:Int):Void {
		values.push(value);
		if (values.length < limit) {
			commands.addThen(value, 1, this);
		}
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		values.push(-1);
	}
}

private class Thrower implements RPCIntReceiver {
	public var told:Int = 0;

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		told++;
		throw "the receiver failed";
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		told++;
		throw "the receiver failed again";
	}
}

private class ReceiverCommands extends RPCCommands {
	public function new() {}

	@:rpc public function add(a:Int, b:Int):RPCResponse<Int> {}

	@:rpc public function half(value:Int):RPCResponse<Float> {}

	@:rpc public function odd(value:Int):RPCResponse<Bool> {}

	@:rpc public function name(id:Int):RPCResponse<String> {}

	@:rpc public function small(value:Int):RPCResponse<Int8> {}

	@:rpc public function byte(value:Int):RPCResponse<UInt8> {}

	@:rpc public function short(value:Int):RPCResponse<Int16> {}

	@:rpc public function word(value:Int):RPCResponse<UInt16> {}

	@:rpc public function unsigned(value:Int):RPCResponse<UInt> {}

	@:rpc public function single(value:Float):RPCResponse<Float32> {}

	@:rpc public function colour(value:Int):RPCResponse<ReceiverColour> {}

	@:rpc public function spot(value:Int):RPCResponse<ReceiverSpot> {}

	@:rpc public function list(count:Int):RPCResponse<Array<Int>> {}

	@:rpc public function mood(level:Int):RPCResponse<ReceiverMood> {}

	@:rpc public function blob(length:Int):RPCResponse<Bytes> {}

	@:rpc public function maybe(present:Bool):RPCResponse<Null<Int>> {}

	@:rpc public function refuse(value:Int):RPCResponse<Int> {}

	@:rpc public function breakDown(value:Int):RPCResponse<Int> {}

	@:rpc public function missing(value:Int):RPCResponse<Int> {}

	@:rpc public function slow(key:String):RPCResponse<String> {}

	@:rpc public function echo(text:String):RPCResponse<String> {}

	public inline function breakThen(value:Int, receiver:RPCIntReceiver):Int {
		return breakDownThen(value, receiver);
	}
}

private class ReceiverHandler extends RPCHandler {
	public final pending = new Map<String, Completer<String>>();

	public function new() {}

	@:rpc public function add(a:Int, b:Int):Int {
		return a + b;
	}

	@:rpc public function half(value:Int):Float {
		return value / 2;
	}

	@:rpc public function odd(value:Int):Bool {
		return value % 2 == 1;
	}

	@:rpc public function name(id:Int):String {
		return 'player $id';
	}

	@:rpc public function small(value:Int):Int8 {
		return value;
	}

	@:rpc public function byte(value:Int):UInt8 {
		return value;
	}

	@:rpc public function short(value:Int):Int16 {
		return value;
	}

	@:rpc public function word(value:Int):UInt16 {
		return value;
	}

	@:rpc public function unsigned(value:Int):UInt {
		return value;
	}

	@:rpc public function single(value:Float):Float32 {
		return value * 2;
	}

	@:rpc public function colour(value:Int):ReceiverColour {
		return value == 2 ? Green : Red;
	}

	@:rpc public function spot(value:Int):ReceiverSpot {
		return {x: value, y: value * 2};
	}

	@:rpc public function list(count:Int):Array<Int> {
		return [for (i in 0...count) i];
	}

	@:rpc public function mood(level:Int):ReceiverMood {
		return level == 0 ? Calm : Angry(level);
	}

	@:rpc public function blob(length:Int):Bytes {
		return Bytes.ofString("abcdef".substr(0, length));
	}

	@:rpc public function maybe(present:Bool):Null<Int> {
		return present ? 9 : null;
	}

	@:rpc public function refuse(value:Int):Int {
		throw new RPCError("not today");
	}

	@:rpc public function breakDown(value:Int):Int {
		throw "broken";
	}

	@:rpc public function slow(key:String):Future<String> {
		var completer = new Completer<String>();
		pending.set(key, completer);
		return completer.future;
	}

	@:rpc public function echo(text:String):String {
		return text;
	}
}

@:rpcContract(ReceiverContract)
private class ContractCommands extends RPCCommands {
	public function new() {}
}

private class ContractHandler extends RPCHandler implements ReceiverContract {
	public function new() {}

	public function total(a:Int, b:Int):Int {
		return a + b;
	}

	public function label(id:Int):String {
		return 'label $id';
	}
}

private class MoreCommands extends ReceiverCommands {
	@:rpc public function triple(value:Int):RPCResponse<Int> {}
}

private class MoreHandler extends ReceiverHandler {
	@:rpc public function triple(value:Int):Int {
		return value * 3;
	}
}
