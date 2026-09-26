package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.utils.Hash;
import haxe.io.Bytes;
import utest.Assert;

/**
	One handler serving many sessions, as a server with one room, one queue
	or one world gives the same handler to every client it accepts.

	A handler held the one session it was given last. Given to a second
	session, it answered every call on that session's connection: one
	client's answer went to another, and since each client numbers its calls
	from 1, it completed whichever call of theirs had the same number --
	Bob, asking for a `String`, was answered with Alice's `Int`. Responses
	were matched by id and never by op, so nothing on Bob's side noticed.
**/
@:access(crossbyte.rpc.RPCSession)
class RPCSharedHandlerTest extends utest.Test {
	public function testOneHandlerAnswersEachSessionOnItsOwnConnection():Void {
		var room = new SharedRoomHandler();
		var alice = Client.of(room, "alice");
		var bob = Client.of(room, "bob");

		var aliceJoined = alice.commands.join("lobby");
		Assert.isTrue(aliceJoined.completed, "Alice's call was answered somewhere else");
		Assert.equals(1, aliceJoined.result);

		var bobJoined = bob.commands.join("lobby");
		Assert.equals(2, bobJoined.result, "the handler's state was not shared");

		// Alice again, after Bob: the handler is not left on the last caller.
		Assert.equals(3, alice.commands.join("lobby").result);
	}

	public function testAHandlerSeesWhichSessionIsCalling():Void {
		var room = new SharedRoomHandler();
		var alice = Client.of(room, "alice");
		var bob = Client.of(room, "bob");

		Assert.equals("alice", alice.commands.whoAmI().result);
		Assert.equals("bob", bob.commands.whoAmI().result);
		Assert.equals("alice", alice.commands.whoAmI().result);
		Assert.isNull(room.session, "a session was left on the handler between calls");
	}

	public function testAnAnswerLaterGoesToTheSessionThatAsked():Void {
		// The guide's match queue: four players queue on one handler, and the
		// fourth completes everyone's future at once, while its own call runs.
		// Every answer went to whichever session the handler was given last.
		var queue = new SharedQueueHandler();
		var players = [for (i in 0...4) Client.of(queue, 'player$i')];
		var answers = [for (player in players) player.commands.queue(player.name)];

		for (i in 0...4) {
			Assert.isTrue(answers[i].completed, 'player $i was never answered');
			Assert.equals(1, answers[i].result, 'player $i was answered ${answers[i].result}');
		}
		for (player in players) {
			Assert.equals(0, player.server.callsWaiting);
		}
	}

	public function testACallMadeFromInsideAnotherLeavesTheHandlerOnItsCaller():Void {
		// Over a connection that delivers at once, a method running for Alice
		// can set off a call from Bob to the same handler before it returns.
		// The handler must still be Alice's when it does return.
		var room = new SharedRoomHandler();
		var alice = Client.of(room, "alice");
		var bob = Client.of(room, "bob");
		// Bob's client answers the room's notice by telling the room it saw it.
		bob.client.handler = new NoticeHandler(bob.commands);
		room.noticeTo = bob.server;

		var relayed = alice.commands.relay("hello");

		Assert.equals("relayed by alice", relayed.result, "Alice's answer went elsewhere");
		Assert.same(["bob saw hello"], room.acks);
		Assert.isNull(room.session);
	}

	public function testAResponseForAnotherOpAnswersNoCall():Void {
		// Bob is waiting on call 1, `secretName`, a String; an answer to call 1
		// for `balance`, an Int, arrives. It completed Bob's call with the Int.
		var link = LinkedConnection.pair();
		var commands = new LobbyCommands();
		var session = new RPCSession<LobbyCommands>(link.client, commands);
		var waiting = commands.secretName();

		link.server.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RESPONSE);
			out.writeInt(opOf("balance"));
			out.writeVarUInt(waiting.requestId);
			out.writeInt(12345);
		}));

		Assert.isFalse(waiting.succeeded, "a call was answered with another call's answer: " + waiting.result);
		Assert.isTrue(waiting.completed, "the call was left waiting for an answer that has been spent");
		Assert.stringContains("does not answer", waiting.error);
		Assert.isTrue(session.connection.connected);
	}

	public function testAnErrorForAnotherOpAnswersNoCall():Void {
		var link = LinkedConnection.pair();
		var commands = new LobbyCommands();
		var session = new RPCSession<LobbyCommands>(link.client, commands);
		var waiting = commands.secretName();

		link.server.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR);
			out.writeInt(opOf("balance"));
			out.writeVarUInt(waiting.requestId);
			out.writeVarUTF("No balance.");
		}));

		Assert.isTrue(waiting.completed);
		Assert.stringContains("does not answer", waiting.error);
		Assert.isFalse(Std.isOfType(waiting.cause, RPCError), "another call's refusal became this one's");
	}

	public function testARuntimeResponseForAnotherOpAnswersNoCall():Void {
		var link = LinkedConnection.pair();
		var session = new RPCSession(link.client);
		var waiting:RPCResponse<Dynamic> = session.request(700, []);

		link.server.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE);
			out.writeInt(701);
			out.writeVarUInt(waiting.requestId);
			out.writeByte(crossbyte.rpc._internal.RPCRuntimeCodec.TAG_INT);
			out.writeInt(12345);
		}));

		Assert.isFalse(waiting.succeeded, "a runtime call was answered with another op's answer: " + waiting.result);
		Assert.stringContains("does not answer", waiting.error);
	}

	/** One frame: its length, then what `write` puts in it. **/
	private static function frameOf(write:ByteArrayOutput->Void):ByteArray {
		var payload = new ByteArrayOutput(64);
		write(payload);
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}

	private static inline function opOf(method:String):Int {
		return Hash.fnv1a32(Bytes.ofString(method));
	}
}

/** A client of a shared handler: its connection, its session and the server's session for it. **/
private class Client {
	public final name:String;
	public final commands:RoomCommands;
	public final client:RPCSession<RoomCommands, Dynamic>;
	public final server:RPCSession<NoticeCommands, String>;

	public static function of(handler:RPCHandler, name:String):Client {
		return new Client(handler, name);
	}

	function new(handler:RPCHandler, name:String) {
		this.name = name;
		var link = LinkedConnection.pair();
		server = new RPCSession<NoticeCommands, String>(link.server, new NoticeCommands(), handler);
		server.data = name;
		commands = new RoomCommands();
		client = new RPCSession<RoomCommands, Dynamic>(link.client, commands);
	}
}

private class RoomCommands extends RPCCommands {
	public function new() {}

	@:rpc public function join(room:String):RPCResponse<Int> {}

	@:rpc public function whoAmI():RPCResponse<String> {}

	@:rpc public function relay(text:String):RPCResponse<String> {}

	@:rpc public function ack(text:String):Void {}

	@:rpc public function queue(player:String):RPCResponse<Int> {}
}

/** Shared state, as the guide's ChatHandler keeps it: one count per room, for everyone. **/
private class SharedRoomHandler extends RPCHandler {
	public var members = new Map<String, Int>();
	public var acks:Array<String> = [];
	public var noticeTo:RPCSession<NoticeCommands, String>;

	public function new() {}

	@:rpc public function join(room:String):Int {
		final count = (members.exists(room) ? members.get(room) : 0) + 1;
		members.set(room, count);
		return count;
	}

	@:rpc public function whoAmI():String {
		return cast session.data;
	}

	@:rpc public function relay(text:String):String {
		// Bob's client answers this notice with a call to this handler, which
		// runs before this method returns.
		noticeTo.commands.notice(text);
		return "relayed by " + session.data;
	}

	@:rpc public function ack(text:String):Void {
		acks.push(session.data + " saw " + text);
	}
}

/** The guide's match queue: four players queued are one match. **/
private class SharedQueueHandler extends RPCHandler {
	var queued:Array<Completer<Int>> = [];
	var nextMatch:Int = 1;

	public function new() {}

	@:rpc public function queue(player:String):Future<Int> {
		final place = new Completer<Int>();
		queued.push(place);
		if (queued.length == 4) {
			final match = nextMatch++;
			for (waiting in queued) {
				waiting.complete(match);
			}
			queued = [];
		}
		return place.future;
	}
}

/** The server's calls to a client. **/
private class NoticeCommands extends RPCCommands {
	public function new() {}

	@:rpc public function notice(text:String):Void {}
}

/** A client that answers a notice by telling the room it saw it. **/
private class NoticeHandler extends RPCHandler {
	final room:RoomCommands;

	public function new(room:RoomCommands) {
		this.room = room;
	}

	@:rpc public function notice(text:String):Void {
		room.ack(text);
	}
}

private class LobbyCommands extends RPCCommands {
	public function new() {}

	@:rpc public function secretName():RPCResponse<String> {}

	@:rpc public function balance():RPCResponse<Int> {}
}
