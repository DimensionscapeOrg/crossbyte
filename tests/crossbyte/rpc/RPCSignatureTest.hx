package crossbyte.rpc;

import crossbyte.rpc._internal.RPCOps;
import crossbyte.utils.Hash;
import haxe.io.Bytes;
import utest.Assert;

private typedef Coordinate = Float;
private typedef Label = String;
private typedef Count = Int;
private typedef MaybeInt = Null<Int>;

/**
	A compiled method's op is the hash of its signature, its name and the
	kinds of its arguments and answer, not of its name alone.

	A client and a server built from two versions of one method read each
	other's bytes as their own: `(x:Int, y:Int)` sent to `(v:Float)`, both
	eight bytes, ran the handler on a Float made of two Ints, and an answer
	of one kind was read as another. Now the two have different ops, and the
	call finds no method.
**/
class RPCSignatureTest extends utest.Test {
	public function testAnOpIsTheHashOfTheMethodsSignature():Void {
		Assert.equals("add(i32,i32):i32", RPCOps.signature("add", ["i32", "i32"], "i32"));
		Assert.equals("say(utf8)", RPCOps.signature("say", ["utf8"], null));
		Assert.equals("find(?i32,bytes):?utf8", RPCOps.signature("find", ["?i32", "bytes"], "?utf8"));
		Assert.equals("tick()", RPCOps.signature("tick", [], null));
		Assert.equals(Hash.fnv1a32(Bytes.ofString("add(i32,i32):i32")), RPCOps.opOf("add(i32,i32):i32"));
	}

	public function testAMethodWhoseArgumentsChangedIsNotRunOnThemMisread():Void {
		// The same eight bytes, read as one Float or two Ints.
		var fixture = new Fixture();
		fixture.commands.move(1, 2);
		Assert.same([], fixture.handler.moved, "a handler ran on another version's arguments");

		// The same kinds, reordered.
		var scaled = fixture.commands.scale(3, 0.5);
		Assert.same([], fixture.handler.scaled, "a handler ran on arguments reordered");
		Assert.isFalse(scaled.succeeded, "a call was answered by another version of its method: " + scaled.result);
		// Answered as a call for a method the server has not got, and the
		// connection carries on.
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, scaled.error);
		Assert.equals(9, fixture.commands.place(4.5, "nine").result);
	}

	public function testAnAnswerOfAnotherKindIsNotReadAsThisOne():Void {
		// An Int answer read as a Bool: one of its four bytes, and the rest
		// passed over.
		var fixture = new Fixture();
		var ready = fixture.commands.ready(7);
		Assert.isFalse(ready.succeeded, "an answer of another kind was read as this one's: " + ready.result);
		Assert.equals(RPCError.UNKNOWN_METHOD_MESSAGE, ready.error);
	}

	public function testRenamingAnArgumentOrATypedefChangesNoOp():Void {
		// The handler names its arguments and their types otherwise: a
		// typedef is the kind it names.
		var fixture = new Fixture();
		Assert.equals(9, fixture.commands.place(4.5, "nine").result);
	}

	public function testAnArgumentThatMayBeAbsentThroughATypedefCarriesItsAbsence():Void {
		// Named through a typedef of Null<Int> on one side and written out on
		// the other: one wrote it bare, the other read a byte first.
		var fixture = new Fixture();
		Assert.equals(5, fixture.commands.maybe(5).result);
		Assert.equals(-1, fixture.commands.maybe(null).result);
	}

	public function testAOneWayCallReachesAMethodThatAnswers():Void {
		// A one-way call has no answer in its signature, and a method with one
		// takes it as ever, its answer sent nowhere.
		var fixture = new Fixture();
		fixture.commands.fire(4);
		Assert.same([4], fixture.handler.fired);
	}
}

private class Fixture {
	public final link = LinkedConnection.pair();
	public final commands = new ClientVersionCommands();
	public final handler = new ServerVersionHandler();
	public final client:RPCSession<ClientVersionCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<ClientVersionCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
	}
}

/** The client, built from one version of each method. **/
private class ClientVersionCommands extends RPCCommands {
	public function new() {}

	@:rpc public function move(x:Int, y:Int):Void {}

	@:rpc public function scale(a:Int, b:Float):RPCResponse<Float> {}

	@:rpc public function ready(id:Int):RPCResponse<Bool> {}

	@:rpc public function place(x:Float, name:String):RPCResponse<Int> {}

	@:rpc public function maybe(value:MaybeInt):RPCResponse<Int> {}

	@:rpc public function fire(value:Int):Void {}
}

/** The server, built from another. **/
private class ServerVersionHandler extends RPCHandler {
	public final moved:Array<Float> = [];
	public final scaled:Array<Float> = [];
	public final fired:Array<Int> = [];

	public function new() {}

	@:rpc public function move(v:Float):Void {
		moved.push(v);
	}

	@:rpc public function scale(b:Float, a:Int):Float {
		scaled.push(a * b);
		return a * b;
	}

	@:rpc public function ready(id:Int):Int {
		return 0x01000000 + id;
	}

	@:rpc public function place(position:Coordinate, label:Label):Count {
		return Std.int(position * 2);
	}

	@:rpc public function maybe(value:Null<Int>):Int {
		return value == null ? -1 : value;
	}

	@:rpc public function fire(value:Int):Int {
		fired.push(value);
		return value * 2;
	}
}
