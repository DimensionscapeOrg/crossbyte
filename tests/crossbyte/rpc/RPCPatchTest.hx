package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.utils.Hash;
import haxe.io.Bytes;
import utest.Assert;

/**
	`RPCPatch<T>`: a structure sent as the fields that differ from a base
	both ends hold, a bit for each field and then each that differs whole,
	a nested structure as a patch of its own. Applied to the base the
	sender used, it gives the sender's value exactly.
**/
class RPCPatchTest extends utest.Test {
	public function testAPatchAppliedToItsBaseIsTheValueSent():Void {
		final fixture = new PatchFixture();
		final base = ship(1520, -310, 120, -45, 16000, 5, false, 180);
		final current = ship(1524, -311.5, 120, -45, 16384, 5, false, 180);
		final patch = new RPCPatch(RPCCodecs.of(PatchShip));
		fixture.commands.ship(1, patch.diff(base, current));
		Assert.equals(3, patch.changedCount);
		Assert.isFalse(patch.isFull);
		final received = fixture.handler.lastShip;
		Assert.notNull(received);
		Assert.equals(3, received.changedCount);
		final into = new PatchShip();
		received.apply(base, into);
		Assert.isTrue(RPCCodecs.of(PatchShip).equals(current, into), "the patch applied to its base was not the value sent: " + describe(into));
		Assert.equals(1524.0, (into.x : Float));
		Assert.equals(-311.5, (into.y : Float));
		Assert.equals(16384, (into.aimSteps : Int));
		Assert.equals(180.0, (into.engineHeat : Float));
	}

	public function testOnlyTheFieldsThatDifferGo():Void {
		// The design's remote ship: aimSteps, x and y of eight changed. A full
		// bit and eight mask bits (two bytes), aimSteps 2, x 4, y 4: 12 bytes.
		final base = ship(1520, -310, 120, -45, 16000, 5, false, 180);
		final current = ship(1524, -311.5, 120, -45, 16384, 5, false, 180);
		final patch = new RPCPatch(RPCCodecs.of(PatchShip));
		final hex:String = argumentsOf(commands -> commands.ship(7, patch.diff(base, current)));
		// tick 7, then the bit section: full 0, mask 0xC1 (bits 0, 6, 7) shifted by one.
		Assert.equals("07" + "8201" + "0040" + "0080be44" + "00c09bc3", hex);
		// Nothing changed: the mask alone.
		Assert.equals("07" + "0000", argumentsOf(commands -> commands.ship(7, patch.diff(base, base))));
		Assert.isTrue(patch.isEmpty);
		Assert.equals("07" + "0000", argumentsOf(commands -> commands.ship(7, patch.diff(base, ship(1520, -310, 120, -45, 16000, 5, false, 180)))));
	}

	public function testAFullPatchSendsWhatDiffersFromTheDefaultAndAppliesToAnything():Void {
		final fixture = new PatchFixture();
		final current = ship(0, 5, 0, 0, 0, 0, true, 0);
		final patch = new RPCPatch(RPCCodecs.of(PatchShip));
		patch.diff(null, current);
		Assert.isTrue(patch.isFull);
		Assert.equals(2, patch.changedCount);
		// Full bit set; mask: engineLocked (3) and y (7).
		Assert.equals("01" + "1101" + "01" + "0000a040", argumentsOf(commands -> commands.ship(1, patch.diff(null, current))));
		fixture.commands.ship(1, patch.diff(null, current));
		final received = fixture.handler.lastShip;
		Assert.isTrue(received.isFull);
		// Whatever base the receiver holds, or none.
		final into = ship(9, 9, 9, 9, 9, 9, false, 9);
		received.apply(ship(1, 2, 3, 4, 5, 6, false, 7), into);
		Assert.isTrue(RPCCodecs.of(PatchShip).equals(current, into));
		final fresh = received.apply(null, new PatchShip());
		Assert.isTrue(RPCCodecs.of(PatchShip).equals(current, fresh));
	}

	public function testAPatchCanBeAppliedInPlace():Void {
		final fixture = new PatchFixture();
		final held = ship(1, 2, 3, 4, 5, 6, false, 7);
		final current = ship(1, 20, 3, 4, 5, 6, true, 7);
		final patch = new RPCPatch(RPCCodecs.of(PatchShip));
		fixture.commands.ship(2, patch.diff(ship(1, 2, 3, 4, 5, 6, false, 7), current));
		Assert.isTrue(fixture.handler.lastShip.apply(held, held) == held);
		Assert.isTrue(RPCCodecs.of(PatchShip).equals(current, held));
	}

	public function testANestedStructureIsPatchedFieldByField():Void {
		final fixture = new PatchFixture();
		final base = new PatchPlayer();
		base.id = 4;
		base.name = "ann";
		base.position.x = 1;
		base.position.y = 2;
		base.position.z = 3;
		base.cells = [1, 2, 3];
		final current = RPCCodecs.of(PatchPlayer).copy(base, new PatchPlayer());
		Assert.isFalse(current.position == base.position, "a copy shared its nested structure");
		Assert.isFalse(current.cells == base.cells, "a copy shared its array");
		current.position.y = 20;
		final patch = new RPCPatch(RPCCodecs.of(PatchPlayer));
		patch.diff(base, current);
		Assert.equals(1, patch.changedCount);
		// Mask: position, field 5 of cells, id, labels, maybe, name,
		// position, spare and tag, after the full bit; then position's own
		// patch: its mask, y alone, and y.
		Assert.equals("4000" + "02" + "0000000000003440", argumentsOf(commands -> commands.player(patch)));
		fixture.commands.player(patch);
		final into = new PatchPlayer();
		fixture.handler.lastPlayer.apply(base, into);
		Assert.isTrue(RPCCodecs.of(PatchPlayer).equals(current, into));
		Assert.equals(20.0, into.position.y);
		Assert.equals(1.0, into.position.x);
		Assert.same([1, 2, 3], into.cells);
		Assert.isFalse(into.cells == base.cells, "an unchanged array was shared with the base");
		// The rest of a structure's kinds, each sent whole when it differs.
		current.cells.push(4);
		current.name = "bob";
		current.tag = Tagged(7, "x");
		current.labels.set("k", 5);
		current.spare = Bytes.ofString("hi");
		current.maybe = 3;
		fixture.commands.player(patch.diff(base, current));
		Assert.equals(7, patch.changedCount);
		final again = new PatchPlayer();
		fixture.handler.lastPlayer.apply(base, again);
		Assert.isTrue(RPCCodecs.of(PatchPlayer).equals(current, again), "the patch of every kind did not apply");
		Assert.same([1, 2, 3, 4], again.cells);
		Assert.equals("bob", again.name);
		Assert.equals(5, again.labels.get("k"));
		Assert.equals("hi", again.spare.toString());
		Assert.equals(3, again.maybe);
	}

	public function testFloatsAreComparedAsTheyAreSent():Void {
		final codec = RPCCodecs.of(PatchFloats);
		final a = new PatchFloats();
		final b = new PatchFloats();
		a.wide = Math.NaN;
		b.wide = Math.NaN;
		Assert.isTrue(codec.equals(a, b), "NaN differed from NaN");
		// Two doubles one single: the same bytes as Float32s.
		a.narrow = 0.1;
		b.narrow = 0.1 + 1e-12;
		Assert.isTrue(codec.equals(a, b), "two values the same at single precision differed");
		b.narrow = 0.2;
		Assert.isFalse(codec.equals(a, b));
		final patch = new RPCPatch(codec).diff(a, b);
		Assert.equals(1, patch.changedCount);
	}

	public function testWideStructuresUseBothMasks():Void {
		final fixture = new PatchFixture();
		final codec = RPCCodecs.of(PatchWide);
		Assert.equals(40, codec.fieldCount);
		final base = new PatchWide();
		final current = codec.copy(base, new PatchWide());
		current.f00 = 1;
		current.f31 = 2;
		current.f32 = 3;
		current.f39 = 4;
		final patch = new RPCPatch(codec).diff(base, current);
		Assert.equals(4, patch.changedCount);
		fixture.commands.wide(patch);
		final into = fixture.handler.lastWide.apply(base, new PatchWide());
		Assert.isTrue(codec.equals(current, into));
		Assert.equals(4, into.f39);
		Assert.equals(0, into.f20);
	}

	public function testTheSessionReadsEveryCallsPatchIntoOne():Void {
		final fixture = new PatchFixture();
		final patch = new RPCPatch(RPCCodecs.of(PatchShip));
		final base = new PatchShip();
		fixture.commands.ship(1, patch.diff(base, ship(1, 0, 0, 0, 0, 0, false, 0)));
		final first = fixture.handler.lastShip;
		fixture.commands.ship(2, patch.diff(base, ship(2, 0, 0, 0, 0, 0, false, 0)));
		Assert.isTrue(first == fixture.handler.lastShip, "a patch was made for each call");
		// Another session has one of its own.
		final other = new PatchFixture(fixture.handler);
		other.commands.ship(3, patch.diff(base, ship(3, 0, 0, 0, 0, 0, false, 0)));
		Assert.isFalse(first == fixture.handler.lastShip, "two sessions shared a patch");
	}

	public function testAPatchIsBytesOfItsOwnToo():Void {
		final codec = RPCCodecs.of(PatchShip);
		final base = ship(1520, -310, 120, -45, 16000, 5, false, 180);
		final current = ship(1524, -311.5, 120, -45, 16384, 5, false, 180);
		final out = new ByteArray();
		out.writeByte(0xEE);
		new RPCPatch(codec).diff(base, current).write(out);
		Assert.equals(13, out.length);
		out.position = 1;
		final read = new RPCPatch(codec).read(out);
		Assert.equals(13, out.position);
		Assert.isTrue(codec.equals(current, read.apply(base, new PatchShip())));
		// The codec's per-value forms.
		final again = new ByteArray();
		codec.writePatch(base, current, again);
		again.position = 0;
		Assert.isTrue(codec.equals(current, codec.readPatch(again, base, new PatchShip())));
		final whole = new ByteArray();
		codec.write(current, whole);
		Assert.equals(24, whole.length);
		whole.position = 0;
		Assert.isTrue(codec.equals(current, codec.read(whole)));
		whole.position = 0;
		final held = new PatchShip();
		Assert.isTrue(codec.read(whole, held) == held);
		Assert.isTrue(codec.equals(current, held));
		Assert.equals("crossbyte.rpc.PatchShip", codec.name);
		Assert.equals(24, codec.maxSize);
		Assert.equals(8, codec.fieldCount);
		Assert.equals(crossbyte.utils.Hash.fnv1a32(Bytes.ofString(SHIP_TOKEN)), codec.layout);
		Assert.isTrue(codec == RPCCodecs.of(PatchShip));
	}

	public function testAPatchsKindIsInTheOp():Void {
		final fixture = new PatchFixture();
		var unknown:Bool = false;
		fixture.server.onUnreadableFrame = (op, id, reason) -> unknown = true;
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("ship(vu,~" + SHIP_TOKEN + ")"));
			out.writeVarUInt(5);
			out.writeByte(0x02); // mask: aimSteps
			out.writeByte(0x00);
			out.writeShort(77);
		}));
		Assert.isFalse(unknown);
		Assert.equals(1, fixture.handler.lastShip.changedCount);
		Assert.equals(77, (fixture.handler.lastShip.apply(new PatchShip(), new PatchShip()).aimSteps : Int));
	}

	public function testAPatchCutShortIsUnreadable():Void {
		final fixture = new PatchFixture();
		final answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("echo(~" + SHIP_TOKEN + "):~" + SHIP_TOKEN));
			out.writeVarUInt(3);
			out.writeByte(0x82); // aimSteps, x and y
			out.writeByte(0x01);
			out.writeShort(77);
		}));
		Assert.same(["3: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	public function testAPatchAnswerArrives():Void {
		final fixture = new PatchFixture();
		final base = ship(1, 2, 3, 4, 5, 6, false, 7);
		final current = ship(1, 2, 30, 4, 5, 6, false, 7);
		final answer = fixture.commands.echo(new RPCPatch(RPCCodecs.of(PatchShip)).diff(base, current)).result;
		Assert.notNull(answer);
		Assert.isTrue(RPCCodecs.of(PatchShip).equals(current, answer.apply(base, new PatchShip())));
	}

	public function testAPatchNotDiffedOrNullIsRefusedBeforeAnythingIsSent():Void {
		final fixture = new PatchFixture();
		final sent:Int = fixture.link.client.sent;
		Assert.raises(() -> fixture.commands.ship(1, null), crossbyte.errors.ArgumentError);
		Assert.raises(() -> fixture.commands.ship(1, new RPCPatch(RPCCodecs.of(PatchShip))), crossbyte.errors.ArgumentError);
		final nested = new PatchPlayer();
		nested.position = null;
		Assert.raises(() -> fixture.commands.player(new RPCPatch(RPCCodecs.of(PatchPlayer)).diff(null, nested)), crossbyte.errors.ArgumentError);
		Assert.equals(sent, fixture.link.client.sent);
		Assert.raises(() -> new RPCPatch(RPCCodecs.of(PatchShip)).diff(null, null), crossbyte.errors.ArgumentError);
	}

	public function testApplyingWithoutTheBaseItNamesIsRefused():Void {
		final fixture = new PatchFixture();
		fixture.commands.ship(1, new RPCPatch(RPCCodecs.of(PatchShip)).diff(new PatchShip(), ship(1, 0, 0, 0, 0, 0, false, 0)));
		Assert.raises(() -> fixture.handler.lastShip.apply(null, new PatchShip()), crossbyte.errors.ArgumentError);
	}

	/**
		Random bases and values, some fields the same and some not: each patch
		applied to its base is the value, and the bytes are the same on every
		target (their hash is the one every target computes).
	**/
	public function testRandomPatchesApplyToTheirBasesAndAreTheSameBytesEverywhere():Void {
		var seed:Int = 20261014;
		final next = (bound:Int) -> {
			seed = (Hash.mul32(seed, 1103515245) + 12345) & 0x7FFFFFFF;
			return (seed >>> 8) % bound;
		};
		final ships = RPCCodecs.of(PatchShip);
		final players = RPCCodecs.of(PatchPlayer);
		final out = new ByteArray();
		final shipPatch = new RPCPatch(ships);
		final shipRead = new RPCPatch(ships);
		final playerPatch = new RPCPatch(players);
		final playerRead = new RPCPatch(players);
		var mismatches:Int = 0;
		for (round in 0...400) {
			final base = randomShip(next);
			final current = ships.copy(base, new PatchShip());
			if (next(2) == 0) current.x = next(4096) / 16 - 128;
			if (next(2) == 0) current.y = next(4096) / 16 - 128;
			if (next(3) == 0) current.vx = next(256) / 4;
			if (next(3) == 0) current.vy = -next(256) / 4;
			if (next(2) == 0) current.aimSteps = next(65536);
			if (next(4) == 0) current.controls = next(64);
			if (next(4) == 0) current.engineLocked = !current.engineLocked;
			if (next(3) == 0) current.engineHeat = next(400);
			final against:Null<PatchShip> = next(10) == 0 ? null : base;
			final playerBase = randomPlayer(next);
			final player = players.copy(playerBase, new PatchPlayer());
			if (next(2) == 0) player.position.x = next(1000) / 8;
			if (next(3) == 0) player.cells.push(next(100));
			if (next(3) == 0) player.name = "p" + next(50);
			if (next(4) == 0) player.tag = Tagged(next(9), "t" + next(9));
			if (next(4) == 0) player.maybe = next(2) == 0 ? null : next(10);
			// Each written after the last, then read back from where it began.
			final shipAt:Int = out.length;
			out.position = shipAt;
			shipPatch.diff(against, current).write(out);
			final playerAt:Int = out.length;
			playerPatch.diff(playerBase, player).write(out);
			out.position = shipAt;
			if (!ships.equals(current, shipRead.read(out).apply(against, new PatchShip()))) {
				mismatches++;
			}
			if (out.position != playerAt) {
				mismatches++;
			}
			if (!players.equals(player, playerRead.read(out).apply(playerBase, new PatchPlayer()))) {
				mismatches++;
			}
		}
		Assert.equals(0, mismatches, "patches did not apply to their bases");
		final bytes:Bytes = (out : Bytes).sub(0, out.length);
		Assert.equals(FUZZ_BYTES, bytes.length);
		Assert.equals(FUZZ_HASH, Hash.fnv1a32(bytes));
	}

	static function randomShip(next:Int->Int):PatchShip {
		return ship(next(4096) / 16 - 128, next(4096) / 16 - 128, next(256) / 4, -next(256) / 4, next(65536), next(64), next(2) == 0, next(400));
	}

	static function randomPlayer(next:Int->Int):PatchPlayer {
		final p = new PatchPlayer();
		p.id = next(1000);
		p.name = "n" + next(20);
		p.position.x = next(100);
		p.position.y = next(100) / 2;
		p.position.z = -next(100);
		p.cells = [for (_ in 0...next(4)) next(50)];
		p.tag = next(2) == 0 ? Plain : Tagged(next(5), "x");
		p.maybe = next(2) == 0 ? null : next(7);
		return p;
	}

	// What every target writes for the random patches above.
	static inline final FUZZ_BYTES:Int = 10506;
	static inline final FUZZ_HASH:Int = 525407908;

	// ------------------------------------------------------------------

	static inline final SHIP_TOKEN:String = "{aimSteps:u16,controls:u8,engineHeat:f32,engineLocked:bool,vx:f32,vy:f32,x:f32,y:f32}";

	static function ship(x:Float, y:Float, vx:Float, vy:Float, aim:Int, controls:Int, locked:Bool, heat:Float):PatchShip {
		final s = new PatchShip();
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

	static function describe(s:PatchShip):String {
		return (s.aimSteps : Int) + "," + (s.controls : Int) + "," + (s.engineHeat : Float) + "," + s.engineLocked + "," + (s.vx : Float) + ","
			+ (s.vy : Float) + "," + (s.x : Float) + "," + (s.y : Float);
	}

	/** The hex of a one-way call's arguments, from a session that sends nowhere. **/
	static function argumentsOf(call:PatchCommands->Void):String {
		final link = LinkedConnection.pair();
		final commands = new PatchCommands();
		final session = new RPCSession<PatchCommands>(link.client, commands);
		Assert.notNull(session);
		var last:String = "";
		link.server.readEnabled = true;
		link.server.onData = input -> {
			final bytes = Bytes.alloc(input.bytesAvailable);
			input.readBytes(bytes, 0, bytes.length);
			last = bytes.toHex();
		};
		call(commands);
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

/** Stellar's remote ship, with today's field types. **/
class PatchShip implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;
	public var vx:Float32 = 0;
	public var vy:Float32 = 0;
	public var aimSteps:UInt16 = 0;
	public var controls:UInt8 = 0;
	public var engineLocked:Bool = false;
	public var engineHeat:Float32 = 0;

	public function new() {}
}

class PatchVec implements RPCStruct {
	public var x:Float = 0;
	public var y:Float = 0;
	public var z:Float = 0;

	public function new() {}
}

enum PatchTag {
	Plain;
	Tagged(level:Int, label:String);
}

class PatchPlayer implements RPCStruct {
	public var id:Int = 0;
	public var name:String = "";
	public var position:PatchVec = new PatchVec();
	public var cells:Array<Int> = [];
	public var tag:PatchTag = Plain;
	public var labels:Map<String, Int> = new Map();
	public var spare:Null<Bytes> = null;
	public var maybe:Null<Int> = null;

	public function new() {}
}

class PatchFloats implements RPCStruct {
	public var wide:Float = 0;
	public var narrow:Float32 = 0;

	public function new() {}
}

class PatchWide implements RPCStruct {
	public var f00:Int = 0;
	public var f01:Int = 0;
	public var f02:Int = 0;
	public var f03:Int = 0;
	public var f04:Int = 0;
	public var f05:Int = 0;
	public var f06:Int = 0;
	public var f07:Int = 0;
	public var f08:Int = 0;
	public var f09:Int = 0;
	public var f10:Int = 0;
	public var f11:Int = 0;
	public var f12:Int = 0;
	public var f13:Int = 0;
	public var f14:Int = 0;
	public var f15:Int = 0;
	public var f16:Int = 0;
	public var f17:Int = 0;
	public var f18:Int = 0;
	public var f19:Int = 0;
	public var f20:Int = 0;
	public var f21:Int = 0;
	public var f22:Int = 0;
	public var f23:Int = 0;
	public var f24:Int = 0;
	public var f25:Int = 0;
	public var f26:Int = 0;
	public var f27:Int = 0;
	public var f28:Int = 0;
	public var f29:Int = 0;
	public var f30:Int = 0;
	public var f31:Int = 0;
	public var f32:Int = 0;
	public var f33:Int = 0;
	public var f34:Int = 0;
	public var f35:Int = 0;
	public var f36:Int = 0;
	public var f37:Int = 0;
	public var f38:Int = 0;
	public var f39:Int = 0;

	public function new() {}
}

interface PatchContract {
	function ship(tick:VarUInt, state:RPCPatch<PatchShip>):Void;
	function player(state:RPCPatch<PatchPlayer>):Void;
	function wide(state:RPCPatch<PatchWide>):Void;
	function echo(state:RPCPatch<PatchShip>):RPCPatch<PatchShip>;
}

@:rpcContract(PatchContract)
private class PatchCommands extends RPCCommands {
	public function new() {}
}

private class PatchHandler extends RPCHandler implements PatchContract {
	public var lastShip:Null<RPCPatch<PatchShip>> = null;
	public var lastPlayer:Null<RPCPatch<PatchPlayer>> = null;
	public var lastWide:Null<RPCPatch<PatchWide>> = null;

	public function new() {}

	public function ship(tick:VarUInt, state:RPCPatch<PatchShip>):Void {
		lastShip = state;
	}

	public function player(state:RPCPatch<PatchPlayer>):Void {
		lastPlayer = state;
	}

	public function wide(state:RPCPatch<PatchWide>):Void {
		lastWide = state;
	}

	public function echo(state:RPCPatch<PatchShip>):RPCPatch<PatchShip> {
		// What arrived, made into a value and diffed again to send back.
		final base = new PatchShip();
		base.x = 1;
		base.y = 2;
		base.vx = 3;
		base.vy = 4;
		base.aimSteps = 5;
		base.controls = 6;
		base.engineHeat = 7;
		final value = state.apply(base, new PatchShip());
		return new RPCPatch(RPCCodecs.of(PatchShip)).diff(base, value);
	}
}

private class PatchFixture {
	public final link = LinkedConnection.pair();
	public final commands = new PatchCommands();
	public final handler:PatchHandler;
	public final client:RPCSession<PatchCommands>;
	public final server:RPCSession<Dynamic>;

	public function new(?handler:PatchHandler) {
		this.handler = handler != null ? handler : new PatchHandler();
		client = new RPCSession<PatchCommands>(link.client, commands);
		server = new RPCSession(link.server, null, this.handler);
	}
}
