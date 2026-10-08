package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.Bytes;
import utest.Assert;

private typedef Scores = Array<Int>;

/**
	`Array<T>` on the compiled lane, of every kind it carries, nested too: a
	varint count and the elements, each as its kind is written, and the
	array's kind in the op as its element's inside brackets.
**/
class RPCArrayTest extends utest.Test {
	public function testArraysOfEachKindArriveAsSent():Void {
		var fixture = new ArrayFixture();
		var bytes = Bytes.ofString("abc");
		fixture.commands.all([1, -2, 0x7FFFFFFF], [1.5, -0.25], [true, false, true], ["one", "", "été"], [bytes, Bytes.alloc(0)]);
		Assert.equals(1, fixture.handler.calls.length);
		Assert.equals("[1,-2,2147483647] [1.5,-0.25] [true,false,true] [one,,été] [abc,]", fixture.handler.calls[0]);
	}

	public function testEmptyAndNestedArraysArriveAsSent():Void {
		var fixture = new ArrayFixture();
		fixture.commands.grid([]);
		fixture.commands.grid([[], [1], [2, 3]]);
		fixture.commands.deep([[["a"], []], []]);
		Assert.same(["grid []", "grid [[],[1],[2,3]]", "deep [[[a],[]],[]]"], fixture.handler.calls);
	}

	public function testAnArrayIsAnAnswer():Void {
		var fixture = new ArrayFixture();
		var answer = fixture.commands.split("a,b,,c");
		Assert.isTrue(answer.succeeded);
		Assert.same(["a", "b", "", "c"], answer.result);
		var none = fixture.commands.split("");
		Assert.same([""], none.result);
		Assert.same([3, 1], fixture.commands.counts([[1, 2, 3], [4]]).result);
	}

	public function testElementsThatMayBeAbsentCarryTheirAbsence():Void {
		var fixture = new ArrayFixture();
		fixture.commands.gaps([1, null, 3, null]);
		fixture.commands.maybe(null);
		fixture.commands.maybe([7]);
		Assert.same(["gaps [1,null,3,null]", "maybe null", "maybe [7]"], fixture.handler.calls, fixture.handler.calls.join(" / "));
	}

	public function testATypedefOfAnArrayIsTheArraysKind():Void {
		// Named through a typedef on one side and written out on the other.
		var fixture = new ArrayFixture();
		Assert.equals(6, fixture.commands.total([1, 2, 3]).result);
	}

	public function testAnArraysKindIsInTheOp():Void {
		Assert.equals("all([i32],[f64],[bool],[utf8],[bytes])", RPCOps.signature("all", ["[i32]", "[f64]", "[bool]", "[utf8]", "[bytes]"], null));
		// A call framed by hand with the op the grammar gives reaches the method.
		var fixture = new ArrayFixture();
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("gaps([?i32])"));
			out.writeVarUInt(2);
			out.writeByte(1);
			out.writeInt(5);
			out.writeByte(0);
		}));
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("grid([[i32]])"));
			out.writeVarUInt(1);
			out.writeVarUInt(1);
			out.writeInt(9);
		}));
		Assert.same(["gaps [5,null]", "grid [[9]]"], fixture.handler.calls);
	}

	public function testAnArrayOfAnotherElementIsAnotherMethod():Void {
		// `[i32]` sent to a method of `[f64]`: the same count, and four bytes
		// an element where eight are read. Another op, so the call finds no
		// method rather than reading one kind as another.
		var link = LinkedConnection.pair();
		var commands = new MismatchCommands();
		var handler = new MismatchHandler();
		var client = new RPCSession<MismatchCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, handler);
		var answer = commands.sum([1, 2]);
		Assert.isFalse(answer.succeeded);
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, answer.error);
		Assert.equals(0, handler.calls);
		Assert.notNull(client);
		Assert.notNull(server);
	}

	public function testANullArrayIsRefusedBeforeAnythingIsSent():Void {
		var fixture = new ArrayFixture();
		var sent:Int = fixture.link.client.sent;
		Assert.raises(() -> fixture.commands.grid(null), ArgumentError);
		Assert.equals(sent, fixture.link.client.sent, "a call with a null array was sent");
		Assert.same([], fixture.handler.calls);
	}

	public function testANullInsideAnArrayIsRefusedAndTheFrameGivenBack():Void {
		var fixture = new ArrayFixture();
		var sent:Int = fixture.link.client.sent;
		Assert.raises(() -> fixture.commands.all([1], [1.0], [true], ["a", null], []), ArgumentError);
		Assert.raises(() -> fixture.commands.grid([[1], null]), ArgumentError);
		Assert.equals(sent, fixture.link.client.sent, "a call with a null inside an array was sent");
		// The session's frame was given back, not left taken: the next call
		// is framed in it.
		Assert.isFalse((@:privateAccess fixture.client.__frame != null && @:privateAccess fixture.client.__frame.busy), "the frame was left taken by the call that threw");
		fixture.commands.grid([[4]]);
		Assert.same(["grid [[4]]"], fixture.handler.calls);
		Assert.isFalse((@:privateAccess fixture.client.__frame != null && @:privateAccess fixture.client.__frame.busy));
	}

	public function testAnAnswerWithANullInsideFailsTheCallAndTheConnectionStays():Void {
		var fixture = new ArrayFixture();
		var reported:Array<String> = [];
		fixture.server.onHandlerError = (op, method, error) -> reported.push(method);
		var answer = fixture.commands.split("null");
		Assert.isFalse(answer.succeeded);
		Assert.equals(RPCError.INTERNAL_MESSAGE, answer.error);
		Assert.same(["split"], reported);
		Assert.isFalse((@:privateAccess fixture.server.__frame != null && @:privateAccess fixture.server.__frame.busy), "the answer's frame was left taken");
		Assert.same(["x"], fixture.commands.split("x").result);
	}

	public function testACountPastTheFrameIsUnreadableAndAllocatesNothingForIt():Void {
		// A count the peer chose, past what the frame holds: refused before an
		// array is made for it, the request answered as unreadable, and the
		// connection carries on.
		for (count in [3, 1000, 0x7FFFFFFF, -1]) {
			var fixture = new ArrayFixture();
			var answers = errorAnswersAt(fixture.link.client);
			var ended:Bool = false;
			fixture.link.server.onClose = _ -> ended = true;
			fixture.link.server.onError = _ -> ended = true;
			fixture.link.client.send(frameOf(out -> {
				out.writeByte(RPCWire.FLAG_REQUEST);
				out.writeInt(RPCOps.opOf("counts([[i32]]):[i32]"));
				out.writeVarUInt(1);
				out.writeVarUInt(count);
				out.writeVarUInt(0);
				out.writeVarUInt(0);
			}));
			Assert.same(["1: " + RPCError.UNREADABLE_MESSAGE], answers, 'a count of $count was not answered as unreadable');
			Assert.isFalse(ended, 'a count of $count ended the connection');
			Assert.same([], fixture.handler.calls);
		}
	}

	public function testACountPastTheBytesItsElementsNeedIsUnreadable():Void {
		// Three Ints named, eight bytes there: within the frame by count, not
		// by the four bytes each Int takes.
		var fixture = new ArrayFixture();
		var answers = errorAnswersAt(fixture.link.client);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("total([i32]):i32"));
			out.writeVarUInt(4);
			out.writeVarUInt(3);
			out.writeInt(1);
			out.writeInt(2);
		}));
		Assert.same(["4: " + RPCError.UNREADABLE_MESSAGE], answers);
		Assert.equals(0, fixture.handler.totals);
	}

	public function testANestedArrayCutShortIsUnreadable():Void {
		// The outer count holds; an inner one runs past the frame's end, into
		// the frame after it, which is read on its own.
		var fixture = new ArrayFixture();
		var answers = errorAnswersAt(fixture.link.client);
		var short = frameOf(out -> {
			out.writeByte(RPCWire.FLAG_REQUEST);
			out.writeInt(RPCOps.opOf("counts([[i32]]):[i32]"));
			out.writeVarUInt(2);
			out.writeVarUInt(1);
			out.writeVarUInt(2);
			out.writeInt(1);
		});
		var sound = frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("grid([[i32]])"));
			out.writeVarUInt(1);
			out.writeVarUInt(1);
			out.writeInt(5);
		});
		var both = new ByteArray();
		both.writeBytes(short, 0, short.length);
		both.writeBytes(sound, 0, sound.length);
		both.position = 0;
		fixture.link.client.send(both);
		Assert.same(["2: " + RPCError.UNREADABLE_MESSAGE], answers);
		Assert.same(["grid [[5]]"], fixture.handler.calls);
	}

	public function testAOneWayCallWithAnUnreadableArrayIsPassedOver():Void {
		var fixture = new ArrayFixture();
		var passed:Array<String> = [];
		fixture.server.onUnreadableFrame = (op, requestId, reason) -> passed.push(reason);
		fixture.link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(RPCOps.opOf("grid([[i32]])"));
			out.writeVarUInt(50);
		}));
		fixture.commands.grid([[1]]);
		Assert.equals(1, passed.length);
		Assert.stringContains("arguments could not be read", passed[0]);
		Assert.same(["grid [[1]]"], fixture.handler.calls);
	}

	public function testAnArrayArrivingIsTheHandlersToKeep():Void {
		// Each call's array is made for it: one the handler kept is not the
		// next call's, nor written over by it.
		var fixture = new ArrayFixture();
		fixture.commands.grid([[1, 2]]);
		fixture.commands.grid([[3, 4]]);
		Assert.equals(2, fixture.handler.kept.length);
		Assert.same([[1, 2]], fixture.handler.kept[0]);
		Assert.same([[3, 4]], fixture.handler.kept[1]);
		Assert.isFalse(fixture.handler.kept[0] == fixture.handler.kept[1]);
	}

	public function testALargeArrayGrowsTheFrameAsItIsWritten():Void {
		// A frame is begun with what the array takes empty; its writer makes
		// the rest. Past the size a session keeps its buffer at, too.
		var fixture = new ArrayFixture();
		var big:Array<String> = [for (i in 0...3000) "item" + i];
		Assert.equals(3000, fixture.commands.size(big).result);
		var small:Array<String> = ["a"];
		Assert.equals(1, fixture.commands.size(small).result);
	}

	/** One frame: its length, then what `write` puts in it. **/
	static function frameOf(write:ByteArrayOutput->Void):ByteArray {
		var payload = new ByteArrayOutput(64);
		write(payload);
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}

	/** Each error answer `connection` is sent from now on, as `<id>: <message>`; nothing reads it otherwise. **/
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

interface ArrayContract {
	function all(ints:Array<Int>, floats:Array<Float>, bools:Array<Bool>, strings:Array<String>, blobs:Array<Bytes>):Void;
	function grid(rows:Array<Array<Int>>):Void;
	function deep(levels:Array<Array<Array<String>>>):Void;
	function gaps(values:Array<Null<Int>>):Void;
	function maybe(values:Null<Array<Int>>):Void;
	function split(text:String):Array<String>;
	function counts(rows:Array<Array<Int>>):Array<Int>;
	function total(values:Scores):Int;
	function size(values:Array<String>):Int;
}

@:rpcContract(ArrayContract)
private class ArrayCommands extends RPCCommands {
	public function new() {}
}

private class ArrayHandler extends RPCHandler implements ArrayContract {
	public final calls:Array<String> = [];
	public final kept:Array<Array<Array<Int>>> = [];
	public var totals:Int = 0;

	public function new() {}

	public function all(ints:Array<Int>, floats:Array<Float>, bools:Array<Bool>, strings:Array<String>, blobs:Array<Bytes>):Void {
		calls.push(show(ints) + " " + show(floats) + " " + show(bools) + " " + show(strings) + " " + show(blobs.map(b -> b.toString())));
	}

	public function grid(rows:Array<Array<Int>>):Void {
		kept.push(rows);
		calls.push("grid " + show(rows.map(show)));
	}

	public function deep(levels:Array<Array<Array<String>>>):Void {
		calls.push("deep " + show(levels.map(level -> show(level.map(show)))));
	}

	public function gaps(values:Array<Null<Int>>):Void {
		calls.push("gaps " + show(values));
	}

	public function maybe(values:Null<Array<Int>>):Void {
		calls.push("maybe " + (values == null ? "null" : show(values)));
	}

	public function split(text:String):Array<String> {
		// A null where an element has to be: the answer cannot be written.
		return text == "null" ? ["a", null] : text.split(",");
	}

	public function counts(rows:Array<Array<Int>>):Array<Int> {
		calls.push("counts");
		return rows.map(row -> row.length);
	}

	public function total(values:Array<Int>):Int {
		totals++;
		var sum:Int = 0;
		for (value in values) {
			sum += value;
		}
		return sum;
	}

	public function size(values:Array<String>):Int {
		return values.length;
	}

	static function show<T>(values:Array<T>):String {
		return "[" + [for (value in values) value == null ? "null" : Std.string(value)].join(",") + "]";
	}
}

private class ArrayFixture {
	public final link = LinkedConnection.pair();
	public final commands = new ArrayCommands();
	public final handler = new ArrayHandler();
	public final client:RPCSession<ArrayCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<ArrayCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

private class MismatchCommands extends RPCCommands {
	public function new() {}

	@:rpc public function sum(values:Array<Int>):RPCResponse<Float> {}
}

private class MismatchHandler extends RPCHandler {
	public var calls:Int = 0;

	public function new() {}

	@:rpc public function sum(values:Array<Float>):Float {
		calls++;
		return 0;
	}
}
