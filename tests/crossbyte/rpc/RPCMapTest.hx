package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCMaps;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import haxe.ds.IntMap;
import haxe.ds.StringMap;
import utest.Assert;

private typedef Labels = Map<String, String>;

/**
	`Map<String, T>` and `Map<Int, T>` on the compiled lane: a varint count,
	then each entry, its key and its value as their kinds are written, in
	the order of the keys, so one map is the same bytes however it was made.
	The count is checked against what the frame holds before a map is made.
**/
class RPCMapTest extends utest.Test {
	public function testMapsOfEachKeyArriveAsSent():Void {
		final fixture = new MapFixture();
		final scores = ["ann" => 3, "bob" => -1, "" => 0x7FFFFFFF, "été" => 7];
		Assert.equals(4, fixture.commands.count(scores).result);
		final echoed = fixture.commands.scores(scores).result;
		Assert.notNull(echoed);
		Assert.equals(describe(scores), describe(echoed));
		final names = [-5 => "minus five", 0 => "", 0x7FFFFFFF => "big"];
		Assert.equals(describeInt(names), describeInt(fixture.commands.names(names).result));
		final empty:Map<String, Int> = [];
		Assert.equals("{}", describe(fixture.commands.scores(empty).result));
	}

	public function testValuesOfEveryKindNestedAndAbsent():Void {
		final fixture = new MapFixture();
		final maybe:Map<String, Null<Int>> = ["a" => 1, "b" => null];
		final back = fixture.commands.maybe(maybe).result;
		Assert.equals(1, back.get("a"));
		Assert.isTrue(back.exists("b") && back.get("b") == null, "an absent value did not arrive absent");
		final nested:Map<String, Map<Int, Bool>> = ["x" => [1 => true, 2 => false], "y" => new Map()];
		final nestedBack = fixture.commands.nested(nested).result;
		Assert.isTrue(nestedBack.get("x").get(1));
		Assert.isFalse(nestedBack.get("x").get(2));
		Assert.isFalse(nestedBack.get("y").iterator().hasNext());
		final lists:Map<String, Array<Int>> = ["one" => [1], "none" => []];
		Assert.same([1], fixture.commands.lists(lists).result.get("one"));
		Assert.same([[1 => "a"], [2 => "b"]].map(describeInt), fixture.commands.many([[1 => "a"], [2 => "b"]]).result.map(describeInt));
		final labels:Labels = ["tier" => "gold"];
		Assert.equals("gold", fixture.commands.labelled(labels).result.get("tier"));
	}

	public function testAMapIsAStructsField():Void {
		final fixture = new MapFixture();
		final realm = new MapRealm();
		realm.id = 9;
		realm.labels = ["region" => "eu", "tier" => "gold"];
		final back = fixture.commands.realm(realm).result;
		Assert.equals(9, back.id);
		Assert.equals("eu", back.labels.get("region"));
		Assert.equals("gold", back.labels.get("tier"));
	}

	public function testAMapAnswerReachesAReceiver():Void {
		final fixture = new MapFixture();
		final told = new MapReceiver();
		fixture.commands.scoresThen(["a" => 1], told);
		Assert.equals("{a: 1}", told.got);
	}

	public function testEntriesGoInTheOrderOfTheirKeys():Void {
		// Two maps of the same entries, made in opposite orders: the same bytes.
		final forward = new Map<String, Int>();
		final backward = new Map<String, Int>();
		final keys = [for (i in 0...300) "key" + i];
		for (i in 0...keys.length) {
			forward.set(keys[i], i);
			backward.set(keys[keys.length - 1 - i], keys.length - 1 - i);
		}
		final a = framesOfCall(commands -> commands.count(forward));
		final b = framesOfCall(commands -> commands.count(backward));
		Assert.equals(a, b, "one map's entries went in two orders");
		// {"b": 2, "a": 1}: a count of 2, then "a" and 1, then "b" and 2.
		final small = framesOfCall(commands -> commands.count(["b" => 2, "a" => 1]));
		Assert.equals("02" + "0161" + "01000000" + "0162" + "02000000", small.substr(small.length - 26), "the entries were not written in key order");
		// Int keys ascending, signed.
		final ints = framesOfCall(commands -> commands.names([3 => "", -1 => "", 0 => ""]));
		Assert.equals("03" + "ffffffff00" + "0000000000" + "0300000000", ints.substr(ints.length - 32));
	}

	public function testKeysAreOrderedByUtf16CodeUnit():Void {
		// U+FFFD before U+1F600 by code point, after it by UTF-16 unit (a high
		// surrogate, 0xD83D): the order is the units', on every target.
		final keys = RPCMaps.stringKeys(["\u{FFFD}" => 1, "\u{1F600}" => 2, "b" => 3, "\u{E9}" => 4, "ab" => 5, "a" => 6]);
		Assert.same(["a", "ab", "b", "\u{E9}", "\u{1F600}", "\u{FFFD}"], keys);
		Assert.isTrue(RPCMaps.__byUnits("\u{1F600}", "\u{FFFD}") < 0);
		Assert.isTrue(RPCMaps.__byUnits("\u{1F600}", "\u{1F601}") < 0);
		Assert.isTrue(RPCMaps.__byUnits("a", "ab") < 0);
		Assert.equals(0, RPCMaps.__byUnits("\u{1F600}x", "\u{1F600}x"));
	}

	public function testTheSortOrdersEveryShape():Void {
		var seed = 12345;
		final next = () -> {
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
			return seed;
		};
		for (n in [0, 1, 2, 15, 16, 17, 100, 600]) {
			final shapes:Array<Array<Int>> = [
				[for (_ in 0...n) next() - 0x40000000],
				[for (i in 0...n) i],
				[for (i in 0...n) n - i],
				[for (_ in 0...n) 7],
				[for (i in 0...n) i % 3]
			];
			for (shape in shapes) {
				final expected = shape.copy();
				expected.sort((x, y) -> x < y ? -1 : (x > y ? 1 : 0));
				final ints = shape.copy();
				RPCMaps.sortInts(ints);
				Assert.same(expected, ints, 'ints of $n were not sorted');
				final strings = [for (v in shape) "k" + v];
				final expectedStrings = strings.copy();
				expectedStrings.sort((x, y) -> RPCMaps.__byUnits(x, y));
				final sortedStrings = strings.copy();
				RPCMaps.sortStrings(sortedStrings);
				Assert.same(expectedStrings, sortedStrings, 'strings of $n were not sorted');
				// Heapsorted from the first level, or the second: the path a set
				// of keys that defeats the quicksort's pivots takes.
				for (depth in [0, 1]) {
					final heapInts = shape.copy();
					RPCMaps.__sortIntsWithin(heapInts, depth);
					Assert.same(expected, heapInts, 'ints of $n were not heapsorted at depth $depth');
					final heapStrings = strings.copy();
					RPCMaps.__sortStringsWithin(heapStrings, depth);
					Assert.same(expectedStrings, heapStrings, 'strings of $n were not heapsorted at depth $depth');
				}
			}
		}
	}

	public function testACountPastTheFrameIsUnreadable():Void {
		for (count in [2, 1000, 0x7FFFFFFF, -1]) {
			final fixture = new MapFixture();
			final answers = errorAnswersAt(fixture.link.client);
			var ended:Bool = false;
			fixture.link.server.onClose = _ -> ended = true;
			fixture.link.server.onError = _ -> ended = true;
			fixture.link.client.send(frameOf(out -> {
				out.writeByte(RPCWire.FLAG_REQUEST);
				out.writeInt(RPCOps.opOf("count([utf8:i32]):i32"));
				out.writeVarUInt(1);
				out.writeVarUInt(count);
				out.writeVarUtf("a");
				out.writeInt(1);
			}));
			Assert.same(["1: " + RPCError.UNREADABLE_MESSAGE], answers, 'a count of $count was not answered as unreadable');
			Assert.isFalse(ended, 'a count of $count ended the connection');
			Assert.equals(0, fixture.handler.counted);
		}
	}

	public function testAKeyGivenTwiceKeepsItsLastValue():Void {
		final fixture = new MapFixture();
		final told:Array<String> = [];
		fixture.handler.onScores = map -> told.push(describe(map));
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("scores([utf8:i32])"));
			out.writeVarUInt(2);
			out.writeVarUtf("a");
			out.writeInt(1);
			out.writeVarUtf("a");
			out.writeInt(2);
		}));
		Assert.same(["{a: 2}"], told);
	}

	public function testANullMapOrValueIsRefusedBeforeAnythingIsSent():Void {
		final fixture = new MapFixture();
		final sent:Int = fixture.link.client.sent;
		Assert.raises(() -> fixture.commands.scores(null), ArgumentError);
		final withNull:Map<String, String> = ["a" => null];
		Assert.raises(() -> fixture.commands.labelled(withNull), ArgumentError);
		Assert.equals(sent, fixture.link.client.sent, "a map that could not be sent was");
		Assert.equals(1, fixture.commands.count(["a" => 1]).result, "the session did not call after it");
	}

	public function testAMapsKindIsInTheOp():Void {
		Assert.equals(RPCOps.opOf("count([utf8:i32]):i32"), opOfCall(commands -> commands.count(["a" => 1])));
		Assert.equals(RPCOps.opOf("names([i32:utf8]):[i32:utf8]"), opOfCall(commands -> commands.names([1 => "a"])));
		Assert.equals(RPCOps.opOf("maybe([utf8:?i32]):[utf8:?i32]"), opOfCall(commands -> commands.maybe(["a" => 1])));
		Assert.equals(RPCOps.opOf("nested([utf8:[i32:bool]]):[utf8:[i32:bool]]"), opOfCall(commands -> commands.nested(new Map())));
		Assert.equals(RPCOps.opOf("realm({id:i32,labels:[utf8:utf8]}):{id:i32,labels:[utf8:utf8]}"), opOfCall(commands -> commands.realm(new MapRealm())));
	}

	// ------------------------------------------------------------------

	static function describe(map:Map<String, Int>):String {
		final keys = [for (key in map.keys()) key];
		keys.sort((a, b) -> RPCMaps.__byUnits(a, b));
		return "{" + [for (key in keys) key + ": " + map.get(key)].join(", ") + "}";
	}

	static function describeInt(map:Map<Int, String>):String {
		final keys = [for (key in map.keys()) key];
		keys.sort((a, b) -> a - b);
		return "{" + [for (key in keys) key + ": " + map.get(key)].join(", ") + "}";
	}

	/** The hex of the last frame a call sends, from a session that sends nowhere. **/
	static function framesOfCall(call:MapCommands->Void):String {
		final link = LinkedConnection.pair();
		final commands = new MapCommands();
		final session = new RPCSession<MapCommands>(link.client, commands);
		Assert.notNull(session);
		var last:String = "";
		link.server.readEnabled = true;
		link.server.onData = input -> {
			final bytes = haxe.io.Bytes.alloc(input.bytesAvailable);
			input.readBytes(bytes, 0, bytes.length);
			last = bytes.toHex();
		};
		call(commands);
		return last;
	}

	static function opOfCall(call:MapCommands->Void):Int {
		final frame = framesOfCall(call);
		final bytes = haxe.io.Bytes.ofHex(frame);
		return bytes.getInt32(5);
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

class MapRealm implements RPCStruct {
	public var id:Int = 0;
	public var labels:Map<String, String> = new Map();

	public function new() {}
}

interface MapContract {
	function count(scores:Map<String, Int>):Int;
	function scores(scores:Map<String, Int>):Map<String, Int>;
	function names(names:Map<Int, String>):Map<Int, String>;
	function maybe(values:Map<String, Null<Int>>):Map<String, Null<Int>>;
	function nested(values:Map<String, Map<Int, Bool>>):Map<String, Map<Int, Bool>>;
	function lists(values:Map<String, Array<Int>>):Map<String, Array<Int>>;
	function many(values:Array<Map<Int, String>>):Array<Map<Int, String>>;
	function labelled(labels:Labels):StringMap<String>;
	function realm(realm:MapRealm):MapRealm;
}

@:rpcContract(MapContract)
private class MapCommands extends RPCCommands {
	public function new() {}
}

private class MapHandler extends RPCHandler implements MapContract {
	public var counted:Int = 0;
	public var onScores:Null<Map<String, Int>->Void> = null;

	public function new() {}

	public function count(scores:Map<String, Int>):Int {
		counted++;
		return [for (_ in scores.keys()) 1].length;
	}

	public function scores(scores:Map<String, Int>):Map<String, Int> {
		if (onScores != null) {
			onScores(scores);
		}
		return scores;
	}

	public function names(names:Map<Int, String>):Map<Int, String> {
		return names;
	}

	public function maybe(values:Map<String, Null<Int>>):Map<String, Null<Int>> {
		return values;
	}

	public function nested(values:Map<String, Map<Int, Bool>>):Map<String, Map<Int, Bool>> {
		return values;
	}

	public function lists(values:Map<String, Array<Int>>):Map<String, Array<Int>> {
		return values;
	}

	public function many(values:Array<Map<Int, String>>):Array<Map<Int, String>> {
		return values;
	}

	public function labelled(labels:Labels):StringMap<String> {
		final copy = new StringMap<String>();
		for (key => value in labels) {
			copy.set(key, value);
		}
		return copy;
	}

	public function realm(realm:MapRealm):MapRealm {
		return realm;
	}
}

private class MapReceiver implements RPCValueReceiver<Map<String, Int>> {
	public var got:String = "";

	public function new() {}

	public function onValue(call:Int, value:Map<String, Int>):Void {
		final keys = [for (key in value.keys()) key];
		keys.sort((a, b) -> RPCMaps.__byUnits(a, b));
		got = "{" + [for (key in keys) key + ": " + value.get(key)].join(", ") + "}";
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		got = "failed: " + failure;
	}
}

private class MapFixture {
	public final link = LinkedConnection.pair();
	public final commands = new MapCommands();
	public final handler = new MapHandler();
	public final client:RPCSession<MapCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<MapCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}
