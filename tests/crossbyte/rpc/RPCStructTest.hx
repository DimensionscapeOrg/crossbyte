package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.FPHelper;
import utest.Assert;

/** A point, as a class. **/
class StructPoint implements RPCStruct {
	public var y:Float32 = 0;
	public var x:Float32 = 0;

	public function new() {}
}

/** The same fields as `StructPoint`, as a typedef, declared the other way round. **/
typedef PointShape = {
	var x:Float32;
	var y:Float32;
}

/** Fields of most kinds, a nested structure, an optional one and one left off the wire. **/
class StructUnit implements RPCStruct {
	public var id:Int = 0;
	public var name:String = "";
	public var level:UInt8 = 0;
	public var at:StructPoint = new StructPoint();
	public var path:Array<StructPoint> = [];
	public var note:Null<String> = null;
	public var tags:Array<String> = [];
	@:rpcSkip public var cache:Map<String, Int> = new Map();
	@:rpcSkip public var sprite:String = "default";

	public function new() {}
}

/** An item and a count, as a typedef: what an inventory holds. **/
typedef StructSlot = {
	var item:Int;
	var count:UInt16;
	@:optional var label:String;
}

/** Fields pinned ahead of the rest, in the order of their ids. **/
class StructPinned implements RPCStruct {
	@:field(2) public var b:Int = 0;
	@:field(1) public var z:Int = 0;
	public var a:Int = 0;

	public function new() {}
}

/** A subclass's fields and its parent's go out together. **/
class StructBase implements RPCStruct {
	public var base:Int = 0;
	private var hidden:Int = 0;

	public function new() {}

	public function getHidden():Int {
		return hidden;
	}

	public function setHidden(value:Int):Void {
		hidden = value;
	}
}

class StructDerived extends StructBase {
	public var extra:String = "";

	public function new() {
		super();
	}
}

/**
	Structures on the compiled lane: classes that implement `RPCStruct`, and
	anonymous structures, positional on the wire, their fields in the order
	of their names or of their pinned ids, and their shape in the op.
**/
class RPCStructTest extends utest.Test {
	public function testAClassArrivesWithEveryField():Void {
		var fixture = new StructFixture();
		var unit = new StructUnit();
		unit.id = 7;
		unit.name = "scout";
		unit.level = 3;
		unit.at.x = 1.5;
		unit.at.y = -2;
		unit.path = [point(1, 2), point(3, 4)];
		unit.note = "fast";
		unit.tags = ["a", "b"];
		unit.sprite = "red";
		unit.cache.set("k", 1);
		fixture.commands.spawn(unit);
		Assert.equals(1, fixture.handler.units.length);
		var got = fixture.handler.units[0];
		Assert.equals(7, got.id);
		Assert.equals("scout", got.name);
		Assert.equals(3, (got.level : Int));
		Assert.equals(1.5, (got.at.x : Float));
		Assert.equals(-2.0, (got.at.y : Float));
		Assert.equals(2, got.path.length);
		Assert.equals(4.0, (got.path[1].y : Float));
		Assert.equals("fast", got.note);
		Assert.same(["a", "b"], got.tags);
		// Off the wire: what the constructor gave.
		Assert.equals("default", got.sprite);
		Assert.isFalse(got.cache.exists("k"));
		Assert.isFalse(got == unit);
	}

	public function testAnOptionalFieldCarriesItsAbsence():Void {
		var fixture = new StructFixture();
		var unit = new StructUnit();
		unit.note = null;
		fixture.commands.spawn(unit);
		Assert.isNull(fixture.handler.units[0].note);
	}

	public function testATypedefArrivesAsAnObject():Void {
		var fixture = new StructFixture();
		var slots:Array<StructSlot> = [{item: 4, count: 65535}, {item: -1, count: 0, label: "x"}];
		Assert.equals("4x65535, -1x0:x", fixture.commands.stock(slots).result);
		var echoed = fixture.commands.first(slots).result;
		Assert.equals(4, echoed.item);
		Assert.equals(65535, (echoed.count : Int));
		Assert.isNull(echoed.label);
	}

	public function testAClassAndATypedefWithTheSameFieldsAreOneShape():Void {
		// The client sends a class, the server reads a typedef with its
		// fields declared the other way round: one op, one layout.
		var link = LinkedConnection.pair();
		var commands = new ClassSideCommands();
		var handler = new TypedefSideHandler();
		var client = new RPCSession<ClassSideCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);
		Assert.equals(3.5, commands.length(point(1.5, 2)).result);
		Assert.notNull(client);
		Assert.notNull(server);
	}

	public function testFieldsGoInTheOrderOfTheirNames():Void {
		// x then y, whatever order StructPoint declares them in: a frame
		// framed by hand that way reaches the method of that shape.
		var fixture = new StructFixture();
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("aim({x:f32,y:f32})"));
			out.writeInt(FPHelper.floatToI32(0.5));
			out.writeInt(FPHelper.floatToI32(8));
		}));
		Assert.same(["0.5,8"], fixture.handler.aims);
	}

	public function testPinnedFieldsGoFirstInTheOrderOfTheirIds():Void {
		var fixture = new StructFixture();
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("pin({1=z:i32,2=b:i32,a:i32})"));
			out.writeInt(10);
			out.writeInt(20);
			out.writeInt(30);
		}));
		Assert.same(["z10 b20 a30"], fixture.handler.pins);
		var pinned = new StructPinned();
		pinned.z = 1;
		pinned.b = 2;
		pinned.a = 3;
		fixture.commands.pin(pinned);
		Assert.same(["z10 b20 a30", "z1 b2 a3"], fixture.handler.pins);
	}

	public function testASubclassCarriesItsParentsFieldsPrivateOnesToo():Void {
		var fixture = new StructFixture();
		var derived = new StructDerived();
		derived.base = 5;
		derived.setHidden(6);
		derived.extra = "seven";
		var back = fixture.commands.derive(derived).result;
		Assert.equals(5, back.base);
		Assert.equals(6, back.getHidden());
		Assert.equals("seven!", back.extra);
	}

	public function testAFieldRenamedIsAnotherMethod():Void {
		var link = LinkedConnection.pair();
		var commands = new RenamedCommands();
		var handler = new TypedefSideHandler();
		var client = new RPCSession<RenamedCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);
		var answer = commands.length({x: 1, z: 2});
		Assert.isFalse(answer.succeeded);
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, answer.error);
		Assert.notNull(client);
		Assert.notNull(server);
	}

	public function testANullStructureIsRefusedAndTheFrameGivenBack():Void {
		var fixture = new StructFixture();
		var sent:Int = fixture.link.client.sent;
		Assert.raises(() -> fixture.commands.spawn(null), ArgumentError);
		// A null inside, where the field cannot be absent.
		var unit = new StructUnit();
		unit.at = null;
		Assert.raises(() -> fixture.commands.spawn(unit), ArgumentError);
		var other = new StructUnit();
		other.path = [point(1, 1), null];
		Assert.raises(() -> fixture.commands.spawn(other), ArgumentError);
		var named = new StructUnit();
		named.name = null;
		Assert.raises(() -> fixture.commands.spawn(named), ArgumentError);
		Assert.equals(sent, fixture.link.client.sent, "a structure with a null where a value has to be was sent");
		Assert.isFalse(@:privateAccess fixture.client.__frame.busy, "the frame was left taken");
		fixture.commands.spawn(new StructUnit());
		Assert.equals(1, fixture.handler.units.length);
	}

	public function testAStructureThatMayBeAbsentCarriesItsAbsence():Void {
		var fixture = new StructFixture();
		Assert.equals("none", fixture.commands.maybe(null).result);
		Assert.equals("1.5,2", fixture.commands.maybe(point(1.5, 2)).result);
	}

	public function testAStructureCutShortIsUnreadable():Void {
		var fixture = new StructFixture();
		var answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("maybe(?{x:f32,y:f32}):utf8"));
			out.writeVarUInt(5);
			out.writeByte(1);
			out.writeInt(0);
		}));
		Assert.same(["5: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	public function testACountOfStructuresPastTheFrameIsUnreadable():Void {
		// Each slot takes at least seven bytes: four, two and a presence byte.
		var fixture = new StructFixture();
		var answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("stock([{count:u16,item:i32,label:?utf8}]):utf8"));
			out.writeVarUInt(6);
			out.writeVarUInt(2);
			for (_ in 0...8) {
				out.writeByte(0);
			}
		}));
		Assert.same(["6: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	static function point(x:Float, y:Float):StructPoint {
		var p = new StructPoint();
		p.x = x;
		p.y = y;
		return p;
	}

	static function frameOf(write:ByteArrayOutput->Void):ByteArray {
		var payload = new ByteArrayOutput(64);
		write(payload);
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}

	static function errorAnswersAt(connection:LinkedConnection):Array<String> {
		var answers:Array<String> = [];
		connection.readEnabled = true;
		connection.onData = input -> {
			while (input.bytesAvailable >= 4) {
				final end:Int = input.position + 4 + input.readInt();
				final flags:Int = input.readByte();
				input.readInt();
				if ((flags & RPCWire.FLAG_ERROR) != 0) {
					final id:Int = input.readVarUInt();
					answers.push(id + ": " + input.readVarUTF());
				}
				input.position = end;
			}
		};
		return answers;
	}
}

interface StructContract {
	function spawn(unit:StructUnit):Void;
	function stock(slots:Array<StructSlot>):String;
	function first(slots:Array<StructSlot>):StructSlot;
	function aim(at:StructPoint):Void;
	function pin(pinned:StructPinned):Void;
	function derive(value:StructDerived):StructDerived;
	function maybe(at:Null<StructPoint>):String;
}

@:rpcContract(StructContract)
private class StructCommands extends RPCCommands {
	public function new() {}
}

private class StructHandler extends RPCHandler implements StructContract {
	public final units:Array<StructUnit> = [];
	public final aims:Array<String> = [];
	public final pins:Array<String> = [];

	public function new() {}

	public function spawn(unit:StructUnit):Void {
		units.push(unit);
	}

	public function stock(slots:Array<StructSlot>):String {
		return [for (slot in slots) slot.item + "x" + slot.count + (slot.label != null ? ":" + slot.label : "")].join(", ");
	}

	public function first(slots:Array<StructSlot>):StructSlot {
		return slots[0];
	}

	public function aim(at:StructPoint):Void {
		aims.push((at.x : Float) + "," + (at.y : Float));
	}

	public function pin(pinned:StructPinned):Void {
		pins.push("z" + pinned.z + " b" + pinned.b + " a" + pinned.a);
	}

	public function derive(value:StructDerived):StructDerived {
		value.extra += "!";
		return value;
	}

	public function maybe(at:Null<StructPoint>):String {
		return at == null ? "none" : (at.x : Float) + "," + (at.y : Float);
	}
}

private class StructFixture {
	public final link = LinkedConnection.pair();
	public final commands = new StructCommands();
	public final handler = new StructHandler();
	public final client:RPCSession<StructCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<StructCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

private class ClassSideCommands extends RPCCommands {
	public function new() {}

	@:rpc public function length(at:StructPoint):RPCResponse<Float> {}
}

private class TypedefSideHandler extends RPCHandler {
	public function new() {}

	@:rpc public function length(at:PointShape):Float {
		return (at.x : Float) + (at.y : Float);
	}
}

private class RenamedCommands extends RPCCommands {
	public function new() {}

	@:rpc public function length(at:{x:Float32, z:Float32}):RPCResponse<Float> {}
}
