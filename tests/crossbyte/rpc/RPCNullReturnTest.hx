package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import haxe.io.Bytes;
import utest.Assert;

private typedef MaybeName = Null<String>;

/**
	Answers that may be absent: a method returning `Null<T>`.

	The caller reads a byte saying whether the answer is there before the
	answer, as it does for an optional argument, so the handler writes that
	byte too. An answer written bare would have its first byte taken for
	that flag, the rest misread, and the connection closed, failing every
	other call waiting on it. A null `String` is written as absent on every
	target: not refused on eval and JavaScript, nor sent as "" on cpp.
**/
class RPCNullReturnTest extends utest.Test {
	public function testAContractAnswerThatMayBeAbsentCrosses():Void {
		var fixture = new Fixture();

		Assert.equals("one", fixture.commands.nickname(1).result);
		var none = fixture.commands.nickname(0);
		Assert.isTrue(none.succeeded, "an absent answer failed: " + none.error);
		Assert.isNull(none.result);
		Assert.equals(7, fixture.commands.score(7).result);
		var noScore = fixture.commands.score(0);
		Assert.isTrue(noScore.succeeded, "an absent Int failed: " + noScore.error);
		Assert.isNull(noScore.result);
		// The connection is still up and still in step.
		Assert.equals("two", fixture.commands.nickname(2).result);
		Assert.isFalse(fixture.ended, "the connection ended");
	}

	public function testAnAnswerLaterThatMayBeAbsentCrosses():Void {
		var fixture = new Fixture();

		var named = fixture.commands.nicknameLater(3);
		fixture.handler.pending.complete("three");
		Assert.equals("three", named.result);

		var unnamed = fixture.commands.nicknameLater(4);
		fixture.handler.pending.complete(null);
		Assert.isTrue(unnamed.succeeded, "an absent later answer failed: " + unnamed.error);
		Assert.isNull(unnamed.result);
		Assert.isFalse(fixture.ended);
	}

	public function testAnRpcMethodAnswerThatMayBeAbsentCrosses():Void {
		// Declared with @:rpc, and through a typedef, which is still Null<T> on
		// both sides whether or not either writes it out.
		var link = LinkedConnection.pair();
		var commands = new MaybeCommands();
		var client = new RPCSession<MaybeCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new MaybeHandler());

		Assert.equals(3, commands.blob(3).result.length);
		var noBlob = commands.blob(0);
		Assert.isTrue(noBlob.succeeded, "an absent Bytes failed: " + noBlob.error);
		Assert.isNull(noBlob.result);

		Assert.equals("ada", commands.alias("ada").result);
		var noAlias = commands.alias("");
		Assert.isTrue(noAlias.succeeded, "an absent answer named by a typedef failed: " + noAlias.error);
		Assert.isNull(noAlias.result);
		Assert.equals("bob", commands.alias("bob").result);
	}
}

private interface NicknameContract {
	function nickname(id:Int):Null<String>;
	function score(id:Int):Null<Int>;
	function nicknameLater(id:Int):Future<Null<String>>;
}

@:rpcContract(NicknameContract)
private class NicknameCommands extends RPCCommands {
	public function new() {}
}

private class NicknameHandler extends RPCHandler implements NicknameContract {
	public var pending:Completer<Null<String>>;

	public function new() {}

	public function nickname(id:Int):Null<String> {
		return switch (id) {
			case 1: "one";
			case 2: "two";
			default: null;
		}
	}

	public function score(id:Int):Null<Int> {
		return id == 0 ? null : id;
	}

	public function nicknameLater(id:Int):Future<Null<String>> {
		pending = new Completer<Null<String>>();
		return pending.future;
	}
}

private class Fixture {
	public final commands = new NicknameCommands();
	public final handler = new NicknameHandler();
	public var ended = false;

	final client:RPCSession<NicknameCommands>;
	final server:RPCSession<Dynamic>;

	public function new() {
		var link = LinkedConnection.pair();
		client = new RPCSession<NicknameCommands>(link.client, commands);
		server = new RPCSession(link.server, null, handler);
		link.client.onClose = _ -> ended = true;
		link.client.onError = _ -> ended = true;
	}
}

private class MaybeCommands extends RPCCommands {
	public function new() {}

	@:rpc public function blob(size:Int):RPCResponse<Null<Bytes>> {}

	@:rpc public function alias(name:String):RPCResponse<MaybeName> {}
}

private class MaybeHandler extends RPCHandler {
	public function new() {}

	@:rpc public function blob(size:Int):Null<Bytes> {
		return size == 0 ? null : Bytes.alloc(size);
	}

	@:rpc public function alias(name:String):MaybeName {
		return name.length == 0 ? null : name;
	}
}
