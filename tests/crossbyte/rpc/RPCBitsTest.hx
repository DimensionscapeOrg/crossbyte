package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.BitReader;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.utils.Hash;
import haxe.ds.IntMap;
import haxe.io.Bytes;
import utest.Assert;

/**
	The bit layout: `@:quantize(min, max, bits)` and `@:range(min, max)`
	fields in a bit section of their own, LSB first as `BitWriter` writes,
	before the structure's other fields; in a whole value and in a patch.
**/
class RPCBitsTest extends utest.Test {
	public function testAQuantizedShipIsItsBitsThenItsBytes():Void {
		final ship = remote(1524, -311.5, 120, -45, 16384, 5, false, 180);
		// controls 6 bits, engineHeat 10, vx, vy, x and y 16 each: 80 bits,
		// ten bytes; then aimSteps 2 and engineLocked 1.
		final whole = new ByteArray();
		RPCCodecs.of(BitShip).write(ship, whole);
		Assert.equals(13, whole.length);
		Assert.equals(13, RPCCodecs.of(BitShip).maxSize);
		// The bit section reads back with a BitReader.
		final reader = new BitReader(whole, 0, 10);
		Assert.equals(5, reader.readRange(0, 63));
		Assert.floatEquals(180, reader.readQuantized(0, 400, 10), 400 / 1023 / 2);
		Assert.floatEquals(120, reader.readQuantized(-1024, 1024, 16), 2048 / 65535 / 2);
		Assert.floatEquals(-45, reader.readQuantized(-1024, 1024, 16), 2048 / 65535 / 2);
		Assert.floatEquals(1524, reader.readQuantized(-8192, 8192, 16), 16384 / 65535 / 2);
		Assert.floatEquals(-311.5, reader.readQuantized(-8192, 8192, 16), 16384 / 65535 / 2);
		whole.position = 0;
		final back = RPCCodecs.of(BitShip).read(whole);
		Assert.isTrue(RPCCodecs.of(BitShip).equals(ship, back), "a quantized ship did not read back within its steps");
		Assert.equals(16384, (back.aimSteps : Int));
		Assert.equals(5, back.controls);
	}

	public function testTheDesignsRemoteShipIsSevenBytes():Void {
		final base = remote(1520, -310, 120, -45, 16000, 5, false, 180);
		final current = remote(1524, -311.5, 120, -45, 16384, 5, false, 180);
		final b = new IntMap<BitShip>();
		b.set(3, base);
		final c = new IntMap<BitShip>();
		c.set(3, current);
		final hex:String = argumentsOf(commands -> commands.ships(new RPCMapPatch(RPCCodecs.of(BitShip)).diff(b, c)));
		// The counts, the key, then the mask (aimSteps, x, y), x's step 38863
		// and y's 31522, sixteen bits each; then aimSteps, a byte field.
		Assert.equals("000001" + "06" + "c1" + "cf97" + "227b" + "0040", hex);
	}

	public function testAQuantizedPatchArrivesWithinHalfAStep():Void {
		final fixture = new BitFixture();
		final base = remote(0, 0, 0, 0, 0, 0, false, 0);
		final current = remote(1000.3, -77.7, 3.3, -4.4, 9, 63, true, 399);
		fixture.commands.ship(new RPCPatch(RPCCodecs.of(BitShip)).diff(base, current));
		final into = fixture.handler.lastShip.apply(base, new BitShip());
		Assert.floatEquals(1000.3, (into.x : Float), 16384 / 65535 / 2);
		Assert.floatEquals(-77.7, (into.y : Float), 16384 / 65535 / 2);
		Assert.floatEquals(3.3, (into.vx : Float), 2048 / 65535 / 2);
		Assert.floatEquals(399, (into.engineHeat : Float), 400 / 1023 / 2);
		Assert.equals(63, into.controls);
		Assert.isTrue(into.engineLocked);
	}

	public function testJitterBelowAStepSendsNothing():Void {
		final codec = RPCCodecs.of(BitShip);
		// 99.9 and 99.95 are both nearest step 33167 of 65535 (99.876).
		final a = remote(99.9, 99.9, 0, 0, 0, 0, false, 0);
		final b = remote(99.95, 99.95, 0, 0, 0, 0, false, 0);
		Assert.isTrue(codec.equals(a, b), "a change of less than a step was a change");
		Assert.equals(0, new RPCPatch(codec).diff(a, b).changedCount);
		b.x = 100.5;
		Assert.equals(1, new RPCPatch(codec).diff(a, b).changedCount);
		// Outside the range, clamped: the ends.
		b.x = 1e9;
		final out = new ByteArray();
		codec.write(b, out);
		out.position = 0;
		Assert.equals(8192.0, (codec.read(out).x : Float));
	}

	public function testValuesThatCannotBeSentAreRefusedBeforeAnythingIs():Void {
		final fixture = new BitFixture();
		final sent:Int = fixture.link.client.sent;
		final codec = RPCCodecs.of(BitShip);
		final nan = remote(Math.NaN, 0, 0, 0, 0, 0, false, 0);
		Assert.raises(() -> fixture.commands.ship(new RPCPatch(codec).diff(null, nan)), ArgumentError);
		final wide = remote(0, 0, 0, 0, 0, 64, false, 0);
		Assert.raises(() -> fixture.commands.ship(new RPCPatch(codec).diff(null, wide)), ArgumentError);
		Assert.raises(() -> codec.write(wide, new ByteArray()), ArgumentError);
		Assert.equals(sent, fixture.link.client.sent);
		// The session goes on.
		fixture.commands.ship(new RPCPatch(codec).diff(null, remote(1, 1, 1, 1, 1, 1, false, 1)));
		Assert.notNull(fixture.handler.lastShip);
	}

	public function testARangedValuePastItsRangeIsUnreadable():Void {
		final fixture = new BitFixture();
		final answers = errorAnswersAt(fixture.link.client);
		// A BitDie is one ranged field from 1 to 6, three bits: 7 is past it.
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("roll(" + DIE_TOKEN + "):i32"));
			out.writeVarUInt(4);
			out.writeByte(0x06); // offset 6, the value 7
		}));
		Assert.same(["4: " + RPCError.UNREADABLE_MESSAGE], answers);
		final die = new BitDie();
		die.face = 6;
		Assert.equals(6, new BitFixture().commands.roll(die).result);
	}

	public function testTheBoundsAndWidthsAreInTheOp():Void {
		Assert.equals(SHIP_TOKEN, tokenOf(commands -> commands.ship(new RPCPatch(RPCCodecs.of(BitShip)).diff(null, new BitShip()))));
		Assert.equals(RPCOps.opOf("roll(" + DIE_TOKEN + "):i32"), opOfCall(commands -> commands.roll(new BitDie())));
		Assert.equals(Hash.fnv1a32(Bytes.ofString(SHIP_TOKEN.substr(1))), RPCCodecs.of(BitShip).layout);
	}

	public function testBoundsMayBeConstants():Void {
		final codec = RPCCodecs.of(BitRuled);
		final ruled = new BitRuled();
		ruled.heat = BitRules.MAX_HEAT;
		ruled.speed = -BitRules.MAX_SPEED;
		final out = new ByteArray();
		codec.write(ruled, out);
		out.position = 0;
		final back = codec.read(out);
		Assert.equals(BitRules.MAX_HEAT, (back.heat : Float));
		Assert.equals(-BitRules.MAX_SPEED, back.speed);
		// The same bounds, as literals, are the same layout.
		Assert.equals(RPCCodecs.of(BitRuledLiterally).layout, codec.layout);
	}

	public function testRandomQuantizedPatchesAreTheSameBytesEverywhere():Void {
		var seed:Int = 99;
		final next = (bound:Int) -> {
			seed = (Hash.mul32(seed, 1103515245) + 12345) & 0x7FFFFFFF;
			return (seed >>> 8) % bound;
		};
		final codec = RPCCodecs.of(BitShip);
		final out = new ByteArray();
		final patch = new RPCPatch(codec);
		final read = new RPCPatch(codec);
		var wrong:Int = 0;
		for (_ in 0...300) {
			final base = remote(next(160000) / 10 - 8000, next(160000) / 10 - 8000, next(2000) - 1000, next(2000) - 1000, next(65536), next(64),
				next(2) == 0, next(4000) / 10);
			final current = codec.copy(base, new BitShip());
			if (next(2) == 0) current.x = next(160000) / 10 - 8000;
			if (next(2) == 0) current.y = next(160000) / 10 - 8000;
			if (next(3) == 0) current.controls = next(64);
			if (next(3) == 0) current.engineHeat = next(4000) / 10;
			if (next(4) == 0) current.aimSteps = next(65536);
			final at:Int = out.length;
			out.position = at;
			patch.diff(next(9) == 0 ? null : base, current).write(out);
			out.position = at;
			if (!codec.equals(current, read.read(out).apply(base, new BitShip()))) {
				wrong++;
			}
		}
		Assert.equals(0, wrong);
		final bytes:Bytes = (out : Bytes).sub(0, out.length);
		Assert.equals(FUZZ_BYTES, bytes.length);
		Assert.equals(FUZZ_HASH, Hash.fnv1a32(bytes));
	}

	// What every target writes for the random patches above.
	static inline final FUZZ_BYTES:Int = 1830;
	static inline final FUZZ_HASH:Int = 154722419;

	// ------------------------------------------------------------------

	static inline final SHIP_TOKEN:String = "~b{aimSteps:u16,controls:r(0,63),engineHeat:q10(0000000000000000,4079000000000000),engineLocked:bool,"
		+ "vx:q16(c090000000000000,4090000000000000),vy:q16(c090000000000000,4090000000000000),x:q16(c0c0000000000000,40c0000000000000),"
		+ "y:q16(c0c0000000000000,40c0000000000000)}";
	static inline final DIE_TOKEN:String = "b{face:r(1,6)}";

	static function remote(x:Float, y:Float, vx:Float, vy:Float, aim:Int, controls:Int, locked:Bool, heat:Float):BitShip {
		final s = new BitShip();
		s.x = x;
		s.y = y;
		s.vx = vx;
		s.vy = vy;
		s.aimSteps = aim;
		s.controls = controls;
		s.engineLocked = locked;
		s.engineHeat = heat;
		return s;
	}

	static function frames(call:BitCommands->Void):Array<Bytes> {
		final link = LinkedConnection.pair();
		final commands = new BitCommands();
		final session = new RPCSession<BitCommands>(link.client, commands);
		Assert.notNull(session);
		final got:Array<Bytes> = [];
		link.server.readEnabled = true;
		link.server.onData = input -> {
			final bytes = Bytes.alloc(input.bytesAvailable);
			input.readBytes(bytes, 0, bytes.length);
			got.push(bytes);
		};
		call(commands);
		return got;
	}

	static function argumentsOf(call:BitCommands->Void):String {
		final got = frames(call);
		return got[got.length - 1].toHex().substr(18);
	}

	static function opOfCall(call:BitCommands->Void):Int {
		final got = frames(call);
		return got[got.length - 1].getInt32(5);
	}

	/** Which of the contract's ops a call went as, by its signature. **/
	static function tokenOf(call:BitCommands->Void):String {
		final op:Int = opOfCall(call);
		return op == RPCOps.opOf("ship(" + SHIP_TOKEN + ")") ? SHIP_TOKEN : "another op";
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

/** The design's remote ship, quantized. **/
class BitShip implements RPCStruct {
	public var aimSteps:UInt16 = 0;
	@:range(0, 63) public var controls:Int = 0;
	@:quantize(0, 400, 10) public var engineHeat:Float = 0;
	public var engineLocked:Bool = false;
	@:quantize(-1024, 1024, 16) public var vx:Float = 0;
	@:quantize(-1024, 1024, 16) public var vy:Float = 0;
	@:quantize(-8192, 8192, 16) public var x:Float32 = 0;
	@:quantize(-8192, 8192, 16) public var y:Float32 = 0;

	public function new() {}
}

class BitDie implements RPCStruct {
	@:range(1, 6) public var face:Int = 1;

	public function new() {}
}

class BitRules {
	public static inline final MAX_HEAT:Float = 400.0;
	public static inline final MAX_SPEED:Int = 1024;
}

class BitRuled implements RPCStruct {
	@:quantize(0, BitRules.MAX_HEAT, 10) public var heat:Float = 0;
	@:range(-crossbyte.rpc.BitRules.MAX_SPEED, BitRules.MAX_SPEED * 2 - 1024) public var speed:Int = 0;

	public function new() {}
}

class BitRuledLiterally implements RPCStruct {
	@:quantize(0, 400.0, 10) public var heat:Float = 0;
	@:range(-1024, 1024) public var speed:Int = 0;

	public function new() {}
}

interface BitContract {
	function ship(ship:RPCPatch<BitShip>):Void;
	function ships(ships:RPCMapPatch<BitShip>):Void;
	function roll(die:BitDie):Int;
}

@:rpcContract(BitContract)
private class BitCommands extends RPCCommands {
	public function new() {}
}

private class BitHandler extends RPCHandler implements BitContract {
	public var lastShip:Null<RPCPatch<BitShip>> = null;

	public function new() {}

	public function ship(ship:RPCPatch<BitShip>):Void {
		lastShip = ship;
	}

	public function ships(ships:RPCMapPatch<BitShip>):Void {}

	public function roll(die:BitDie):Int {
		return die.face;
	}
}

private class BitFixture {
	public final link = LinkedConnection.pair();
	public final commands = new BitCommands();
	public final handler = new BitHandler();
	public final client:RPCSession<BitCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<BitCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}
