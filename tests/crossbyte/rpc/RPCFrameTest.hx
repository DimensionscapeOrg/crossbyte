package crossbyte.rpc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.rpc._internal.RPCFrame;
import haxe.io.Bytes;
import utest.Assert;

/**
	One buffer a session: every frame a session sends (calls, answers,
	error answers, pings, on both lanes) is written in the one buffer the
	session keeps, and handed to `INetConnection.send`, which copies what it
	keeps before it returns.

	A `ByteArrayOutput` of its own for each frame, a call's and its
	answer's alike, would be most of what a call allocates. Under
	`-D crossbyte_check_events` each frame is a buffer of its own, poisoned
	once sent, so a transport that kept one is caught; under
	`-D crossbyte_fresh_events` each is one of its own and left as it is.
**/
@:access(crossbyte.rpc.RPCSession)
class RPCFrameTest extends utest.Test {
	public function testEveryFrameASessionSendsIsWrittenInItsOneBuffer():Void {
		var link = KeepingConnection.pair();
		var commands = new FrameCommands();
		var client = new RPCSession<FrameCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new FrameHandler());
		server.register(30, args -> args[0]);
		var keeping:KeepingConnection = cast link.client;
		// What each side said as it started, a hello, aside.
		keeping.forget();

		commands.note("first");
		Assert.equals("second!", commands.shout("second").result);
		Assert.equals(5, (client.request(30, [5]).result : Int));
		client.call(31, ["unanswered"]);
		client.__sendPing();

		// Every one arrived whole, in the order it was sent...
		Assert.same(["first"], (cast server.handler : FrameHandler).heard);
		Assert.same(["second"], (cast server.handler : FrameHandler).shouted);
		Assert.equals(5, keeping.kept.length);
		for (i in 0...keeping.kept.length) {
			Assert.notEquals(0, keeping.copies[i].length, 'frame $i was sent empty');
		}
		// ...and was written in the session's buffer, which each send left to
		// it, or, checking or fresh, in one of its own.
		#if (crossbyte_check_events || crossbyte_fresh_events)
		for (i in 1...keeping.kept.length) {
			Assert.isFalse(keeping.kept[i] == keeping.kept[0], 'frame $i was framed in the buffer of frame 0');
		}
		#else
		for (i in 1...keeping.kept.length) {
			Assert.isTrue(keeping.kept[i] == keeping.kept[0], 'frame $i was not framed in the session\'s buffer');
		}
		#end
		Assert.isFalse(client.__frame != null && client.__frame.busy, "the buffer was left in use");
	}

	public function testATransportThatKeepsAFrameKeepsWhatIsWrittenOverIt():Void {
		// Why `send` copies what it keeps: the frame it was handed is the
		// session's to write the next one over. Checking, it is poisoned the
		// moment the send returns instead.
		var link = KeepingConnection.pair();
		var commands = new FrameCommands();
		var client = new RPCSession<FrameCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new FrameHandler());
		var keeping:KeepingConnection = cast link.client;
		keeping.forget();

		commands.note("a message long enough to tell apart");
		final first:ByteArray = keeping.kept[0];
		final sent:Bytes = keeping.copies[0];
		#if crossbyte_check_events
		// Emptied, and its storage filled with RPCFrame.POISON: a transport
		// that kept the ByteArray sends nothing, one that kept its storage
		// sends garbage.
		Assert.equals(0, first.length, "a frame kept past its send was not emptied");
		Assert.equals(0, first.position);
		#else
		commands.note("x");
		#if crossbyte_fresh_events
		Assert.equals(sent.length, first.length, "a frame of its own changed after its send");
		#else
		Assert.notEquals(sent.length, first.length, "the next frame was not written over the one kept");
		#end
		#end
		Assert.same(["a message long enough to tell apart"].concat(#if crossbyte_check_events [] #else ["x"] #end),
			(cast server.handler : FrameHandler).heard);
	}

	public function testACallMadeFromInsideASendGetsAFrameOfItsOwn():Void {
		// The client relays to the server, whose handler calls the client
		// back from inside that send (the link delivers at once), and the
		// client's handler calls the server again while its own frame is
		// still being sent: that call cannot be framed over it.
		var link = KeepingConnection.pair();
		var clientCommands = new FrameCommands();
		var serverCommands = new FrameCommands();
		var clientHandler = new FrameHandler();
		var serverHandler = new FrameHandler();
		var client = new RPCSession<FrameCommands>(link.client, clientCommands, clientHandler);
		var server = new RPCSession<FrameCommands>(link.server, serverCommands, serverHandler);
		var keeping:KeepingConnection = cast link.client;
		keeping.forget();

		clientCommands.relay("outer");

		// The server heard the relay, then the call made inside it.
		Assert.same(["relay:outer", "inner:outer"], serverHandler.heard);
		Assert.same(["back:outer"], clientHandler.heard);
		Assert.equals(2, keeping.kept.length);
		Assert.isFalse(keeping.kept[1] == keeping.kept[0], "a frame was written over one still being sent");
		// Both arrived whole: the inner one was not written over the outer.
		Assert.isFalse(client.__frame != null && client.__frame.busy, "the buffer was left in use");

		// And the session's own buffer is used again afterwards.
		clientCommands.note("after");
		#if !(crossbyte_check_events || crossbyte_fresh_events)
		Assert.isTrue(keeping.kept[2] == keeping.kept[0], "the session's buffer was not used again");
		#end
		Assert.equals("after", serverHandler.heard[serverHandler.heard.length - 1]);
	}

	public function testASendThatThrowsGivesItsFrameBack():Void {
		var link = KeepingConnection.pair();
		var commands = new FrameCommands();
		var client = new RPCSession<FrameCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new FrameHandler());

		link.client.failSends = true;
		Assert.raises(() -> commands.note("lost"));
		var refused = commands.shout("lost too");
		Assert.isTrue(refused.completed && !refused.succeeded, "a call whose send threw was left waiting");
		Assert.isFalse(client.__frame != null && client.__frame.busy, "a send that threw left the buffer in use");

		link.client.failSends = false;
		Assert.equals("kept!", commands.shout("kept").result);
	}

	public function testAFrameLargerThanTheSessionKeepsIsLetGoOnceSent():Void {
		var link = KeepingConnection.pair();
		var commands = new FrameCommands();
		var client = new RPCSession<FrameCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new FrameHandler());
		var handler:FrameHandler = cast server.handler;

		final large = Bytes.alloc(RPCFrame.KEEP_LIMIT * 2);
		large.fill(0, large.length, 7);
		commands.store(large);
		Assert.equals(large.length, handler.stored);
		Assert.isTrue(client.__frame == null || client.__frame.capacity <= RPCFrame.KEEP_LIMIT, "a session kept a buffer past its limit");

		commands.note("small again");
		Assert.isTrue(client.__frame == null || client.__frame.capacity <= RPCFrame.KEEP_LIMIT);
		Assert.equals("small again", handler.heard[handler.heard.length - 1]);
	}

	public function testANullWhereAValueMustBeIsRefusedBeforeAnythingIsSent():Void {
		// A null String or Bytes argument is refused, rather than crashing the
		// process natively or throwing a null access on the interpreter and the jvm.
		var link = KeepingConnection.pair();
		var commands = new FrameCommands();
		var client = new RPCSession<FrameCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new FrameHandler());
		var keeping:KeepingConnection = cast link.client;
		keeping.forget();
		var reported:Array<String> = [];
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Type.getClassName(Type.getClass(error)));

		// A request's too: framed before it waits, it throws with nothing
		// left waiting, as a runtime argument the lane does not carry does.
		Assert.raises(() -> commands.note(null), ArgumentError);
		Assert.raises(() -> commands.store(null), ArgumentError);
		Assert.raises(() -> commands.shout(null), ArgumentError);
		Assert.equals(0, keeping.kept.length, "a call with a null argument was sent");
		Assert.isFalse(client.__frame != null && client.__frame.busy, "a refused call left the buffer in use");

		// An answer that cannot be null, null: the handler failing, as any
		// other answer that cannot be sent.
		var answer = commands.absent();
		Assert.equals(RPCError.INTERNAL_MESSAGE, answer.error);
		Assert.same(["absent: crossbyte.errors.ArgumentError"], reported);
		Assert.equals("still!", commands.shout("still").result);
	}

	public function testAStringIsSentAsItsUtf8WhateverItHolds():Void {
		// Natively a string held a byte a character is copied as it stands,
		// and on the jvm a short ASCII one a character at a time; every other
		// string is written character by character.
		var link = KeepingConnection.pair();
		var commands = new FrameCommands();
		var client = new RPCSession<FrameCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new FrameHandler());
		var texts = [
			"",
			"a",
			"plain ascii, with \"quotes\" and \t control \x01 characters",
			"café crème",
			"日本語",
			"\u{1F600} astral",
			StringTools.lpad("", "x", 300),
			StringTools.lpad("", "y", 300) + "é",
			"é" + StringTools.lpad("", "z", 255)
		];
		for (text in texts) {
			Assert.equals(text + "!", commands.shout(text).result, 'not answered as sent: ${text.length} characters');
		}
		Assert.same(texts.map(t -> t), (cast server.handler : FrameHandler).shouted);
	}
}

/** A linked connection that keeps what it was handed to send, and a copy of what it held then. **/
private class KeepingConnection extends LinkedConnection {
	public final kept:Array<ByteArray> = [];
	public final copies:Array<Bytes> = [];

	public static function pair():{client:LinkedConnection, server:LinkedConnection} {
		var client = new KeepingConnection();
		var server = new KeepingConnection();
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	public function new() {
		super();
	}

	/** Forgets what was sent so far: the hello a session says as it starts. **/
	public function forget():Void {
		kept.resize(0);
		copies.resize(0);
	}

	override public function send(data:ByteArray):Void {
		if (!failSends) {
			kept.push(data);
			final copy = Bytes.alloc(data.length);
			copy.blit(0, data, 0, data.length);
			copies.push(copy);
		}
		super.send(data);
	}
}

private class FrameCommands extends RPCCommands {
	public function new() {}

	@:rpc public function note(text:String):Void {}

	@:rpc public function shout(text:String):RPCResponse<String> {}

	@:rpc public function absent():RPCResponse<String> {}

	@:rpc public function store(blob:Bytes):Void {}

	@:rpc public function relay(text:String):Void {}

	@:rpc public function inner(text:String):Void {}

	@:rpc public function back(text:String):Void {}
}

private class FrameHandler extends RPCHandler {
	public final heard:Array<String> = [];
	public final shouted:Array<String> = [];
	public var stored:Int = 0;

	public function new() {}

	@:rpc public function note(text:String):Void {
		heard.push(text);
	}

	@:rpc public function shout(text:String):String {
		shouted.push(text);
		return text + "!";
	}

	// Null, which a String answer cannot be.
	@:rpc public function absent():String {
		return null;
	}

	@:rpc public function store(blob:Bytes):Void {
		stored = blob.length;
		for (i in 0...blob.length) {
			if (blob.get(i) != 7) {
				stored = -1;
				break;
			}
		}
	}

	// The server, told to relay: calls the client back from inside the send.
	@:rpc public function relay(text:String):Void {
		heard.push("relay:" + text);
		(cast session.commands : FrameCommands).back(text);
	}

	// The client, called back: calls the server again from inside its own send.
	@:rpc public function back(text:String):Void {
		heard.push("back:" + text);
		(cast session.commands : FrameCommands).inner(text);
	}

	@:rpc public function inner(text:String):Void {
		heard.push("inner:" + text);
	}
}
