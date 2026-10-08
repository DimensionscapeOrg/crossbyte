package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc.RPCStructTest.StructPoint;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.FPHelper;
import utest.Assert;

/** A simple enum: its index, one byte. **/
enum Stance {
	Standing;
	Crouching;
	Prone;
}

/** An enum with arguments: its index, then the arguments of that constructor. **/
enum Order {
	Idle;
	Walk(x:Float32, y:Float32);
	Say(text:String, ?to:Int);
	Hit(target:StructPoint, damage:UInt16);
	Group(orders:Array<Stance>);
}

/** More than 256 constructors: two bytes for the index. **/
enum Many {
	M0; M1; M2; M3; M4; M5; M6; M7; M8; M9; M10; M11; M12; M13; M14; M15; M16; M17; M18; M19; M20; M21; M22; M23; M24; M25; M26; M27; M28; M29;
	M30; M31; M32; M33; M34; M35; M36; M37; M38; M39; M40; M41; M42; M43; M44; M45; M46; M47; M48; M49; M50; M51; M52; M53; M54; M55; M56; M57;
	M58; M59; M60; M61; M62; M63; M64; M65; M66; M67; M68; M69; M70; M71; M72; M73; M74; M75; M76; M77; M78; M79; M80; M81; M82; M83; M84; M85;
	M86; M87; M88; M89; M90; M91; M92; M93; M94; M95; M96; M97; M98; M99; M100; M101; M102; M103; M104; M105; M106; M107; M108; M109; M110;
	M111; M112; M113; M114; M115; M116; M117; M118; M119; M120; M121; M122; M123; M124; M125; M126; M127; M128; M129; M130; M131; M132; M133;
	M134; M135; M136; M137; M138; M139; M140; M141; M142; M143; M144; M145; M146; M147; M148; M149; M150; M151; M152; M153; M154; M155; M156;
	M157; M158; M159; M160; M161; M162; M163; M164; M165; M166; M167; M168; M169; M170; M171; M172; M173; M174; M175; M176; M177; M178; M179;
	M180; M181; M182; M183; M184; M185; M186; M187; M188; M189; M190; M191; M192; M193; M194; M195; M196; M197; M198; M199; M200; M201; M202;
	M203; M204; M205; M206; M207; M208; M209; M210; M211; M212; M213; M214; M215; M216; M217; M218; M219; M220; M221; M222; M223; M224; M225;
	M226; M227; M228; M229; M230; M231; M232; M233; M234; M235; M236; M237; M238; M239; M240; M241; M242; M243; M244; M245; M246; M247; M248;
	M249; M250; M251; M252; M253; M254; M255; M256; M257;
}

/**
	Enums on the compiled lane: a simple enum as its index, an enum with
	arguments as its index and that constructor's arguments, and each one's
	constructors in its op.
**/
class RPCEnumTest extends utest.Test {
	public function testASimpleEnumArrivesAsSent():Void {
		var fixture = new EnumFixture();
		Assert.equals(Prone, fixture.commands.stance(Prone).result);
		Assert.equals(Standing, fixture.commands.stance(Standing).result);
		Assert.same([Crouching, Prone, Standing], fixture.commands.stances([Crouching, Prone, Standing]).result);
	}

	public function testASimpleEnumIsOneByteOnTheWire():Void {
		var link = LinkedConnection.pair();
		var commands = new EnumCommands();
		var client = new RPCSession<EnumCommands>(link.client, commands);
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
		commands.tell(Crouching);
		// Flags, op, one byte.
		Assert.same([5 + 1], lengths);
		Assert.notNull(client);
	}

	public function testAnEnumWithArgumentsArrivesAsSent():Void {
		var fixture = new EnumFixture();
		var at = new StructPoint();
		at.x = 3;
		at.y = 4;
		var orders:Array<Order> = [Idle, Walk(1.5, -2), Say("hi"), Say("you", 7), Hit(at, 65535), Group([Prone, Standing])];
		var back = fixture.commands.orders(orders).result;
		Assert.equals(6, back.length);
		Assert.isTrue(back[0].match(Idle));
		switch (back[1]) {
			case Walk(x, y):
				Assert.equals(1.5, (x : Float));
				Assert.equals(-2.0, (y : Float));
			case _:
				Assert.fail("not a Walk: " + back[1]);
		}
		Assert.isTrue(back[2].match(Say("hi", null)));
		Assert.isTrue(back[3].match(Say("you", 7)));
		switch (back[4]) {
			case Hit(target, damage):
				Assert.equals(4.0, (target.y : Float));
				Assert.equals(65535, (damage : Int));
			case _:
				Assert.fail("not a Hit");
		}
		switch (back[5]) {
			case Group(list):
				Assert.same([Prone, Standing], list);
			case _:
				Assert.fail("not a Group");
		}
	}

	public function testAnEnumOfMoreThan256ConstructorsTakesTwoBytes():Void {
		var fixture = new EnumFixture();
		Assert.equals(M257, fixture.commands.many(M257).result);
		Assert.equals(M0, fixture.commands.many(M0).result);
		Assert.same([M256, M3], fixture.commands.manies([M256, M3]).result);
	}

	public function testAnEnumsConstructorsAreInTheOp():Void {
		var fixture = new EnumFixture();
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("tell(<Standing,Crouching,Prone>)"));
			out.writeByte(2);
		}));
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("command(<Idle,Walk(f32,f32),Say(utf8,?i32),Hit({x:f32,y:f32},u16),Group([<Standing,Crouching,Prone>])>)"));
			out.writeByte(1);
			out.writeInt(FPHelper.floatToI32(0.5));
			out.writeInt(FPHelper.floatToI32(1));
		}));
		Assert.same(["tell Prone", "command Walk(0.5,1)"], fixture.handler.calls);
	}

	public function testAnEnumOfOtherConstructorsIsAnotherMethod():Void {
		// Another list of constructors, one more, at the end, is another
		// op, answered as a method not there, rather than an index read
		// against the other list.
		var link = LinkedConnection.pair();
		var commands = new OtherEnumCommands();
		var handler = new EnumHandler();
		var client = new RPCSession<OtherEnumCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);
		var answer = commands.stance(Kneeling);
		Assert.isFalse(answer.succeeded);
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, answer.error);
		Assert.notNull(client);
		Assert.notNull(server);
	}

	public function testAnIndexPastTheConstructorsIsUnreadable():Void {
		var fixture = new EnumFixture();
		var answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("stance(<Standing,Crouching,Prone>):<Standing,Crouching,Prone>"));
			out.writeVarUInt(4);
			out.writeByte(3);
		}));
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("stances([<Standing,Crouching,Prone>]):[<Standing,Crouching,Prone>]"));
			out.writeVarUInt(5);
			out.writeVarUInt(2);
			out.writeByte(0);
			out.writeByte(200);
		}));
		Assert.same(["4: " + RPCError.UNREADABLE_MESSAGE, "5: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	public function testANullEnumIsRefusedAndAbsenceCarried():Void {
		var fixture = new EnumFixture();
		var sent:Int = fixture.link.client.sent;
		Assert.raises(() -> fixture.commands.stance(null), ArgumentError);
		Assert.raises(() -> fixture.commands.stances([Prone, null]), ArgumentError);
		Assert.raises(() -> fixture.commands.orders([Idle, null]), ArgumentError);
		Assert.equals(sent, fixture.link.client.sent);
		Assert.isFalse(@:privateAccess fixture.client.__frame.busy);
		Assert.equals("none", fixture.commands.maybe(null).result);
		Assert.equals("Say", fixture.commands.maybe(Say("x")).result);
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

interface EnumContract {
	function stance(value:Stance):Stance;
	function stances(values:Array<Stance>):Array<Stance>;
	function tell(value:Stance):Void;
	function command(order:Order):Void;
	function orders(values:Array<Order>):Array<Order>;
	function many(value:Many):Many;
	function manies(values:Array<Many>):Array<Many>;
	function maybe(order:Null<Order>):String;
}

@:rpcContract(EnumContract)
private class EnumCommands extends RPCCommands {
	public function new() {}
}

private class EnumHandler extends RPCHandler implements EnumContract {
	public final calls:Array<String> = [];

	public function new() {}

	public function stance(value:Stance):Stance {
		return value;
	}

	public function stances(values:Array<Stance>):Array<Stance> {
		return values;
	}

	public function tell(value:Stance):Void {
		calls.push("tell " + value);
	}

	public function command(order:Order):Void {
		calls.push("command " + switch (order) {
			case Walk(x, y): "Walk(" + (x : Float) + "," + (y : Float) + ")";
			case _: Std.string(order);
		});
	}

	public function orders(values:Array<Order>):Array<Order> {
		return values;
	}

	public function many(value:Many):Many {
		return value;
	}

	public function manies(values:Array<Many>):Array<Many> {
		return values;
	}

	public function maybe(order:Null<Order>):String {
		return order == null ? "none" : Type.enumConstructor(order);
	}
}

private class EnumFixture {
	public final link = LinkedConnection.pair();
	public final commands = new EnumCommands();
	public final handler = new EnumHandler();
	public final client:RPCSession<EnumCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<EnumCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

/** A later Stance, its constructors renamed and one added. **/
enum StanceV2 {
	Standing2;
	Crouching2;
	Prone2;
	Kneeling;
}

private class OtherEnumCommands extends RPCCommands {
	public function new() {}

	@:rpc public function stance(value:StanceV2):RPCResponse<StanceV2> {}
}
