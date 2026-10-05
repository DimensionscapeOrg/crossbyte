package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.net._internal.reliable.ResetBudget;
import crossbyte.test.Require;
import utest.Assert;

/**
	A session that follows its player to a new address
	(`ReliableDatagramServerSocket.allowRebind`): through a NAT, written for
	the tests, that moves the client to a new outside port while messages
	cross both ways, and through REBINDs written by hand for each refusal.
**/
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramRebindTest extends utest.Test {
	public function setup():Void {
		ResetBudget.refill();
	}

	/**
		The NAT gives the client a new port mid-stream. The server's reset
		to the new port carries a challenge, the client answers, and the
		session moves: every message both ways arrives once and in order, on
		the same session object, filed only under the new port.
	**/
	public function testASessionFollowsItsPlayerToANewPort():Void {
		if (!requireRebindSupport()) return;
		var pair = Pair.open(true);
		if (pair == null) {
			Assert.fail("the pair never connected");
			return;
		}

		try {
			var oldPort:Int = pair.nat.outsidePort;
			Assert.equals(oldPort, pair.session.remotePort);
			Assert.notNull(pair.client.__rebindKey, "the client was given no rebind key");
			Assert.notNull(pair.server.__byConnectionId.get(pair.session.__peerConnectionId), "the session was not filed by its connection id");

			pair.exchange(0, 20);
			pair.nat.remap();
			var newPort:Int = pair.nat.outsidePort;
			pair.exchange(20, 60);
			pair.waitForAll(60, 10.0);

			Assert.same(Pair.expected("c", 60), pair.serverGot, "the server's messages from the client, once each and in order");
			Assert.same(Pair.expected("s", 60), pair.clientGot, "the client's messages from the server, once each and in order");
			Assert.equals(1, pair.accepted.length, "the server announced another session");
			Assert.isTrue(pair.client.connected && pair.session.connected, "the session did not survive the move");
			Assert.equals(newPort, pair.session.remotePort, "the session is not at the new port");
			Assert.isTrue(pair.session == pair.server.__sessionAt("127.0.0.1", newPort), "the new port does not find the same session");
			Assert.isNull(pair.server.__sessionAt("127.0.0.1", oldPort), "the old port still finds it");
			Assert.isTrue(pair.server.__connections.exists("127.0.0.1:" + newPort) && !pair.server.__connections.exists("127.0.0.1:" + oldPort),
				"the endpoint keys were not moved");
			Assert.equals(1, pair.server.__byHostCount.get("127.0.0.1"), "the host's count was not kept");
			Assert.equals(-1, pair.client.__rebindingSince, "the client still thinks it is rebinding");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		pair.close();
	}

	/**
		What each side sent while the other could not be reached goes again
		as soon as the session has moved, all of it: two messages each way,
		sent together just after the NAT moved the client and nothing sent
		after them, arrive a round trip after the move, well inside a
		retransmission timeout, the least of which is 200 ms.
	**/
	public function testWhatWasLostDuringTheMoveIsSentAgainAtOnce():Void {
		if (!requireRebindSupport()) return;
		var pair = Pair.open(true);
		if (pair == null) {
			Assert.fail("the pair never connected");
			return;
		}

		try {
			// Mid-stream, so the last messages before the move are delivered
			// and their acknowledgements still held, as a game's are.
			pair.exchange(0, 5);
			pair.nat.remap();
			for (i in 5...7) {
				pair.client.send(Pair.text("c" + i));
				pair.session.send(Pair.text("s" + i));
			}
			// With the timers held still: nothing may wait for a probe or a
			// retransmission timeout, only for the move itself.
			var deadline:Float = haxe.Timer.stamp() + 2.0;
			while (!(pair.serverGot.length >= 7 && pair.clientGot.length >= 7) && haxe.Timer.stamp() < deadline) {
				CrossByte.current().pump(0, 0);
				crossbyte.sys.System.sleep(0.001);
			}
			var took:Float = haxe.Timer.stamp() - pair.nat.firstOutAt;
			Assert.same(Pair.expected("c", 7), pair.serverGot);
			Assert.same(Pair.expected("s", 7), pair.clientGot);
			Assert.isTrue(took < 0.15, 'what was sent during the move took $took s to arrive after the first datagram from the new port');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		pair.close();
	}

	/** With rebinding off, a new port is a stranger: reset, and the client closes, as it always did. **/
	public function testWithoutRebindTheResetEndsTheSessionAsBefore():Void {
		var pair = Pair.open(false);
		if (pair == null) {
			if (ReliableDatagramSocket.isSupported) {
				Assert.fail("the pair never connected");
			}
			return;
		}

		try {
			Assert.isNull(pair.client.__rebindKey, "a server not allowing rebinds gave a key");
			Assert.isNull(pair.server.__byConnectionId, "a server not allowing rebinds kept a map for them");
			pair.exchange(0, 5);
			pair.waitForAll(5, 5.0);
			pair.nat.remap();
			pair.client.send(Pair.text("after"));
			pumpUntil(() -> pair.clientClosed, 5.0);
			Assert.isTrue(pair.clientClosed, "the client was not reset");
			Assert.isNull(pair.clientError, "the reset was reported as an error: " + pair.clientError);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		pair.close();
	}

	/**
		Every REBIND the server must refuse leaves the session where it was:
		a wrong proof, a challenge made for another address, one past its
		time, a session closing; and one from the address the session is at
		already moves nothing and is answered.
	**/
	public function testEachRefusedRebindLeavesTheSessionWhereItWas():Void {
		if (!requireRebindSupport()) return;
		var pair = Pair.open(true);
		if (pair == null) {
			Assert.fail("the pair never connected");
			return;
		}
		var peers:Array<Rebinder> = [];
		function peer():Rebinder {
			var made = new Rebinder(pair.server.localPort, pair.session.__peerConnectionId);
			peers.push(made);
			return made;
		}

		try {
			var session = pair.session;
			var home:Int = session.remotePort;
			function stays(why:String):Void {
				Assert.equals(home, session.remotePort, why);
				Assert.isTrue(session == pair.server.__sessionAt("127.0.0.1", home), why);
			}

			// A wrong proof.
			var wrong = peer();
			var challenge = wrong.challenge();
			Assert.notEquals(0, challenge, "a reset to a stranger carried no challenge");
			proof(session, challenge);
			wrong.rebind(challenge, session.__proofHigh, session.__proofLow ^ 1);
			pumpUntil(() -> false, 0.2);
			stays("a wrong proof moved the session");
			Assert.equals(0, wrong.rebounds, "a wrong proof was answered");

			// A challenge made for another address, with the right proof.
			var elsewhere = peer();
			var theirs = peer().challenge();
			proof(session, theirs);
			elsewhere.fins = [];
			elsewhere.rebind(theirs, session.__proofHigh, session.__proofLow);
			pumpUntil(() -> elsewhere.fins.length > 0, 1.0);
			stays("a challenge from another address moved the session");
			Assert.equals(1, elsewhere.fins.length, "a challenge from elsewhere was not answered with a fresh one");
			if (elsewhere.fins.length > 0) {
				Assert.isTrue(elsewhere.fins[0] != 0 && elsewhere.fins[0] != theirs, "the answer carried no fresh challenge");
			}

			// A challenge past its time.
			pair.server.__pathKeyPeriod = 0.2;
			var late = peer();
			var old = late.challenge();
			pumpUntil(() -> false, 0.5);
			proof(session, old);
			late.fins = [];
			late.rebind(old, session.__proofHigh, session.__proofLow);
			pumpUntil(() -> late.fins.length > 0, 1.0);
			stays("an expired challenge moved the session");
			Assert.equals(1, late.fins.length, "an expired challenge was not answered with a fresh one");
			pair.server.__pathKeyPeriod = 10.0;

			// From where it is already: answered, and nothing moves.
			var before:Float = session.__reboundAt;
			var here = pair.server.__challengeFor("127.0.0.1", home);
			proof(session, here);
			var rebind = Rebinder.frame(session.__peerConnectionId, here, session.__proofHigh, session.__proofLow);
			var sentBefore:Int = pair.nat.forwardedIn;
			pair.server.__receiveDatagram(rebind, "127.0.0.1", home);
			pumpUntil(() -> pair.nat.forwardedIn > sentBefore, 1.0);
			stays("a REBIND from where the session is moved it");
			Assert.equals(before, session.__reboundAt, "a REBIND from where the session is counted as a move");
			Assert.isTrue(pair.nat.forwardedIn > sentBefore, "a REBIND from where the session is was not answered");

			// The right one, from somewhere new: moved, and answered there.
			var good = peer();
			var fresh = good.challenge();
			proof(session, fresh);
			good.rebind(fresh, session.__proofHigh, session.__proofLow);
			pumpUntil(() -> good.rebounds > 0, 1.0);
			Assert.equals(good.port, session.remotePort, "a right REBIND did not move the session");
			Assert.equals(1, good.rebounds, "the move was not answered");

			// A session closing is moved nowhere, and the sender is told it
			// has none with a reset that carries no challenge.
			session.close();
			Assert.isTrue(session.__closing || session.__closed);
			var closing = peer();
			var last = closing.challenge();
			proof(session, last);
			closing.fins = [];
			closing.rebind(last, session.__proofHigh, session.__proofLow);
			pumpUntil(() -> closing.fins.length > 0, 1.0);
			Assert.notEquals(closing.port, session.remotePort, "a closing session was moved");
			Assert.same([0], closing.fins, "a REBIND for a closing session was not told there is none");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		for (made in peers) {
			made.close();
		}
		pair.close();
	}

	/** Lossy both ways, before, during and after the move: still everything once, in order. **/
	@:timeout(60000)
	public function testARebindUnderLossDeliversEverythingOnceInOrder():Void {
		if (!requireRebindSupport()) return;
		var pair = Pair.open(true);
		if (pair == null) {
			Assert.fail("the pair never connected");
			return;
		}

		try {
			pair.nat.loss = 0.15;
			pair.exchange(0, 30);
			pair.nat.remap();
			pair.exchange(30, 80);
			pair.waitForAll(80, 30.0);
			Assert.same(Pair.expected("c", 80), pair.serverGot);
			Assert.same(Pair.expected("s", 80), pair.clientGot);
			Assert.equals(pair.nat.outsidePort, pair.session.remotePort, "the session did not follow the client");
			Assert.equals(1, pair.accepted.length);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		pair.close();
	}

	/** A server that validates every join still lets the session it opened follow its player. **/
	public function testARebindWithJoinCookiesInForce():Void {
		if (!requireRebindSupport()) return;
		var pair = Pair.open(true, ALWAYS);
		if (pair == null) {
			Assert.fail("the pair never connected through its cookie");
			return;
		}

		try {
			pair.exchange(0, 10);
			pair.nat.remap();
			pair.exchange(10, 30);
			pair.waitForAll(30, 10.0);
			Assert.same(Pair.expected("c", 30), pair.serverGot);
			Assert.same(Pair.expected("s", 30), pair.clientGot);
			Assert.equals(pair.nat.outsidePort, pair.session.remotePort);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		pair.close();
	}

	/**
		A storm of REBINDs in one pass: from a thousand addresses with right
		challenges and proofs, the session moves once and no more than 16 are
		checked; with wrong proofs, none moves it; naming no session, none is
		checked at all.
	**/
	public function testARebindStormStaysWithinItsLimits():Void {
		if (!requireRebindSupport()) return;
		var pair = Pair.open(true);
		if (pair == null) {
			Assert.fail("the pair never connected");
			return;
		}

		try {
			var server = pair.server;
			var session = pair.session;
			var id:Int = session.__peerConnectionId;
			var frames:Array<ByteArray> = [];
			for (i in 0...1000) {
				var address = "127.0.0." + (2 + i % 200);
				var port = 30000 + i;
				var challenge = server.__challengeFor(address, port);
				proof(session, challenge);
				frames.push(Rebinder.frame(id, challenge, session.__proofHigh, session.__proofLow));
			}
			// All within one pass: nothing pumps between them.
			for (i in 0...1000) {
				server.__receiveDatagram(frames[i], "127.0.0." + (2 + i % 200), 30000 + i);
			}
			Assert.equals(ReliableDatagramServerSocket.MAX_REBIND_CHECKS_PER_PASS, server.__rebindChecks, "more REBINDs were checked in a pass than allowed");
			Assert.equals(30000, session.remotePort, "the session did not move to the first right REBIND, or moved again");
			Assert.equals("127.0.0.2", session.remoteAddress);

			// The next pass: wrong proofs, from elsewhere again.
			CrossByte.current().pump(0, 0);
			Assert.equals(0, server.__rebindChecks, "the count did not start again with the pass");
			session.__reboundAt = -1;
			for (i in 0...1000) {
				var address = "127.0.1." + (2 + i % 200);
				var port = 40000 + i;
				var challenge = server.__challengeFor(address, port);
				server.__receiveDatagram(Rebinder.frame(id, challenge, i, i), address, port);
			}
			Assert.equals(ReliableDatagramServerSocket.MAX_REBIND_CHECKS_PER_PASS, server.__rebindChecks);
			Assert.equals(30000, session.remotePort, "a wrong proof moved the session");

			// Naming no session: nothing to check.
			CrossByte.current().pump(0, 0);
			for (i in 0...1000) {
				server.__receiveDatagram(Rebinder.frame(id ^ (i + 1), 1, i, i), "127.0.2." + (2 + i % 200), 40000 + i);
			}
			Assert.equals(0, server.__rebindChecks, "REBINDs naming no session were checked");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		pair.close();
	}

	/**
		The client's REBINDs never reach the server: it closes within its
		`timeout`, with an `ioError` that names the failed rebind.
	**/
	public function testAClientWhoseRebindIsNeverTakenClosesSayingSo():Void {
		if (!requireRebindSupport()) return;
		var pair = Pair.open(true);
		if (pair == null) {
			Assert.fail("the pair never connected");
			return;
		}

		try {
			pair.client.timeout = 1000;
			pair.nat.dropOut = data -> {
				var frame = ReliableDatagramProtocol.decode(data);
				return frame != null && frame.type == PATH;
			};
			pair.nat.remap();
			var started:Float = haxe.Timer.stamp();
			pair.client.send(Pair.text("into the void"));
			pumpUntil(() -> pair.clientClosed, 5.0);
			var took:Float = haxe.Timer.stamp() - started;
			Assert.isTrue(pair.clientClosed, "the client never gave up its rebind");
			Assert.isTrue(took >= 0.9 && took < 3.0, 'the client gave up after $took s, where its timeout was 1 s');
			Assert.isTrue(pair.clientError != null && pair.clientError.indexOf("rebind") >= 0, "the error did not name the rebind: " + pair.clientError);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		pair.close();
	}

	// ------------------------------------------------------------- helpers

	/** The proof a REBIND for `challenge` carries, from the session's key, into its `__proofHigh` and `__proofLow`. **/
	private static function proof(session:ReliableDatagramSocket, challenge:Int):Void {
		session.__proofFor(session.__peerConnectionId, challenge);
	}

	/**
		Whether a rebind can be offered here: not without a secure random
		source (neko, HashLink), where a server allowing rebinds gives no key
		and the client is reset as before, which is checked instead.
	**/
	private static function requireRebindSupport():Bool {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return false;
		}
		if (crossbyte.crypto.SecureRandom.isSupported) {
			return true;
		}
		var pair = Pair.open(true);
		if (pair == null) {
			Assert.fail("the pair never connected");
			return false;
		}
		Assert.isNull(pair.client.__rebindKey, "a key was given with no secure random source");
		pair.nat.remap();
		pair.client.send(Pair.text("after"));
		pumpUntil(() -> pair.clientClosed, 5.0);
		Assert.isTrue(pair.clientClosed, "with no key, the client was not reset as before");
		pair.close();
		return false;
	}

	public static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		var last = haxe.Timer.stamp();
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			crossbyte.sys.System.sleep(0.001);
		}
	}
}

/** A server, a NAT, and a client connected through it, each message each way kept. **/
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
private class Pair {
	public var server:ReliableDatagramServerSocket;
	public var nat:NatRelay;
	public var client:ReliableDatagramSocket;
	public var session:ReliableDatagramSocket;
	public var accepted:Array<ReliableDatagramSocket> = [];
	public var serverGot:Array<String> = [];
	public var clientGot:Array<String> = [];
	public var clientClosed:Bool = false;
	public var clientError:String = null;

	public function new() {}

	public static function open(allowRebind:Bool, ?validation:JoinValidation):Null<Pair> {
		if (!ReliableDatagramSocket.isSupported) {
			return null;
		}
		var pair = new Pair();
		pair.server = new ReliableDatagramServerSocket();
		pair.server.bind(0, "127.0.0.1");
		pair.server.allowRebind = allowRebind;
		if (validation != null) {
			pair.server.joinValidation = validation;
		}
		pair.server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
			pair.accepted.push(e.socket);
			e.socket.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent):Void {
				pair.serverGot.push(d.data.readUTFBytes(d.data.length));
			});
		});
		pair.server.listen();
		pair.nat = new NatRelay(pair.server.localPort);
		pair.client = new ReliableDatagramSocket();
		pair.client.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent):Void {
			pair.clientGot.push(d.data.readUTFBytes(d.data.length));
		});
		pair.client.addEventListener(Event.CLOSE, _ -> pair.clientClosed = true);
		pair.client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> pair.clientError = e.text);
		pair.client.connect("127.0.0.1", pair.nat.port);
		ReliableDatagramRebindTest.pumpUntil(() -> pair.client.connected && pair.accepted.length > 0 && pair.accepted[0].connected, 5.0);
		if (!pair.client.connected || pair.accepted.length == 0) {
			pair.close();
			return null;
		}
		pair.session = pair.accepted[0];
		return pair;
	}

	/** Messages `from` to `to`, one each way a pass, a millisecond or so apart. **/
	public function exchange(from:Int, to:Int):Void {
		for (i in from...to) {
			if (client.connected) {
				client.send(text("c" + i));
			}
			if (session.connected) {
				session.send(text("s" + i));
			}
			ReliableDatagramRebindTest.pumpUntil(() -> false, 0.005);
		}
	}

	public function waitForAll(count:Int, timeout:Float):Void {
		ReliableDatagramRebindTest.pumpUntil(() -> serverGot.length >= count && clientGot.length >= count, timeout);
		// And a moment for anything sent twice to show up twice.
		ReliableDatagramRebindTest.pumpUntil(() -> false, 0.1);
	}

	public static function expected(prefix:String, count:Int):Array<String> {
		return [for (i in 0...count) prefix + i];
	}

	public static function text(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	public function close():Void {
		try if (client != null) client.abort() catch (_:Dynamic) {}
		try if (server != null) server.close() catch (_:Dynamic) {}
		if (nat != null) {
			nat.close();
		}
	}
}

/**
	A peer written by hand, at an address of its own, for one session's
	REBINDs: it draws a reset to learn the challenge for its address, and
	keeps every reset's challenge and how many REBOUNDs came.
**/
private class Rebinder {
	public var socket:DatagramSocket;
	public var port(get, never):Int;
	public var fins:Array<Int> = [];
	public var rebounds:Int = 0;

	var serverPort:Int;
	var id:Int;

	public function new(serverPort:Int, id:Int) {
		this.serverPort = serverPort;
		this.id = id;
		socket = new DatagramSocket();
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var frame = ReliableDatagramProtocol.decode(e.data);
			if (frame == null) {
				return;
			}
			if (frame.type == FIN) {
				fins.push(frame.sequence);
			} else if (frame.type == PATH && (frame.payload : haxe.io.Bytes).get(0) == ReliableDatagramProtocol.PATH_REBOUND) {
				rebounds++;
			}
		});
		socket.receive();
	}

	/** Sends a frame as a session's, draws the reset, and says the challenge it carried. **/
	public function challenge():Int {
		var count:Int = fins.length;
		var packet = ReliableDatagramProtocol.encode(PACKET, 1, ReliableDatagramRebindTestText.of("x"), false, 1);
		socket.send(packet, 0, packet.length, "127.0.0.1", serverPort);
		ReliableDatagramRebindTest.pumpUntil(() -> fins.length > count, 2.0);
		return fins.length > count ? fins[fins.length - 1] : 0;
	}

	public function rebind(challenge:Int, high:Int, low:Int):Void {
		var frame = Rebinder.frame(id, challenge, high, low);
		socket.send(frame, 0, frame.length, "127.0.0.1", serverPort);
	}

	public static function frame(id:Int, challenge:Int, high:Int, low:Int):ByteArray {
		var body = new ByteArray();
		body.length = 1 + ReliableDatagramProtocol.CHALLENGE_SIZE + ReliableDatagramProtocol.REBIND_PROOF_SIZE;
		var bytes:haxe.io.Bytes = body;
		bytes.set(0, ReliableDatagramProtocol.PATH_REBIND);
		setInt(bytes, 1, challenge);
		setInt(bytes, 5, high);
		setInt(bytes, 9, low);
		return ReliableDatagramProtocol.encode(PATH, id, body);
	}

	static function setInt(bytes:haxe.io.Bytes, at:Int, value:Int):Void {
		bytes.set(at, value >>> 24);
		bytes.set(at + 1, (value >>> 16) & 0xFF);
		bytes.set(at + 2, (value >>> 8) & 0xFF);
		bytes.set(at + 3, value & 0xFF);
	}

	public function close():Void {
		try socket.close() catch (_:Dynamic) {}
	}

	function get_port():Int {
		return socket.localPort;
	}
}

private class ReliableDatagramRebindTestText {
	public static function of(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}
}

/**
	A NAT, for the tests: what a client sends to `port` goes on to the
	server from one outside port, and what comes back to that port goes back
	to the client; `remap()` moves the client to a new outside port, as a NAT
	that drops a mapping and makes another does, after which what comes back
	to the old one is dropped. It can lose a share of what crosses, each way,
	from a fixed sequence, and drop by what a datagram is.
**/
private class NatRelay {
	public var port(get, never):Int;
	public var outsidePort(get, never):Int;
	public var loss:Float = 0;
	public var dropOut:Null<ByteArray->Bool> = null;
	public var dropIn:Null<ByteArray->Bool> = null;
	public var forwardedOut:Int = 0;
	public var forwardedIn:Int = 0;

	/** When the first datagram from the client went out of the newest mapping; -1 before. **/
	public var firstOutAt:Float = -1;

	var inside:DatagramSocket;
	var outsides:Array<DatagramSocket> = [];
	var current:DatagramSocket;
	var serverPort:Int;
	var clientPort:Int = 0;
	var random:Int = 12345;

	public function new(serverPort:Int) {
		this.serverPort = serverPort;
		inside = new DatagramSocket();
		inside.bind(0, "127.0.0.1");
		inside.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			clientPort = e.srcPort;
			if (lost() || (dropOut != null && dropOut(e.data))) {
				return;
			}
			if (firstOutAt < 0) {
				firstOutAt = haxe.Timer.stamp();
			}
			forwardedOut++;
			current.send(e.data, 0, e.data.length, "127.0.0.1", this.serverPort);
		});
		inside.receive();
		remap();
	}

	/** A new outside port for the client, from now on. **/
	public function remap():Void {
		var outside = new DatagramSocket();
		outside.bind(0, "127.0.0.1");
		outside.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			// A mapping the NAT has dropped forwards nothing.
			if (outside != current || clientPort == 0) {
				return;
			}
			if (lost() || (dropIn != null && dropIn(e.data))) {
				return;
			}
			forwardedIn++;
			inside.send(e.data, 0, e.data.length, "127.0.0.1", clientPort);
		});
		outside.receive();
		outsides.push(outside);
		current = outside;
		firstOutAt = -1;
	}

	public function close():Void {
		try inside.close() catch (_:Dynamic) {}
		for (outside in outsides) {
			try outside.close() catch (_:Dynamic) {}
		}
	}

	function lost():Bool {
		if (loss <= 0) {
			return false;
		}
		random = (random * 1103515245 + 12345) & 0x7FFFFFFF;
		return (random % 10000) < loss * 10000;
	}

	function get_port():Int {
		return inside.localPort;
	}

	function get_outsidePort():Int {
		return current.localPort;
	}
}
