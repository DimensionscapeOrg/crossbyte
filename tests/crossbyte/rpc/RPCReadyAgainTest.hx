package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import utest.Assert;

/**
	A session on a connection that takes one peer after another, as a
	listening `LocalConnection` does: its client leaves, and the next one
	lands on the same object.

	The session stayed ended once the first client left. For every client
	after it, each error answer and each answer given later was dropped,
	the second worker's refused call never heard it was refused, and the
	heartbeat stayed off.
**/
class RPCReadyAgainTest extends utest.Test {
	/**
		Pumped once so its timers are the harness runtime's: a test elsewhere
		makes a runtime of its own and exits it, and until this one pumps, a
		timer set on this thread goes to that one and never fires.
	**/
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testTheNextPeerIsAnsweredAsTheFirstWas():Void {
		var fixture = new Fixture();
		var first = fixture.connect();
		Assert.equals("A room needs a name.", first.join("").error);

		fixture.firstLeaves();
		var second = fixture.connect();

		Assert.equals(1, second.join("lobby").result);
		var refused = second.join("");
		Assert.isTrue(refused.completed, "the next peer's refused call was never answered");
		Assert.equals("A room needs a name.", refused.error);
		var later = second.later("b");
		fixture.handler.pending.get("b").complete("for the second");
		Assert.equals("for the second", later.result, "an answer given later was dropped");
	}

	public function testALastPeersAnswerDoesNotReachTheNext():Void {
		// Each numbers its calls from 1: the first's call 1, answered after it
		// has gone, would complete the second's call 1.
		var fixture = new Fixture();
		var first = fixture.connect();
		var stale = first.later("a");
		fixture.firstLeaves();
		var second = fixture.connect();
		var waiting = second.later("b");
		Assert.equals(stale.requestId, waiting.requestId);

		fixture.handler.pending.get("a").complete("for the first");

		Assert.isFalse(waiting.completed, "the next peer's call was answered with the last one's answer");
		fixture.handler.pending.get("b").complete("for the second");
		Assert.equals("for the second", waiting.result);
	}

	public function testTheHeartbeatResumesForTheNextPeer():Void {
		var fixture = new Fixture();
		fixture.server.heartbeatInterval = 1000;
		fixture.server.heartbeatTimeout = 100000;
		fixture.server.start();
		fixture.connect();
		fixture.firstLeaves();
		var next = fixture.connectConnection();
		var before = fixture.link.server.sent;

		pump(3.5);

		Assert.isTrue(fixture.link.server.sent - before >= 2, 'the heartbeat pinged the next peer ${fixture.link.server.sent - before} times in 3.5 s');
		fixture.server.stop();
	}

	private static function pump(seconds:Float):Void {
		var runtime = CrossByte.current();
		var elapsed = 0.0;
		while (elapsed < seconds) {
			runtime.pump(0.25, 0);
			elapsed += 0.25;
		}
	}
}

private class Fixture {
	public final link = LinkedConnection.pair();
	public final handler = new AgainHandler();
	public final server:RPCSession<Dynamic>;
	var clients:Array<RPCSession<AgainCommands>> = [];

	public function new() {
		server = new RPCSession(link.server, null, handler);
	}

	/** A client on the listener's current peer, or the next one. **/
	public function connect():AgainCommands {
		var commands = new AgainCommands();
		clients.push(new RPCSession<AgainCommands>(connectConnection(), commands));
		return commands;
	}

	public function connectConnection():LinkedConnection {
		if (clients.length == 0 && link.server.open) {
			return link.client;
		}
		var next = new LinkedConnection();
		link.server.takePeer(next);
		return next;
	}

	public function firstLeaves():Void {
		link.server.peerLeft();
	}
}

private class AgainCommands extends RPCCommands {
	public function new() {}

	@:rpc public function join(room:String):RPCResponse<Int> {}

	@:rpc public function later(key:String):RPCResponse<String> {}
}

private class AgainHandler extends RPCHandler {
	public final pending = new Map<String, Completer<String>>();

	public function new() {}

	@:rpc public function join(room:String):Int {
		if (room.length == 0) {
			throw new RPCError("A room needs a name.");
		}
		return 1;
	}

	@:rpc public function later(key:String):Future<String> {
		var completer = new Completer<String>();
		pending.set(key, completer);
		return completer.future;
	}
}
