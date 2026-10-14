package crossbyte.rpc;

import utest.Assert;

/**
	`@:reuse`: an argument read into what the handler's session keeps for
	it, valid during the call: a structure's fields set in place, an array's
	element instances kept, a map cleared and refilled. On a handler's
	argument, on a contract method (naming its arguments), or on the handler
	class. Nothing changes on the wire.
**/
class RPCReuseTest extends utest.Test {
	public function testAnArrayAndItsElementsAreKeptFromCallToCall():Void {
		final fixture = new ReuseFixture();
		fixture.commands.inputs(5, 1000, [input(1, 16384, 997), input(1, 16384, 998), input(5, 16400, 999), input(1, 16420, 1000)]);
		final first = fixture.handler.lastRecent;
		final element = first[2];
		Assert.equals("1:16384,1:16384,5:16400,1:16420", fixture.handler.lastSeen);
		fixture.commands.inputs(6, 1001, [input(2, 1, 998), input(3, 2, 999), input(4, 3, 1000), input(5, 4, 1001)]);
		Assert.isTrue(first == fixture.handler.lastRecent, "the array was made again");
		Assert.isTrue(element == fixture.handler.lastRecent[2], "an element was made again");
		Assert.equals("2:1,3:2,4:3,5:4", fixture.handler.lastSeen);
		// Fewer, then more, than before.
		fixture.commands.inputs(7, 1002, [input(9, 9, 1)]);
		Assert.equals("9:9", fixture.handler.lastSeen);
		fixture.commands.inputs(8, 1003, [for (i in 0...6) input(i, i, i)]);
		Assert.equals("0:0,1:1,2:2,3:3,4:4,5:5", fixture.handler.lastSeen);
		Assert.isTrue(first == fixture.handler.lastRecent);
	}

	public function testAStructureIsReadInPlaceItsNestedOnesToo():Void {
		final fixture = new ReuseFixture();
		final state = new ReuseState();
		state.tick = 3;
		state.label = "a";
		state.where.x = 1.5;
		state.history = [1, 2, 3];
		state.tags.set("k", 1);
		fixture.commands.update(state);
		final kept = fixture.handler.lastState;
		final nested = kept.where;
		final history = kept.history;
		Assert.equals("3 a 1.5 1,2,3 k=1", fixture.handler.lastSeen);
		state.tick = 4;
		state.label = "b";
		state.where.x = -2;
		state.history = [9];
		state.tags = ["z" => 26];
		fixture.commands.update(state);
		Assert.isTrue(kept == fixture.handler.lastState, "the structure was made again");
		Assert.isTrue(nested == kept.where, "its nested structure was made again");
		Assert.isTrue(history == kept.history, "its array was made again");
		Assert.equals("4 b -2 9 z=26", fixture.handler.lastSeen);
	}

	public function testAHandlerClassMarkedKeepsEveryArgument():Void {
		final fixture = new ReuseFixture(new ReuseEverything());
		final everything:ReuseEverything = cast fixture.handler;
		fixture.commands.update(new ReuseState());
		fixture.commands.inputs(1, 1, [input(1, 1, 1)]);
		final state = everything.lastState;
		final recent = everything.lastRecent;
		fixture.commands.update(new ReuseState());
		fixture.commands.inputs(2, 2, [input(2, 2, 2)]);
		Assert.isTrue(state == everything.lastState);
		Assert.isTrue(recent == everything.lastRecent);
	}

	public function testAnArgumentNotMarkedIsTheHandlersToKeep():Void {
		final fixture = new ReuseFixture();
		fixture.commands.keep([input(1, 1, 1)]);
		final first = fixture.handler.lastKept;
		fixture.commands.keep([input(2, 2, 2)]);
		Assert.isFalse(first == fixture.handler.lastKept, "an argument not marked @:reuse was reused");
		Assert.equals(1, first[0].controls);
	}

	public function testEachSessionKeepsItsOwn():Void {
		final handler = new ReuseHandler();
		final a = new ReuseFixture(handler);
		final b = new ReuseFixture(handler);
		a.commands.inputs(1, 1, [input(1, 1, 1)]);
		final fromA = handler.lastRecent;
		b.commands.inputs(1, 1, [input(2, 2, 2)]);
		Assert.isFalse(fromA == handler.lastRecent, "two sessions shared what they keep");
		Assert.equals(1, fromA[0].controls);
		a.commands.inputs(2, 2, [input(3, 3, 3)]);
		Assert.isTrue(fromA == handler.lastRecent);
	}

	public function testNothingChangesOnTheWire():Void {
		// The same op as a handler that keeps nothing: a peer of either kind answers.
		final plain = new ReuseNothing();
		final fixture = new ReuseFixture(null, plain);
		fixture.commands.inputs(5, 6, [input(7, 8, 9)]);
		Assert.equals("5 6 7:8", plain.lastSeen);
	}

	static function input(controls:Int, aim:Int, seq:Int):ReuseInput {
		final i = new ReuseInput();
		i.controls = controls;
		i.aimSteps = aim;
		i.seq = seq;
		return i;
	}
}

class ReuseInput implements RPCStruct {
	public var aimSteps:UInt16 = 0;
	public var controls:UInt8 = 0;
	public var seq:VarUInt = 0;

	public function new() {}
}

class ReuseWhere implements RPCStruct {
	public var x:Float = 0;
	public var y:Float = 0;

	public function new() {}
}

class ReuseState implements RPCStruct {
	public var tick:Int = 0;
	public var label:String = "";
	public var where:ReuseWhere = new ReuseWhere();
	public var history:Array<Int> = [];
	public var tags:Map<String, Int> = new Map();

	public function new() {}
}

interface ReuseContract {
	function inputs(ack:VarUInt, newest:VarUInt, recent:Array<ReuseInput>):Void;
	@:reuse(state) function update(state:ReuseState):Void;
	function keep(recent:Array<ReuseInput>):Void;
}

@:rpcContract(ReuseContract)
private class ReuseCommands extends RPCCommands {
	public function new() {}
}

private class ReuseHandler extends RPCHandler implements ReuseContract {
	public var lastRecent:Null<Array<ReuseInput>> = null;
	public var lastKept:Null<Array<ReuseInput>> = null;
	public var lastState:Null<ReuseState> = null;
	public var lastSeen:String = "";

	public function new() {}

	public function inputs(ack:VarUInt, newest:VarUInt, @:reuse recent:Array<ReuseInput>):Void {
		lastRecent = recent;
		lastSeen = [for (i in recent) i.controls + ":" + (i.aimSteps : Int)].join(",");
	}

	public function update(state:ReuseState):Void {
		lastState = state;
		lastSeen = state.tick + " " + state.label + " " + state.where.x + " " + state.history.join(",") + " "
			+ [for (key => value in state.tags) key + "=" + value].join(",");
	}

	public function keep(recent:Array<ReuseInput>):Void {
		lastKept = recent;
	}
}

@:reuse
private class ReuseEverything extends ReuseHandler {
	public function new() {
		super();
	}
}

private class ReuseNothing extends RPCHandler implements ReuseContract {
	public var lastSeen:String = "";

	public function new() {}

	public function inputs(ack:VarUInt, newest:VarUInt, recent:Array<ReuseInput>):Void {
		lastSeen = (ack : Int) + " " + (newest : Int) + " " + [for (i in recent) i.controls + ":" + (i.aimSteps : Int)].join(",");
	}

	public function update(state:ReuseState):Void {}

	public function keep(recent:Array<ReuseInput>):Void {}
}

private class ReuseFixture {
	public final link = LinkedConnection.pair();
	public final commands = new ReuseCommands();
	public final handler:ReuseHandler;
	public final client:RPCSession<ReuseCommands>;
	public final server:RPCSession<Dynamic>;

	public function new(?handler:ReuseHandler, ?other:RPCHandler<Dynamic, Dynamic>) {
		this.handler = handler != null ? handler : new ReuseHandler();
		client = new RPCSession<ReuseCommands>(link.client, commands);
		server = new RPCSession(link.server, null, other != null ? other : this.handler);
	}
}
