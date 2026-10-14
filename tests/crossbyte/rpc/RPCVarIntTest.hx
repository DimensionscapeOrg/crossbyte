package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import utest.Assert;

/**
	`VarUInt` and `VarInt` on the compiled lane: an `Int` as an unsigned
	LEB128 varint, or zigzagged and then one, in one to five bytes, as
	protobuf's `uint32` and `sint32`. All 32 bits arrive, so a tick that has
	wrapped past 2^31 - 1 carries on.
**/
class RPCVarIntTest extends utest.Test {
	public function testEveryIntArrivesAsSent():Void {
		final fixture = new VarFixture();
		final values:Array<Int> = [0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 268435456, 0x7FFFFFFF, -1, -2, -2147483647 - 1];
		for (value in values) {
			fixture.commands.both(value, value);
		}
		Assert.same([for (value in values) value + " " + value], fixture.handler.calls);
	}

	public function testEachTakesTheBytesItsValueNeeds():Void {
		// tick 1000 is two bytes and 36,000 three, where an Int is four; a
		// wrapped tick (negative) is five, and back the same.
		Assert.equals("e807", argumentsOf(commands -> commands.tick(1000)));
		Assert.equals("a09902", argumentsOf(commands -> commands.tick(36000)));
		Assert.equals("7f", argumentsOf(commands -> commands.tick(127)));
		Assert.equals("8001", argumentsOf(commands -> commands.tick(128)));
		Assert.equals("ffffffff0f", argumentsOf(commands -> commands.tick(-1)));
		Assert.equals("8580808008", argumentsOf(commands -> commands.tick(-2147483647 - 1 + 5)));
		// Zigzag: small magnitudes of either sign in a byte.
		Assert.equals("00" + "01", argumentsOf(commands -> commands.both(0, -1)));
		Assert.equals("00" + "7f", argumentsOf(commands -> commands.both(0, -64)));
		Assert.equals("00" + "8001", argumentsOf(commands -> commands.both(0, 64)));
		Assert.equals("00" + "feffffff0f", argumentsOf(commands -> commands.both(0, 0x7FFFFFFF)));
		Assert.equals("00" + "ffffffff0f", argumentsOf(commands -> commands.both(0, -2147483647 - 1)));
	}

	public function testAWrappedTickComesBackTheSame():Void {
		final fixture = new VarFixture();
		final wrapped:Int = -2147483647 - 1 + 5;
		Assert.equals(wrapped, (fixture.commands.echo(wrapped).result : Int));
		Assert.equals(-1, (fixture.commands.echo(-1).result : Int));
		final told = new VarReceiver();
		fixture.commands.echoThen(wrapped, told);
		Assert.equals(wrapped, told.got);
	}

	public function testArraysAndAbsenceCarryVarints():Void {
		final fixture = new VarFixture();
		final ticks:Array<VarUInt> = [1, 300, -1];
		final offsets:Array<Null<VarInt>> = [-3, null, 70000];
		Assert.equals("1,300,-1 -3,null,70000", fixture.commands.lists(ticks, offsets).result);
		Assert.equals("null", fixture.commands.maybe(null).result);
		Assert.equals("9", fixture.commands.maybe(9).result);
	}

	public function testOperatorsWorkOnTheIntItHolds():Void {
		var tick:VarUInt = 1000;
		var delta:VarInt = -3;
		Assert.equals(997, tick + delta);
		Assert.isTrue(tick > 999);
		Assert.isTrue(delta < 0);
		Assert.equals(1001, tick + 1);
		final next:VarUInt = tick + 1;
		Assert.equals(1001, (next : Int));
	}

	public function testTheirKindsAreInTheOp():Void {
		final fixture = new VarFixture();
		var unreadable:Bool = false;
		fixture.server.onUnreadableFrame = (op, id, reason) -> unreadable = true;
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("both(vu,vi)"));
			out.writeVarUInt(300);
			out.writeVarUInt(5); // -3 zigzagged
		}));
		Assert.isFalse(unreadable);
		Assert.same(["300 -3"], fixture.handler.calls);
	}

	public function testAVarintRunningPastItsFrameIsUnreadable():Void {
		final fixture = new VarFixture();
		final answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("echo(vu):vu"));
			out.writeVarUInt(4);
			out.writeByte(0x80);
			out.writeByte(0x80);
		}));
		Assert.same(["4: " + RPCError.UNREADABLE_MESSAGE], answers);
		// Six bytes is more than 32 bits.
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("echo(vu):vu"));
			out.writeVarUInt(5);
			for (_ in 0...5) {
				out.writeByte(0xFF);
			}
			out.writeByte(0x01);
		}));
		Assert.same(["4: " + RPCError.UNREADABLE_MESSAGE, "5: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	// ------------------------------------------------------------------

	/** The hex of a one-way call's arguments, from a session that sends nowhere. **/
	static function argumentsOf(call:VarCommands->Void):String {
		final link = LinkedConnection.pair();
		final commands = new VarCommands();
		final session = new RPCSession<VarCommands>(link.client, commands);
		Assert.notNull(session);
		var last:String = "";
		link.server.readEnabled = true;
		link.server.onData = input -> {
			final bytes = haxe.io.Bytes.alloc(input.bytesAvailable);
			input.readBytes(bytes, 0, bytes.length);
			last = bytes.toHex();
		};
		call(commands);
		// Past the length, the flags and the op.
		return last.substr(18);
	}

	static function frameOf(write:ByteArrayOutput->Void):ByteArray {
		final payload = new ByteArrayOutput(64);
		write(payload);
		final frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}

	static function errorAnswersAt(connection:LinkedConnection):Array<String> {
		final answers:Array<String> = [];
		connection.readEnabled = true;
		connection.onData = input -> {
			while (input.bytesAvailable >= 4) {
				final end:Int = input.position + 4 + input.readInt();
				final flags:Int = input.readByte();
				input.readInt();
				if ((flags & RPCWire.FLAG_ERROR) != 0) {
					final id:Int = input.readVarUInt();
					answers.push(id + ": " + input.readVarUtf());
				}
				input.position = end;
			}
		};
		return answers;
	}
}

interface VarContract {
	function tick(tick:VarUInt):Void;
	function both(unsigned:VarUInt, signed:VarInt):Void;
	function echo(tick:VarUInt):VarUInt;
	function lists(ticks:Array<VarUInt>, offsets:Array<Null<VarInt>>):String;
	function maybe(tick:Null<VarUInt>):String;
}

@:rpcContract(VarContract)
private class VarCommands extends RPCCommands {
	public function new() {}
}

private class VarHandler extends RPCHandler implements VarContract {
	public final calls:Array<String> = [];

	public function new() {}

	public function tick(tick:VarUInt):Void {
		calls.push(Std.string((tick : Int)));
	}

	public function both(unsigned:VarUInt, signed:VarInt):Void {
		calls.push((unsigned : Int) + " " + (signed : Int));
	}

	public function echo(tick:VarUInt):VarUInt {
		return tick;
	}

	public function lists(ticks:Array<VarUInt>, offsets:Array<Null<VarInt>>):String {
		return [for (t in ticks) Std.string((t : Int))].join(",") + " "
			+ [for (o in offsets) o == null ? "null" : Std.string(((o : VarInt) : Int))].join(",");
	}

	public function maybe(tick:Null<VarUInt>):String {
		return tick == null ? "null" : Std.string(((tick : VarUInt) : Int));
	}
}

private class VarReceiver implements RPCIntReceiver {
	public var got:Int = 0;

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		got = value;
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {}
}

private class VarFixture {
	public final link = LinkedConnection.pair();
	public final commands = new VarCommands();
	public final handler = new VarHandler();
	public final client:RPCSession<VarCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<VarCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}
