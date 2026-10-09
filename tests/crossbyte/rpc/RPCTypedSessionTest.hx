package crossbyte.rpc;

import utest.Assert;

/**
	A handler that names the kind of session it serves sees that session
	typed: `session.commands` calls its client back through checked stubs,
	and `session.data` is the application's own type, with no cast and no
	call through `Dynamic`.

	Before, `session` was always `RPCSession<Dynamic, Dynamic>`, so a call
	back to the client compiled whatever it said and ran by reflection.
**/
class RPCTypedSessionTest extends utest.Test {
	public function testATypedHandlerCallsItsClientBackThroughTypedStubs():Void {
		final room = new TypedRoomHandler();
		final alice = TypedClient.join(room, "alice");
		final bob = TypedClient.join(room, "bob");

		alice.commands.say("hello");

		Assert.same([], alice.heard, "the speaker was told of its own line");
		Assert.same(["alice: hello"], bob.heard);
		Assert.equals(5, room.lastSpeakerNameLength, "session.data was not the session's String");
	}

	public function testASessionOfAnotherKindRefusesATypedHandler():Void {
		// The handler reads its session as one whose commands are
		// TypedListenerCommands: a session with other commands would hand it
		// stubs that are not there.
		final link = LinkedConnection.pair();
		final room = new TypedRoomHandler();
		var refused:Null<crossbyte.errors.ArgumentError> = null;
		try {
			// Kept in a variable: a discarded `new` whose arguments branch
			// fails the jvm's verifier.
			final taken = new RPCSession<TypedSpeakerCommands>(link.server, new TypedSpeakerCommands(), room);
			taken.close();
		} catch (error:crossbyte.errors.ArgumentError) {
			refused = error;
		}
		Assert.notNull(refused, "a session with other commands took a handler typed for TypedListenerCommands");
		if (refused != null) {
			Assert.stringContains("TypedListenerCommands", refused.message);
		}
		// Commands set later are checked as well.
		final session = new RPCSession<Dynamic, Dynamic>(link.client, null, room);
		Assert.raises(() -> session.commands = new TypedSpeakerCommands(), crossbyte.errors.ArgumentError);
		session.commands = new TypedListenerCommands();
		Assert.notNull(session.commands);
	}

	public function testAnUntypedHandlerStillServesAnySession():Void {
		final link = LinkedConnection.pair();
		final handler = new UntypedEchoHandler();
		final server = new RPCSession<TypedListenerCommands, String>(link.server, new TypedListenerCommands(), handler);
		final commands = new TypedSpeakerCommands();
		final client = new RPCSession<TypedSpeakerCommands>(link.client, commands);
		var answered:Null<Int> = null;
		commands.count("abc").then(v -> answered = v);
		Assert.equals(3, answered);
		client.close();
		server.close();
	}
}

interface TypedSpeakerContract {
	function say(text:String):Void;
	function count(text:String):Int;
}

interface TypedListenerContract {
	function said(line:String):Void;
}

@:rpcContract(TypedSpeakerContract)
private class TypedSpeakerCommands extends RPCCommands {
	public function new() {}
}

@:rpcContract(TypedListenerContract)
private class TypedListenerCommands extends RPCCommands {
	public function new() {}
}

/** One room for everyone, which tells each client what the others say. **/
private class TypedRoomHandler extends RPCHandler<TypedListenerCommands, String> implements TypedSpeakerContract {
	public final clients:Array<RPCSession<TypedListenerCommands, String>> = [];
	public var lastSpeakerNameLength:Int = 0;

	public function new() {}

	public function say(text:String):Void {
		// Typed: a String's length, and a stub the build checks.
		lastSpeakerNameLength = session.data.length;
		for (client in clients) {
			if (client != session) {
				client.commands.said(session.data + ": " + text);
			}
		}
	}

	public function count(text:String):Int {
		return text.length;
	}
}

private class UntypedEchoHandler extends RPCHandler implements TypedSpeakerContract {
	public function new() {}

	public function say(text:String):Void {}

	public function count(text:String):Int {
		return text.length;
	}
}

private class TypedListener extends RPCHandler implements TypedListenerContract {
	public final heard:Array<String> = [];

	public function new() {}

	public function said(line:String):Void {
		heard.push(line);
	}
}

private class TypedClient {
	public final commands:TypedSpeakerCommands = new TypedSpeakerCommands();
	public final heard:Array<String>;

	public static function join(room:TypedRoomHandler, name:String):TypedClient {
		return new TypedClient(room, name);
	}

	function new(room:TypedRoomHandler, name:String) {
		final link = LinkedConnection.pair();
		final server = new RPCSession<TypedListenerCommands, String>(link.server, new TypedListenerCommands(), room);
		server.data = name;
		room.clients.push(server);
		final listener = new TypedListener();
		heard = listener.heard;
		final client = new RPCSession<TypedSpeakerCommands>(link.client, commands, listener);
		client.data = name;
	}
}
