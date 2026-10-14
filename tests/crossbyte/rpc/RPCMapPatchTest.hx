package crossbyte.rpc;

import crossbyte.ds.IdList;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.utils.Hash;
import haxe.ds.IntMap;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

/**
	`RPCMapPatch<V>` and `RPCStringMapPatch<V>`: a keyed map sent as the keys
	removed, the entries added, and patches of the entries both hold whose
	values differ, each group ascending with its keys coded small. Applied
	to the base the sender used, it makes the sender's map.
**/
class RPCMapPatchTest extends utest.Test {
	public function testAPatchAppliedToItsBaseIsTheMapSent():Void {
		final fixture = new MapPatchFixture();
		final base = world([1 => ship(10, 0), 2 => ship(20, 0), 3 => ship(30, 0), 9 => ship(90, 0)]);
		final current = world([1 => ship(10, 0), 2 => ship(21, 5), 4 => ship(40, 0), 9 => ship(90, 1)]);
		final patch = new RPCMapPatch(RPCCodecs.of(MapShip)).diff(base, current);
		Assert.equals(1, patch.removedCount);
		Assert.equals(1, patch.addedCount);
		Assert.equals(2, patch.updatedCount);
		Assert.equals(3, patch.removed.get(0));
		Assert.equals(4, patch.addedKey(0));
		Assert.equals(2, patch.updatedKey(0));
		Assert.equals(9, patch.updatedKey(1));
		// Into another map, as a ring of frames is, and into the base itself.
		final into = world([7 => ship(70, 7), 2 => ship(0, 0)]);
		final kept = into.get(2);
		final held = copyOf(base);
		fixture.handler.inCall.test(() -> fixture.commands.ships(1, patch), () -> {
			final received = fixture.handler.lastShips;
			Assert.equals(1, received.removedCount);
			Assert.equals(1, received.addedCount);
			Assert.equals(2, received.updatedCount);
			received.apply(base, into);
			received.apply(held, held);
		});
		Assert.isTrue(sameMap(current, into), "the patch applied to its base was not the map sent");
		Assert.isTrue(into.get(2) == kept, "a value into held was not patched in place");
		Assert.isFalse(into.get(1) == base.get(1), "a value was shared with the base");
		Assert.isTrue(sameMap(current, held));
	}

	public function testKeysCloseTogetherTakeAByteEach():Void {
		final codec = RPCCodecs.of(MapShip);
		final base = world([100 => ship(1, 0), 101 => ship(1, 0), 102 => ship(1, 0), 200 => ship(1, 0)]);
		final current = world([101 => ship(1, 0), 102 => ship(2, 0), 103 => ship(1, 0), 200 => ship(1, 0)]);
		final patch = new RPCMapPatch(codec).diff(base, current);
		// head 1 removed (2), 1 added, 1 updated; removed 100 (zigzag 200);
		// added 103 (zigzag 206), its patch from the default: the mask (x and
		// y) and x 1; updated 102 (zigzag 204), its mask (x) and x 2.
		Assert.equals("02" + "01" + "01" + "c801" + "ce01" + "01" + "0000803f" + "cc01" + "01" + "00000040", argumentsOf(commands -> commands.ships(5, patch)).substr(2));
		// The design's remote ship as an entry: a key of 1 byte and 11 of patch.
		final b = world([3 => stellar(1520, -310, 16000)]);
		final c = world([3 => stellar(1524, -311.5, 16384)]);
		final remote = argumentsOf(commands -> commands.remote(new RPCMapPatch(RPCCodecs.of(MapRemote)).diff(b, c)));
		Assert.equals("00" + "00" + "01" + "06" + "c1" + "0040" + "0080be44" + "00c09bc3", remote);
	}

	public function testViewsOfSharedFramesInAnyOrder():Void {
		final fixture = new MapPatchFixture();
		// One frame of the world's values per tick, a list of ids per observer.
		final tick1 = world([5 => ship(5, 0), 8 => ship(8, 0), 2 => ship(2, 0), 40 => ship(40, 0)]);
		final tick2 = world([5 => ship(5, 1), 8 => ship(8, 0), 2 => ship(2, 0), 40 => ship(40, 0), 41 => ship(41, 0)]);
		final view1 = ids([40, 2, 8]);
		final view2 = ids([41, 5, 8, 2, 8]); // grid order, 8 twice
		final patch = new RPCMapPatch(RPCCodecs.of(MapShip)).diffKeys(tick1, view1, tick2, view2);
		Assert.equals("40", patch.removed.toArray().join(","));
		Assert.equals(2, patch.addedCount);
		Assert.equals(5, patch.addedKey(0));
		Assert.equals(41, patch.addedKey(1));
		Assert.equals(0, patch.updatedCount);
		// The client keeps frames as values and keys; the second frame, into
		// one that held an older tick's.
		final frame1 = world([40 => ship(40, 0), 2 => ship(2, 0), 8 => ship(8, 0)]);
		final keys1 = ids([2, 8, 40]);
		final frame2 = new IntMap<MapShip>();
		final keys2 = new IdList();
		final reused = world([1 => ship(0, 0), 8 => ship(0, 0)]);
		final reusedKeys = ids([1, 8]);
		final eight = reused.get(8);
		fixture.handler.inCall.test(() -> fixture.commands.ships(2, patch), () -> {
			fixture.handler.lastShips.applyKeys(frame1, keys1, frame2, keys2);
			fixture.handler.lastShips.applyKeys(frame1, keys1, reused, reusedKeys, true);
		});
		Assert.equals("2,5,8,41", keys2.toArray().join(","));
		Assert.isTrue(sameMap(world([2 => ship(2, 0), 5 => ship(5, 1), 8 => ship(8, 0), 41 => ship(41, 0)]), frame2));
		Assert.equals("2,5,8,41", reusedKeys.toArray().join(","));
		Assert.isTrue(sameMap(frame2, reused));
		Assert.isTrue(reused.get(8) == eight);
		Assert.isFalse(reused.exists(1));
	}

	public function testValuesThatNeverChangeAreOnlyAddedAndRemoved():Void {
		final codec = RPCCodecs.of(MapShip);
		final bolt = ship(3, 3);
		final base = new IntMap<MapShip>();
		base.set(1, bolt);
		base.set(2, ship(4, 4));
		final current = new IntMap<MapShip>();
		current.set(1, bolt); // the same object in both frames
		current.set(3, ship(5, 5));
		final patch = new RPCMapPatch(codec).diff(base, current);
		Assert.equals(0, patch.updatedCount);
		Assert.equals(1, patch.addedCount);
		Assert.equals(1, patch.removedCount);
		Assert.isFalse(patch.isEmpty);
		Assert.isTrue(new RPCMapPatch(codec).diff(base, base).isEmpty);
	}

	public function testAFullPatchClearsWhatTheReceiverHeld():Void {
		final fixture = new MapPatchFixture();
		final current = world([3 => ship(3, 0), 1 => ship(1, 1)]);
		final patch = new RPCMapPatch(RPCCodecs.of(MapShip)).diff(null, current);
		Assert.isTrue(patch.isFull);
		Assert.equals(2, patch.addedCount);
		final into = world([9 => ship(9, 9), 3 => ship(0, 0)]);
		fixture.handler.inCall.test(() -> fixture.commands.ships(1, patch), () -> {
			final received = fixture.handler.lastShips;
			Assert.isTrue(received.isFull);
			received.apply(null, into);
			// The added values, one by one.
			Assert.equals(1, received.addedKey(0));
			Assert.equals(1.0, (received.addedValue(0).y : Float));
		});
		Assert.isTrue(sameMap(current, into));
	}

	public function testRecycledValuesServeTheNextAdds():Void {
		final fixture = new MapPatchFixture();
		final base = world([1 => ship(1, 0), 2 => ship(2, 0)]);
		final held = copyOf(base);
		final dropped = held.get(1);
		fixture.handler.inCall.test(() -> fixture.commands.ships(1, new RPCMapPatch(RPCCodecs.of(MapShip)).diff(base, world([2 => ship(2, 0)]))),
			() -> fixture.handler.lastShips.apply(held, held, true));
		Assert.isFalse(held.exists(1));
		final next = world([2 => ship(2, 0), 5 => ship(5, 5)]);
		fixture.handler.inCall.test(() -> fixture.commands.ships(2, new RPCMapPatch(RPCCodecs.of(MapShip)).diff(world([2 => ship(2, 0)]), next)),
			() -> fixture.handler.lastShips.apply(held, held, true));
		InCall.assertKept(dropped, held.get(5), "a dropped value was not used for the next add");
		Assert.isTrue(sameMap(next, held));
	}

	public function testUpdatesOneByOne():Void {
		final fixture = new MapPatchFixture();
		final base = world([4 => ship(4, 0)]);
		final mine = ship(4, 0);
		fixture.handler.inCall.test(() -> fixture.commands.ships(1, new RPCMapPatch(RPCCodecs.of(MapShip)).diff(base, world([4 => ship(4, 44)]))),
			() -> Assert.isTrue(fixture.handler.lastShips.applyUpdate(0, mine) == mine));
		Assert.equals(44.0, (mine.y : Float));
	}

	public function testAWrongBaseIsRefusedNamingTheKey():Void {
		final fixture = new MapPatchFixture();
		final base = world([1 => ship(1, 0), 2 => ship(2, 0)]);
		final other = world([2 => ship(2, 0)]);
		fixture.handler.inCall.test(() -> fixture.commands.ships(1, new RPCMapPatch(RPCCodecs.of(MapShip)).diff(base, world([2 => ship(2, 9)]))), () -> {
			Assert.raises(() -> fixture.handler.lastShips.apply(other, other), ArgumentError);
			Assert.raises(() -> fixture.handler.lastShips.apply(world([1 => ship(1, 0)]), new IntMap()), ArgumentError);
			Assert.raises(() -> fixture.handler.lastShips.apply(null, new IntMap()), ArgumentError);
		});
	}

	public function testHostilePatchesAreUnreadable():Void {
		final shipsOp:Int = RPCOps.opOf("count(~[i32:" + SHIP_TOKEN + "]):i32");
		final cases:Array<ByteArrayOutput->Void> = [
			// Removed keys past 2^31 - 1.
			out -> {
				out.writeVarUInt(4);
				out.writeVarUInt(0);
				out.writeVarUInt(0);
				out.writeVarUInt(0xFFFFFFFE); // zigzag of 2^31 - 1
				out.writeVarUInt(0);
			},
			// The same key twice is not ascending: a gap of 2^32 - 1.
			out -> {
				out.writeVarUInt(4);
				out.writeVarUInt(0);
				out.writeVarUInt(0);
				out.writeVarUInt(2);
				out.writeVarUInt(0xFFFFFFFF);
			},
			// A gap carrying the next key past 2^31 - 1: 5, then 5 + 2^31.
			out -> {
				out.writeVarUInt(4);
				out.writeVarUInt(0);
				out.writeVarUInt(0);
				out.writeVarUInt(10);
				out.writeVarUInt(0x7FFFFFFF);
			},
			// Counts past the frame.
			out -> {
				out.writeVarUInt(0);
				out.writeVarUInt(1000000);
				out.writeVarUInt(0);
			},
			out -> {
				out.writeVarUInt(0xFFFFFFFE);
				out.writeVarUInt(0);
				out.writeVarUInt(0);
			},
			out -> {
				out.writeVarUInt(0);
				out.writeVarUInt(0);
				out.writeVarUInt(0x7FFFFFFF);
			},
			// A full patch that removes.
			out -> {
				out.writeVarUInt(3);
				out.writeVarUInt(0);
				out.writeVarUInt(0);
				out.writeVarUInt(2);
			},
			// An entry whose patch is cut short.
			out -> {
				out.writeVarUInt(0);
				out.writeVarUInt(1);
				out.writeVarUInt(0);
				out.writeVarUInt(2);
				out.writeByte(0x01);
			}
		];
		var id:Int = 0;
		for (write in cases) {
			final fixture = new MapPatchFixture();
			final answers = errorAnswersAt(fixture.link.client);
			id++;
			final at:Int = id;
			fixture.link.client.send(frameOf(out -> {
				out.writeByte(RPCWire.FLAG_REQUEST);
				out.writeInt(shipsOp);
				out.writeVarUInt(at);
				write(out);
			}));
			Assert.same([at + ": " + RPCError.UNREADABLE_MESSAGE], answers, 'case $at was not answered as unreadable');
			Assert.equals(0, fixture.handler.counted);
		}
	}

	public function testAMapPatchIsBytesOfItsOwnToo():Void {
		final codec = RPCCodecs.of(MapShip);
		final base = world([1 => ship(1, 0), 2 => ship(2, 0)]);
		final current = world([2 => ship(2, 2), 3 => ship(3, 3)]);
		final out = new ByteArray();
		new RPCMapPatch(codec).diff(base, current).write(out);
		out.position = 0;
		final read = new RPCMapPatch(codec).read(out);
		Assert.equals(out.length, out.position);
		final into = new IntMap<MapShip>();
		read.apply(base, into);
		Assert.isTrue(sameMap(current, into));
		// A patch carried in a Bytes argument, as a generic channel does.
		final fixture = new MapPatchFixture();
		fixture.commands.raw((out : Bytes).sub(0, out.length));
		final carried = new RPCMapPatch(codec).read(ByteArray.fromBytes(fixture.handler.lastRaw));
		final again = new IntMap<MapShip>();
		carried.apply(base, again);
		Assert.isTrue(sameMap(current, again));
	}

	public function testTheSizeBoundCoversThePatch():Void {
		final codec = RPCCodecs.of(MapShip);
		final base = world([for (i in 0...16) i * 3 => ship(i, 0)]);
		final current = world([for (i in 2...20) i * 3 => ship(i, i % 2)]);
		final patch = new RPCMapPatch(codec).diff(base, current);
		final bytes:Int = Std.int(argumentsOf(commands -> commands.ships(1, patch)).length / 2) - 1;
		Assert.isTrue(patch.sizeBound() >= bytes, 'a bound of ${patch.sizeBound()} for $bytes bytes');
		Assert.equals(-1, new RPCMapPatch(RPCCodecs.of(MapNamed)).diff(null, new IntMap()).sizeBound());
	}

	public function testAMapPatchsKindIsInTheOp():Void {
		final fixture = new MapPatchFixture();
		fixture.handler.inCall.test(() -> fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("ships(vu,~[i32:" + SHIP_TOKEN + "])"));
			out.writeVarUInt(3);
			out.writeVarUInt(0);
			out.writeVarUInt(1);
			out.writeVarUInt(0);
			out.writeVarUInt(14); // key 7
			out.writeByte(0);
		})), () -> Assert.equals(7, fixture.handler.lastShips.addedKey(0)));
	}

	public function testStringKeys():Void {
		final fixture = new MapPatchFixture();
		final codec = RPCCodecs.of(MapShip);
		final base = new StringMap<MapShip>();
		base.set("ann", ship(1, 0));
		base.set("bob", ship(2, 0));
		base.set("\u{E9}t\u{E9}", ship(3, 0));
		final current = new StringMap<MapShip>();
		current.set("bob", ship(2, 1));
		current.set("\u{E9}t\u{E9}", ship(3, 0));
		current.set("cy", ship(4, 0));
		final patch = new RPCStringMapPatch(codec).diff(base, current);
		Assert.same(["ann"], patch.removed);
		Assert.equals("cy", patch.addedKey(0));
		Assert.equals("bob", patch.updatedKey(0));
		final into = new StringMap<MapShip>();
		fixture.handler.inCall.test(() -> fixture.commands.named(patch), () -> fixture.handler.lastNamed.apply(base, into));
		Assert.equals(3, [for (_ in into.keys()) 1].length);
		Assert.equals(1.0, (into.get("bob").y : Float));
		Assert.equals(4.0, (into.get("cy").x : Float));
		Assert.equals(3.0, (into.get("\u{E9}t\u{E9}").x : Float));
		// Keys out of order are unreadable.
		final answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("countNamed(~[utf8:" + SHIP_TOKEN + "]):i32"));
			out.writeVarUInt(8);
			out.writeVarUInt(4);
			out.writeVarUInt(0);
			out.writeVarUInt(0);
			out.writeVarUtf("b");
			out.writeVarUtf("a");
		}));
		Assert.same(["8: " + RPCError.UNREADABLE_MESSAGE], answers);
	}

	public function testRandomMapPatchesMakeTheMapAndAreTheSameBytesEverywhere():Void {
		var seed:Int = 77;
		final next = (bound:Int) -> {
			seed = (Hash.mul32(seed, 1103515245) + 12345) & 0x7FFFFFFF;
			return (seed >>> 8) % bound;
		};
		final codec = RPCCodecs.of(MapShip);
		final out = new ByteArray();
		final sending = new RPCMapPatch(codec);
		final reading = new RPCMapPatch(codec);
		var wrong:Int = 0;
		var frame = new IntMap<MapShip>();
		var keys = new IdList();
		for (_ in 0...200) {
			final base = new IntMap<MapShip>();
			final baseKeys = new IdList();
			final current = new IntMap<MapShip>();
			final currentKeys = new IdList();
			for (_ in 0...next(20)) {
				final key:Int = next(3) == 0 ? next(2000000) - 1000000 : next(60);
				if (!base.exists(key)) {
					base.set(key, ship(next(100), next(100)));
					baseKeys.push(key);
				}
			}
			for (key in baseKeys) {
				if (next(4) != 0) {
					final value = codec.copy(base.get(key), new MapShip());
					if (next(2) == 0) {
						value.x = next(100);
					}
					current.set(key, value);
					currentKeys.push(key);
				}
			}
			for (_ in 0...next(6)) {
				final key:Int = next(100);
				if (!current.exists(key)) {
					current.set(key, ship(next(100), next(100)));
					currentKeys.push(key);
				}
			}
			final full:Bool = next(8) == 0;
			final at:Int = out.length;
			out.position = at;
			sending.diffKeys(full ? null : base, full ? null : baseKeys, current, currentKeys).write(out);
			out.position = at;
			reading.read(out);
			reading.applyKeys(base, baseKeys, frame, keys, true);
			if (!sameMap(current, frame) || keys.length != [for (_ in current.keys()) 1].length) {
				wrong++;
			}
		}
		Assert.equals(0, wrong, "map patches did not make their maps");
		final bytes:Bytes = (out : Bytes).sub(0, out.length);
		Assert.equals(FUZZ_BYTES, bytes.length);
		Assert.equals(FUZZ_HASH, Hash.fnv1a32(bytes));
	}

	// What every target writes for the random patches above.
	static inline final FUZZ_BYTES:Int = 12081;
	static inline final FUZZ_HASH:Int = -174239266;

	// ------------------------------------------------------------------

	static inline final SHIP_TOKEN:String = "{x:f32,y:f32}";

	static function ship(x:Float, y:Float):MapShip {
		final s = new MapShip();
		s.x = x;
		s.y = y;
		return s;
	}

	static function stellar(x:Float, y:Float, aim:Int):MapRemote {
		final s = new MapRemote();
		s.x = x;
		s.y = y;
		s.vx = 120;
		s.vy = -45;
		s.aimSteps = aim;
		s.controls = 5;
		s.engineHeat = 180;
		return s;
	}

	static function world<T>(values:Map<Int, T>):IntMap<T> {
		final map = new IntMap<T>();
		for (key => value in values) {
			map.set(key, value);
		}
		return map;
	}

	static function copyOf(map:IntMap<MapShip>):IntMap<MapShip> {
		final copy = new IntMap<MapShip>();
		for (key => value in map) {
			copy.set(key, RPCCodecs.of(MapShip).copy(value, new MapShip()));
		}
		return copy;
	}

	static function ids(values:Array<Int>):IdList {
		final list = new IdList();
		for (value in values) {
			list.push(value);
		}
		return list;
	}

	static function sameMap(a:IntMap<MapShip>, b:IntMap<MapShip>):Bool {
		final codec = RPCCodecs.of(MapShip);
		var count:Int = 0;
		for (key => value in a) {
			count++;
			if (!b.exists(key) || !codec.equals(value, b.get(key))) {
				return false;
			}
		}
		for (_ in b.keys()) {
			count--;
		}
		return count == 0;
	}

	/** The hex of a one-way call's arguments, from a session that sends nowhere. **/
	static function argumentsOf(call:MapPatchCommands->Void):String {
		final link = LinkedConnection.pair();
		final commands = new MapPatchCommands();
		final session = new RPCSession<MapPatchCommands>(link.client, commands);
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

class MapShip implements RPCStruct {
	public var x:Float32 = 0;
	public var y:Float32 = 0;

	public function new() {}
}

/** Stellar's remote ship, with today's field types. **/
class MapRemote implements RPCStruct {
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

class MapNamed implements RPCStruct {
	public var name:String = "";

	public function new() {}
}

interface MapPatchContract {
	function ships(tick:VarUInt, ships:RPCMapPatch<MapShip>):Void;
	function count(ships:RPCMapPatch<MapShip>):Int;
	function remote(ships:RPCMapPatch<MapRemote>):Void;
	function named(ships:RPCStringMapPatch<MapShip>):Void;
	function countNamed(ships:RPCStringMapPatch<MapShip>):Int;
	function raw(patch:Bytes):Void;
}

@:rpcContract(MapPatchContract)
private class MapPatchCommands extends RPCCommands {
	public function new() {}
}

private class MapPatchHandler extends RPCHandler implements MapPatchContract {
	public var lastShips:Null<RPCMapPatch<MapShip>> = null;
	public var lastNamed:Null<RPCStringMapPatch<MapShip>> = null;
	public var lastRaw:Null<Bytes> = null;
	public var counted:Int = 0;
	public final inCall = new InCall();

	public function new() {}

	public function ships(tick:VarUInt, ships:RPCMapPatch<MapShip>):Void {
		lastShips = ships;
		inCall.run();
	}

	public function count(ships:RPCMapPatch<MapShip>):Int {
		counted++;
		return ships.addedCount;
	}

	public function remote(ships:RPCMapPatch<MapRemote>):Void {}

	public function named(ships:RPCStringMapPatch<MapShip>):Void {
		lastNamed = ships;
		inCall.run();
	}

	public function countNamed(ships:RPCStringMapPatch<MapShip>):Int {
		counted++;
		return ships.addedCount;
	}

	public function raw(patch:Bytes):Void {
		lastRaw = patch;
	}
}

private class MapPatchFixture {
	public final link = LinkedConnection.pair();
	public final commands = new MapPatchCommands();
	public final handler = new MapPatchHandler();
	public final client:RPCSession<MapPatchCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<MapPatchCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}
