package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.rpc.RPCEnumTest.Order;
import crossbyte.rpc.RPCEnumTest.Stance;
import crossbyte.rpc.RPCStructTest.StructPoint;
import crossbyte.rpc.RPCStructTest.StructSlot;
import utest.Assert;

typedef MaybePoint = Null<StructPoint>;

/**
	`Null<T>` of every kind the compiled lane carries (compact numbers,
	arrays, structures, enums) as arguments, as answers, inside arrays and
	structures, and named through a typedef: a byte saying whether the value
	is there, then the value if it is.
**/
class RPCNullTypesTest extends utest.Test {
	public function testEachKindThatMayBeAbsentArrivesAbsentOrPresent():Void {
		var fixture = new NullFixture();
		fixture.commands.all(null, null, null, null, null, null);
		var at = new StructPoint();
		at.x = 2;
		fixture.commands.all(250, 0.5, [1, null], at, {item: 3, count: 4}, Prone);
		Assert.same([
			"null null null null null null",
			"250 0.5 [1,null] 2 3x4 Prone"
		], fixture.handler.calls);
	}

	public function testOptionalArgumentsOfEachKindMayBeLeftOut():Void {
		var fixture = new NullFixture();
		fixture.commands.optional(1);
		var at = new StructPoint();
		at.y = 9;
		fixture.commands.optional(2, at, [Standing], Say("x"));
		Assert.same(["1: null null null", "2: 9 [Standing] Say"], fixture.handler.calls);
	}

	public function testAnAnswerOfEachKindMayBeAbsent():Void {
		var fixture = new NullFixture();
		Assert.isNull(fixture.commands.point(false).result);
		Assert.equals(5.0, (fixture.commands.point(true).result.x : Float));
		Assert.isNull(fixture.commands.stance(false).result);
		Assert.equals(Crouching, fixture.commands.stance(true).result);
		Assert.isNull(fixture.commands.slots(false).result);
		Assert.equals(1, fixture.commands.slots(true).result.length);
		Assert.isNull(fixture.commands.level(false).result);
		Assert.equals(77, (fixture.commands.level(true).result : Int));
	}

	public function testElementsAndFieldsThatMayBeAbsentCarryTheirAbsence():Void {
		var fixture = new NullFixture();
		var at = new StructPoint();
		at.x = 1;
		Assert.equals("[1,null] [null,Prone] [null]", fixture.commands.sparse([at, null], [null, Prone], [null]).result);
	}

	public function testAStructureThatMayBeAbsentThroughATypedefCarriesItsAbsence():Void {
		// A typedef of Null<StructPoint> on the client, Null<StructPoint>
		// written out on the server.
		var link = LinkedConnection.pair();
		var commands = new TypedefNullCommands();
		var handler = new NullHandler();
		var client = new RPCSession<TypedefNullCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);
		Assert.equals("absent", commands.where(null).result);
		var at = new StructPoint();
		at.x = 4;
		Assert.equals("4", commands.where(at).result);
		Assert.notNull(client);
		Assert.notNull(server);
	}

	public function testAnAbsentValueIsOneByte():Void {
		var link = LinkedConnection.pair();
		var commands = new NullCommands();
		var client = new RPCSession<NullCommands>(link.client, commands);
		var lengths:Array<Int> = [];
		link.server.readEnabled = true;
		link.server.onData = input -> {
			while (input.bytesAvailable >= 4) {
				final length:Int = input.readInt();
				lengths.push(length);
				input.position += length;
			}
		};
		lengths.resize(0);
		commands.all(null, null, null, null, null, null);
		// Flags, op, and a presence byte each.
		Assert.same([5 + 6], lengths);
		Assert.notNull(client);
	}
}

interface NullContract {
	function all(level:Null<UInt8>, speed:Null<Float32>, values:Null<Array<Null<Int>>>, at:Null<StructPoint>, slot:Null<StructSlot>,
		stance:Null<Stance>):Void;
	function optional(id:Int, ?at:StructPoint, ?stances:Array<Stance>, ?order:Order):Void;
	function point(present:Bool):Null<StructPoint>;
	function stance(present:Bool):Null<Stance>;
	function slots(present:Bool):Null<Array<StructSlot>>;
	function level(present:Bool):Null<UInt8>;
	function sparse(points:Array<Null<StructPoint>>, stances:Array<Null<Stance>>, slots:Array<Null<StructSlot>>):String;
	function where(at:Null<StructPoint>):String;
}

@:rpcContract(NullContract)
private class NullCommands extends RPCCommands {
	public function new() {}
}

private class NullHandler extends RPCHandler implements NullContract {
	public final calls:Array<String> = [];

	public function new() {}

	public function all(level:Null<UInt8>, speed:Null<Float32>, values:Null<Array<Null<Int>>>, at:Null<StructPoint>, slot:Null<StructSlot>,
			stance:Null<Stance>):Void {
		calls.push([
			level == null ? "null" : Std.string((level : Int)),
			speed == null ? "null" : Std.string((speed : Float)),
			values == null ? "null" : "[" + [for (v in values) v == null ? "null" : Std.string(v)].join(",") + "]",
			at == null ? "null" : Std.string((at.x : Float)),
			slot == null ? "null" : slot.item + "x" + slot.count,
			stance == null ? "null" : Std.string(stance)
		].join(" "));
	}

	public function optional(id:Int, ?at:StructPoint, ?stances:Array<Stance>, ?order:Order):Void {
		calls.push(id + ": " + (at == null ? "null" : Std.string((at.y : Float))) + " " + (stances == null ? "null" : Std.string(stances)) + " "
			+ (order == null ? "null" : Type.enumConstructor(order)));
	}

	public function point(present:Bool):Null<StructPoint> {
		if (!present) {
			return null;
		}
		var at = new StructPoint();
		at.x = 5;
		return at;
	}

	public function stance(present:Bool):Null<Stance> {
		return present ? Crouching : null;
	}

	public function slots(present:Bool):Null<Array<StructSlot>> {
		return present ? [{item: 1, count: 1}] : null;
	}

	public function level(present:Bool):Null<UInt8> {
		return present ? 77 : null;
	}

	public function sparse(points:Array<Null<StructPoint>>, stances:Array<Null<Stance>>, slots:Array<Null<StructSlot>>):String {
		return "[" + [for (p in points) p == null ? "null" : Std.string((p.x : Float))].join(",") + "] ["
			+ [for (s in stances) s == null ? "null" : Std.string(s)].join(",") + "] ["
			+ [for (s in slots) s == null ? "null" : Std.string(s.item)].join(",") + "]";
	}

	public function where(at:Null<StructPoint>):String {
		return at == null ? "absent" : Std.string((at.x : Float));
	}
}

private class NullFixture {
	public final link = LinkedConnection.pair();
	public final commands = new NullCommands();
	public final handler = new NullHandler();
	public final client:RPCSession<NullCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<NullCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

private class TypedefNullCommands extends RPCCommands {
	public function new() {}

	@:rpc public function where(at:MaybePoint):RPCResponse<String> {}
}
