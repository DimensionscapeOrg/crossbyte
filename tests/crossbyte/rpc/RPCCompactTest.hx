package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.FPHelper;
import utest.Assert;

enum abstract Team(Int) to Int {
	var Red = 1;
	var Blue = 2;
}

abstract PlayerName(String) from String to String {}

/**
	Compact numbers on the compiled lane, `Float32` (or `Single`), `Int8`,
	`UInt8`, `Int16`, `UInt16`, in fewer bytes than an `Int` or a `Float`,
	and abstracts carried as the type they abstract.
**/
class RPCCompactTest extends utest.Test {
	public function testEachCompactNumberArrivesAsSent():Void {
		var fixture = new CompactFixture();
		fixture.commands.pack(-128, 255, -32768, 65535, 1.5);
		fixture.commands.pack(127, 0, 32767, 0, -0.25);
		fixture.commands.pack(-1, 1, -1, 1, 0);
		Assert.same(["-128 255 -32768 65535 1.5", "127 0 32767 0 -0.25", "-1 1 -1 1 0"], fixture.handler.calls);
	}

	public function testAnIntNarrowsAsItBecomesOne():Void {
		// Assigned, an Int keeps its low bits, as a cast in C does, so what
		// is sent is what the sender holds.
		var fixture = new CompactFixture();
		var big:Int = 300;
		var wide:Int = 70000;
		var small:Int8 = 200;
		var byte:UInt8 = big;
		var short:Int16 = 40000;
		var unsigned:UInt16 = wide;
		Assert.equals(-56, (small : Int));
		Assert.equals(44, (byte : Int));
		Assert.equals(-25536, (short : Int));
		Assert.equals(4464, (unsigned : Int));
		fixture.commands.pack(small, byte, short, unsigned, 0);
		Assert.same(["-56 44 -25536 4464 0"], fixture.handler.calls);
	}

	public function testAFloat32IsRoundedToSinglePrecisionOnEveryTarget():Void {
		var fixture = new CompactFixture();
		var single:Float = FPHelper.i32ToFloat(FPHelper.floatToI32(0.1));
		Assert.notEquals(0.1, single);
		Assert.floatEquals(single, fixture.commands.scale(0.1).result, 0.0);
		Assert.isTrue(Math.isNaN(fixture.commands.scale(Math.NaN).result));
		Assert.equals(Math.POSITIVE_INFINITY, fixture.commands.scale(Math.POSITIVE_INFINITY).result);
		// Past a single's range: infinity, as a C cast gives.
		Assert.equals(Math.POSITIVE_INFINITY, fixture.commands.scale(1e300).result);
	}

	public function testCompactNumbersTakeTheirBytesOnTheWire():Void {
		// The frame's payload: flags, op, then 1 + 1 + 2 + 2 + 4 bytes.
		var link = LinkedConnection.pair();
		var commands = new CompactCommands();
		var client = new RPCSession<CompactCommands>(link.client, commands);
		var lengths:Array<Int> = [];
		link.server.readEnabled = true;
		link.server.onData = input -> {
			while (input.bytesAvailable >= 4) {
				final length:Int = input.readInt();
				lengths.push(length);
				input.position += length;
			}
		};
		// The hello, then the call.
		lengths.resize(0);
		commands.pack(1, 2, 3, 4, 5);
		Assert.same([5 + 10], lengths);
		lengths.resize(0);
		// The same values as Ints and a Float: 4 + 4 + 4 + 4 + 8.
		commands.wide(1, 2, 3, 4, 5);
		Assert.same([5 + 24], lengths);
		Assert.notNull(client);
	}

	public function testACompactNumbersKindIsInTheOp():Void {
		var fixture = new CompactFixture();
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("pack(i8,u8,i16,u16,f32)"));
			out.writeByte(0xFF);
			out.writeByte(0xFF);
			out.writeByte(0x00);
			out.writeByte(0x80);
			out.writeByte(0x34);
			out.writeByte(0x12);
			out.writeInt(FPHelper.floatToI32(2.5));
		}));
		Assert.same(["-1 255 -32768 4660 2.5"], fixture.handler.calls);
	}

	public function testAnIntWhereACompactNumberWasIsAnotherMethod():Void {
		// `(i32)` against `(u8)`: another op, answered as a method not there,
		// rather than one byte of four read as the value.
		var link = LinkedConnection.pair();
		var commands = new OldCommands();
		var handler = new CompactHandler();
		var client = new RPCSession<OldCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);
		var answer = commands.level(7);
		Assert.isFalse(answer.succeeded);
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, answer.error);
		Assert.notNull(client);
		Assert.notNull(server);
	}

	public function testArraysOfCompactNumbersArriveAsSent():Void {
		var fixture = new CompactFixture();
		var levels:Array<UInt8> = [0, 1, 255, 256];
		var heights:Array<Int16> = [-1, 32767, -32768];
		var weights:Array<Float32> = [1.5, -2.25];
		var gaps:Array<Null<UInt16>> = [65535, null, 3];
		fixture.commands.lists(levels, heights, weights, gaps);
		Assert.same(["[0,1,255,0] [-1,32767,-32768] [1.5,-2.25] [65535,null,3]"], fixture.handler.calls);
	}

	public function testCompactNumbersThatMayBeAbsentCarryTheirAbsence():Void {
		var fixture = new CompactFixture();
		Assert.equals("null null", fixture.commands.maybe(null, null).result);
		Assert.equals("200 -0.5", fixture.commands.maybe(200, -0.5).result);
	}

	public function testAnAbstractIsTheKindOfWhatItAbstracts():Void {
		var fixture = new CompactFixture();
		Assert.equals("Blue:shadow:all", fixture.commands.tag(Blue, "shadow", 0xFFFFFFFF).result);
		var sameOp = RPCOps.opOf("tag(i32,utf8,i32):utf8");
		var found:Bool = false;
		fixture.server.onUnreadableFrame = (op, id, reason) -> found = true;
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(sameOp);
			out.writeVarUInt(9);
			out.writeInt(1);
			out.writeVarUTF("x");
			out.writeInt(5);
		}));
		Assert.isFalse(found, "an abstract's op was not its underlying type's");
	}

	public function testAFloat32CutShortIsUnreadable():Void {
		var fixture = new CompactFixture();
		var answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("scale(f32):f32"));
			out.writeVarUInt(3);
			out.writeByte(0);
			out.writeByte(0);
		}));
		Assert.same(["3: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	#if (cpp || java || hl)
	public function testHaxesOwnSingleIsAFloat32():Void {
		// Declared as Single on one side and as Float32 on the other.
		var link = LinkedConnection.pair();
		var commands = new SingleCommands();
		var handler = new CompactHandler();
		var client = new RPCSession<SingleCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);
		var value:Single = 3.25;
		Assert.floatEquals(6.5, commands.scale(value).result, 0.0);
		Assert.notNull(client);
		Assert.notNull(server);
	}
	#end

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

interface CompactContract {
	function pack(a:Int8, b:UInt8, c:Int16, d:UInt16, e:Float32):Void;
	function wide(a:Int, b:Int, c:Int, d:Int, e:Float):Void;
	function scale(value:Float32):Float32;
	function lists(levels:Array<UInt8>, heights:Array<Int16>, weights:Array<Float32>, gaps:Array<Null<UInt16>>):Void;
	function maybe(level:Null<UInt8>, weight:Null<Float32>):String;
	function tag(team:Team, name:PlayerName, mask:UInt):String;
	function level(value:UInt8):Int;
}

@:rpcContract(CompactContract)
private class CompactCommands extends RPCCommands {
	public function new() {}
}

private class CompactHandler extends RPCHandler implements CompactContract {
	public final calls:Array<String> = [];

	public function new() {}

	public function pack(a:Int8, b:UInt8, c:Int16, d:UInt16, e:Float32):Void {
		calls.push(a + " " + b + " " + c + " " + d + " " + (e : Float));
	}

	public function wide(a:Int, b:Int, c:Int, d:Int, e:Float):Void {}

	public function scale(value:Float32):Float32 {
		// Twice 3.25, for the test of Single; anything else as it came.
		return (value : Float) == 3.25 ? 6.5 : value;
	}

	public function lists(levels:Array<UInt8>, heights:Array<Int16>, weights:Array<Float32>, gaps:Array<Null<UInt16>>):Void {
		calls.push(show(levels) + " " + show(heights) + " " + show([for (w in weights) (w : Float)]) + " " + show(gaps));
	}

	public function maybe(level:Null<UInt8>, weight:Null<Float32>):String {
		return (level == null ? "null" : Std.string((level : Int))) + " " + (weight == null ? "null" : Std.string((weight : Float)));
	}

	public function tag(team:Team, name:PlayerName, mask:UInt):String {
		return (team == Blue ? "Blue" : "Red") + ":" + name + ":" + (mask == (0xFFFFFFFF : UInt) ? "all" : "some");
	}

	public function level(value:UInt8):Int {
		return value;
	}

	static function show<T>(values:Array<T>):String {
		return "[" + [for (value in values) value == null ? "null" : Std.string(value)].join(",") + "]";
	}
}

private class CompactFixture {
	public final link = LinkedConnection.pair();
	public final commands = new CompactCommands();
	public final handler = new CompactHandler();
	public final client:RPCSession<CompactCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<CompactCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

/** An older client, whose `level` took an Int. **/
private class OldCommands extends RPCCommands {
	public function new() {}

	@:rpc public function level(value:Int):RPCResponse<Int> {}
}

#if (cpp || java || hl)
private class SingleCommands extends RPCCommands {
	public function new() {}

	@:rpc public function scale(value:Single):RPCResponse<Single> {}
}
#end
