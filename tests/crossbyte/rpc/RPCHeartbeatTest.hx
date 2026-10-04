package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.Reason;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.utils.Logger;
import utest.Assert;

/**
	The session heartbeat: a ping when nothing else has gone, and the
	connection closed when nothing has come back.

	It closed healthy connections and never noticed dead ones. Pings were
	one-way and nobody answered them, so a client heartbeating a server that
	only answers calls heard nothing between calls and gave up on it. A peer
	that had never sent a byte was compared against a deadline that moved
	with the clock, and was never timed out. It ran only with commands, so a
	server, a handler and nothing else, never dropped a client that had
	vanished. Started before the connection was up it never started, started
	twice it ran twice and outlived `stop()`, and a timeout reported the
	close twice.

	Runs on the runtime's own clock, pumped: a heartbeat's seconds pass as
	fast as the pump is called.
**/
class RPCHeartbeatTest extends utest.Test {
	/**
		Pumped once so its timers are the harness runtime's: a test elsewhere
		makes a runtime of its own and exits it, and until this one pumps, a
		timer set on this thread goes to that one and never fires.
	**/
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testTheOpOfPingIsTheOneTheWireUses():Void {
		Assert.equals(RPCOps.opOf("ping"), RPCWire.PING_OP);
	}

	public function testAClientHeartbeatingAQuietServerKeepsItsConnection():Void {
		var link = LinkedConnection.pair();
		var server = new RPCSession(link.server, null, new QuietHandler());
		var commands = new QuietCommands();
		var client = new RPCSession<QuietCommands>(link.client, commands);
		var closes = closesOf(client);
		client.heartbeatInterval = 1000;
		client.heartbeatTimeout = 3000;
		client.start();

		pump(0.5);
		Assert.equals(1, commands.join("lobby").result);
		// Idle from here: only pings, and whatever answers them.
		pump(10);

		Assert.same([], closes, "a healthy connection was closed");
		Assert.isTrue(link.client.open);
		Assert.equals(2, commands.join("lobby").result);
		client.stop();
	}

	public function testAPeerThatNeverSendsIsTimedOut():Void {
		// A server session, a handler and nothing else, whose client never
		// says a word, and answers no ping: nothing is reading its end.
		var link = LinkedConnection.pair();
		var server = new RPCSession(link.server, null, new QuietHandler());
		var closes = closesOf(server);
		server.heartbeatInterval = 1000;
		server.heartbeatTimeout = 3000;
		server.start();

		pump(5);

		Assert.same(["Closed"], closes, "a vanished client was not dropped, or was dropped more than once");
		Assert.isFalse(link.server.open);
	}

	public function testATimeoutFailsTheCallsWaitingAndReportsTheCloseOnce():Void {
		var link = LinkedConnection.pair();
		// Nobody on the other end: the calls go unanswered, and so do the pings.
		var commands = new QuietCommands();
		var client = new RPCSession<QuietCommands>(link.client, commands);
		var closes = closesOf(client);
		client.heartbeatInterval = 1000;
		client.heartbeatTimeout = 3000;
		client.start();
		var waiting = commands.join("lobby");

		pump(5);

		Assert.same(["Closed"], closes);
		Assert.isTrue(waiting.completed, "a call outlived the connection");
		Assert.stringContains("timed out", waiting.error);
		Assert.isTrue(Type.enumEq(Reason.Timeout, waiting.cause), "the call's cause is not the timeout: " + waiting.cause);
	}

	public function testAHeartbeatStartedBeforeTheConnectionIsUpStartsOnceItIs():Void {
		var link = LinkedConnection.pair();
		link.client.isConnected = false;
		var server = new RPCSession(link.server, null, new QuietHandler());
		var client = new RPCSession<QuietCommands>(link.client, new QuietCommands());
		client.heartbeatInterval = 1000;
		client.heartbeatTimeout = 3000;
		Assert.isFalse(client.start(), "start() said a connection that was not up was");

		pump(3);
		Assert.equals(0, link.client.sent, "pinged a connection that was not up");

		link.client.becomeReady();
		pump(5);
		Assert.isTrue(link.client.sent >= 4, 'sent ${link.client.sent} pings in 5 s once up, at 1 a second');
		client.stop();
	}

	public function testStartingTwiceRunsOneHeartbeatAndStopEndsIt():Void {
		var link = LinkedConnection.pair();
		var server = new RPCSession(link.server, null, new QuietHandler());
		var client = new RPCSession<QuietCommands>(link.client, new QuietCommands());
		client.heartbeatInterval = 1000;
		client.heartbeatTimeout = 100000;
		client.start();
		client.start();
		pump(5);

		client.stop();
		var before = link.client.sent;
		pump(5);

		Assert.equals(before, link.client.sent, 'pinged ${link.client.sent - before} times after stop()');
	}

	public function testAHeartbeatNeverThrowsOutOfTheTickOnceItsConnectionHasClosed():Void {
		var link = LinkedConnection.pair();
		link.client.strictSend = true;
		var server = new RPCSession(link.server, null, new QuietHandler());
		var client = new RPCSession<QuietCommands>(link.client, new QuietCommands());
		var closes = closesOf(client);
		client.heartbeatInterval = 1000;
		client.heartbeatTimeout = 3000;
		client.start();
		client.start();
		pump(0.5);

		link.client.close();
		var escaped:Array<String> = [];
		var runtime = CrossByte.current();
		for (_ in 0...40) {
			try {
				runtime.pump(0.25, 0);
			} catch (error:Dynamic) {
				escaped.push(Std.string(error));
			}
		}

		Assert.same([], escaped, "a heartbeat threw out of the tick");
		Assert.same(["Closed"], closes);
	}

	public function testEverySessionAnswersAPing():Void {
		// A handler, commands, a runtime handler, or nothing but a heartbeat
		// of its own: each answers.
		for (kind in ["handler", "commands", "runtime", "started"]) {
			var link = LinkedConnection.pair();
			var session:RPCSession<Dynamic, Dynamic> = null;
			switch (kind) {
				case "handler":
					session = cast new RPCSession(link.server, null, new QuietHandler());
				case "commands":
					session = cast new RPCSession<QuietCommands>(link.server, new QuietCommands());
				case "runtime":
					session = cast new RPCSession(link.server);
					session.register(900, args -> null);
				default:
					session = cast new RPCSession(link.server);
			}
			if (kind == "started") {
				session.heartbeatInterval = 100000;
				session.start();
			}
			var answers = framesArrivingAt(link.client);

			link.client.send(pingFrame());

			Assert.equals(1, answers.length, '$kind: answered ${answers.length} times');
			if (answers.length == 1) {
				var pong = answers[0];
				pong.readInt();
				Assert.equals(RPCWire.FLAG_RESPONSE, pong.readByte(), '$kind: not a response');
				Assert.equals(RPCWire.PING_OP, pong.readInt(), '$kind: not for ping');
				Assert.equals(0, pong.readVarUInt(), '$kind: answers a call');
			}
			session.stop();
		}
	}

	public function testAPingIsNotACallAndNoLimitOnCallsRefusesIt():Void {
		// A handler refusing every call, a rate limit run out, still
		// answers the heartbeat: refusing it closed the connection, and
		// counting it spent the client's allowance on pings.
		var link = LinkedConnection.pair();
		var handler = new RefusingHandler();
		var server = new RPCSession(link.server, null, handler);
		var answers = framesArrivingAt(link.client);

		link.client.send(pingFrame());

		Assert.equals(1, answers.length, "a ping went unanswered");
		Assert.same([], handler.asked, "beforeCall was asked about a ping");
		Assert.equals(1, handler.pinged, "the handler's ping was not told");
	}

	public function testAPingGoesOnEveryBeatWhateverTheClockRoundsTo():Void {
		// The beat after a ping is an interval after it, which the clock's
		// rounding put a hair short, 2.8 - 1.8 is 0.99999999999999978, and
		// the ping waited for the next beat: a ping every other beat, and a
		// peer's pongs heard twice the interval apart.
		var link = LinkedConnection.pair();
		var client = new RPCSession<QuietCommands>(link.client, new QuietCommands());
		client.heartbeatInterval = 1000;
		client.heartbeatTimeout = 1000000;
		client.start();
		var runtime = CrossByte.current();
		// A tenth of a second at a time, which no binary fraction is.
		for (_ in 0...10) {
			runtime.pump(0.1, 0);
		}
		var before = link.client.sent;
		for (_ in 0...300) {
			runtime.pump(0.1, 0);
		}
		var pings = link.client.sent - before;
		client.stop();

		Assert.isTrue(pings >= 29, 'pinged $pings times in 30 beats');
	}

	public function testAHeartbeatLogsNothing():Void {
		// It logged five lines at INFO for every session on every beat.
		var logged:Array<String> = [];
		var sink = Logger.sink;
		Logger.sink = line -> logged.push(line);
		try {
			var link = LinkedConnection.pair();
			var server = new RPCSession(link.server, null, new QuietHandler());
			var client = new RPCSession<QuietCommands>(link.client, new QuietCommands());
			client.heartbeatInterval = 1000;
			client.heartbeatTimeout = 3000;
			client.start();
			pump(4);
			client.stop();
		} catch (error:Dynamic) {
			Logger.sink = sink;
			throw error;
		}
		Logger.sink = sink;

		Assert.same([], logged);
	}

	// ------------------------------------------------------------------

	private static function pump(seconds:Float):Void {
		var runtime = CrossByte.current();
		var elapsed = 0.0;
		while (elapsed < seconds) {
			runtime.pump(0.25, 0);
			elapsed += 0.25;
		}
	}

	/** What the application's `onClose` is told, set after the session, as an application would. **/
	private static function closesOf(session:RPCSession<Dynamic, Dynamic>):Array<String> {
		var closes:Array<String> = [];
		session.connection.onClose = reason -> closes.push(Std.string(reason));
		return closes;
	}

	/** Each frame `connection` is sent from now on, whole. **/
	private static function framesArrivingAt(connection:LinkedConnection):Array<ByteArrayInput> {
		var frames:Array<ByteArrayInput> = [];
		connection.readEnabled = true;
		connection.onData = input -> {
			var copy = new ByteArray();
			copy.writeBytes(cast input, input.position, input.bytesAvailable);
			copy.position = 0;
			frames.push(copy);
		};
		return frames;
	}

	private static function pingFrame():ByteArray {
		var frame = new ByteArray();
		frame.writeInt(RPCWire.MIN_PAYLOAD_LEN);
		frame.writeByte(0);
		frame.writeInt(RPCWire.PING_OP);
		frame.position = 0;
		return frame;
	}
}

private class QuietCommands extends RPCCommands {
	public function new() {}

	@:rpc public function join(room:String):RPCResponse<Int> {}
}

private class QuietHandler extends RPCHandler {
	var joined:Int = 0;

	public function new() {}

	@:rpc public function join(room:String):Int {
		return ++joined;
	}
}

private class RefusingHandler extends RPCHandler {
	public final asked:Array<String> = [];
	public var pinged:Int = 0;

	public function new() {}

	@:rpc public function join(room:String):Int {
		return 1;
	}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		asked.push(method);
		return new RPCError("Slow down.");
	}

	public function ping():Void {
		pinged++;
	}
}
