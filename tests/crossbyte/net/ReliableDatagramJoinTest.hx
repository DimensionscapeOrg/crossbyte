package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrame;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.net._internal.reliable.ResetBudget;
import crossbyte.test.Require;
import utest.Assert;

/**
	What a reliable datagram server sends to addresses that hold no session
	with it: the cookie a join must return before a session is opened for it
	(`joinValidation`), and the resets it answers other frames with, held to
	one allowance for the process.

	Forged CONNECTs are handed to the server as its socket hands datagrams
	over, since a socket only ever sends from one address and port; what a
	real peer receives back is read from a plain `DatagramSocket`.
**/
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramJoinTest extends utest.Test {
	// ------------------------------------------------------------- joins

	/**
		A few CONNECTs a second from forged addresses kept every pending
		slot full, and no real client could join. Past the threshold each is
		answered with a cookie that never reaches anyone, and holds nothing;
		a real client returns its cookie and joins, a round trip later.
	**/
	public function testAFloodOfForgedConnectsDoesNotStopARealClientJoining():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		// Where the forged CONNECTs say they are from: bound and never read,
		// so what the server sends there goes quietly nowhere, as it does to
		// an address that never asked, where a port nobody holds would
		// answer with an ICMP error that ends the session at once.
		var sinks:Array<DatagramSocket> = [];

		try {
			server.bind(0, "127.0.0.1");
			// The ceiling and the threshold made small, so the flood is.
			server.maxPendingConnections = 16;
			server.joinValidationThreshold = 8;
			server.addEventListener(crossbyte.events.ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.listen();

			for (i in 0...40) {
				var sink = new DatagramSocket();
				sink.bind(0, "127.0.0.1");
				sinks.push(sink);
				// As 1.0 peers and as older ones.
				var forged = i % 2 == 0 ? ReliableDatagramProtocol.encodeConnect(0x100 + i) : ReliableDatagramProtocol.encode(CONNECT, 0x100 + i);
				inject(server, forged, "127.0.0.1", sink.localPort);
			}
			pumpUntil(() -> false, 0.3);
			Assert.equals(8, server.__pendingCount, "the flood did not hold just the threshold's worth of slots");

			// And from a thousand addresses more, at once: none holds a slot.
			// Most as peers from before 1.0, which are sent nothing; fifty as
			// 1.0 peers, each sent a cookie to a port nobody holds, no more,
			// since Windows reports each one's ICMP error on a later read, and
			// 64 of those in a row stop a socket receiving.
			for (i in 0...1000) {
				var forged = i % 20 == 0 ? ReliableDatagramProtocol.encodeConnect(0x1000 + i) : ReliableDatagramProtocol.encode(CONNECT, 0x1000 + i);
				inject(server, forged, "127.0.0." + (2 + i % 200), 20000 + i);
			}
			Assert.equals(8, server.__pendingCount, 'the flood from many addresses held ${server.__pendingCount} slots');

			var started:Float = haxe.Timer.stamp();
			client.connect("127.0.0.1", server.localPort, bytesOf("player one"));
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 5.0);
			var took:Float = haxe.Timer.stamp() - started;

			Assert.isTrue(client.connected, 'a real client could not join through the flood (${server.__pendingCount} pending)');
			Assert.isTrue(took < 2.5, 'joining took $took s: the cookie should cost a round trip, not an attempt interval');
			if (accepted != null) {
				Assert.equals("player one", textOf(accepted.connectPayload), "the session's payload was not what connect passed");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
		for (sink in sinks) {
			try sink.close() catch (_:Dynamic) {}
		}
	}

	/**
		A cookie opens a session only for the address, port and attempt it
		was made for: sent from another address or port, or with another
		connection id, it is no cookie, and the CONNECT is answered with a
		fresh one.
	**/
	public function testACookieOpensASessionOnlyWhereItWasSent():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var peer = new RawPeer();

		try {
			server.bind(0, "127.0.0.1");
			server.joinValidation = ALWAYS;
			server.listen();
			peer.open();

			peer.send(ReliableDatagramProtocol.encodeConnect(0xC0FFEE), server.localPort);
			pumpUntil(() -> peer.cookies.length > 0, 2.0);
			var cookie = Require.notNull(peer.cookies[0], "no cookie came back");
			Assert.equals(0xC0FFEE, cookie.id, "the cookie did not echo the attempt's id");
			Assert.equals(0, server.__pendingCount, "a session was held before the cookie came back");

			// Somewhere else: another port, another address, another attempt.
			inject(server, ReliableDatagramProtocol.encodeConnect(0xC0FFEE, null, 0, true, cookie.high, cookie.low), "127.0.0.1", peer.port + 1);
			inject(server, ReliableDatagramProtocol.encodeConnect(0xC0FFEE, null, 0, true, cookie.high, cookie.low), "127.0.0.9", peer.port);
			inject(server, ReliableDatagramProtocol.encodeConnect(0xBEEF, null, 0, true, cookie.high, cookie.low), "127.0.0.1", peer.port);
			// Changed by a bit.
			inject(server, ReliableDatagramProtocol.encodeConnect(0xC0FFEE, null, 0, true, cookie.high, cookie.low ^ 1), "127.0.0.1", peer.port);
			Assert.equals(0, server.__pendingCount, "a cookie opened a session somewhere it was not sent");

			// Where it was sent, it does.
			peer.send(ReliableDatagramProtocol.encodeConnect(0xC0FFEE, null, 0, true, cookie.high, cookie.low), server.localPort);
			pumpUntil(() -> server.__pendingCount > 0, 2.0);
			Assert.equals(1, server.__pendingCount, "the cookie returned from where it was sent opened nothing");
			Assert.notNull(server.__sessionAt("127.0.0.1", peer.port));
			pumpUntil(() -> peer.handshakes > 0, 2.0);
			Assert.isTrue(peer.handshakes > 0, "the session opened never answered");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		peer.close();
		closeServerQuietly(server);
	}

	/**
		A cookie is good for the key it was made with and the one after: past
		that it is refused, and the CONNECT is sent a fresh one.
	**/
	public function testAnExpiredCookieIsRefused():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var peer = new RawPeer();

		try {
			server.bind(0, "127.0.0.1");
			server.joinValidation = ALWAYS;
			server.__pathKeyPeriod = 0.2;
			server.listen();
			peer.open();

			// One turnover later the key before still takes it.
			peer.send(ReliableDatagramProtocol.encodeConnect(0x1001), server.localPort);
			pumpUntil(() -> peer.cookies.length > 0, 2.0);
			var young = Require.notNull(peer.cookies[0]);
			pumpUntil(() -> false, 0.25);
			peer.send(ReliableDatagramProtocol.encodeConnect(0x1001, null, 0, true, young.high, young.low), server.localPort);
			pumpUntil(() -> server.__pendingCount > 0, 2.0);
			Assert.equals(1, server.__pendingCount, "a cookie one turnover old was refused");

			// Two turnovers later nothing does: a fresh cookie comes instead.
			var otherPort = new RawPeer();
			otherPort.open();
			otherPort.send(ReliableDatagramProtocol.encodeConnect(0x2002), server.localPort);
			pumpUntil(() -> otherPort.cookies.length > 0, 2.0);
			var old = Require.notNull(otherPort.cookies[0]);
			pumpUntil(() -> false, 0.45);
			otherPort.cookies = [];
			otherPort.send(ReliableDatagramProtocol.encodeConnect(0x2002, null, 0, true, old.high, old.low), server.localPort);
			pumpUntil(() -> otherPort.cookies.length > 0, 2.0);
			Assert.isNull(server.__sessionAt("127.0.0.1", otherPort.port), "an expired cookie opened a session");
			Assert.equals(1, otherPort.cookies.length, "an expired cookie was not answered with a fresh one");
			if (otherPort.cookies.length > 0) {
				Assert.isFalse(otherPort.cookies[0].high == old.high && otherPort.cookies[0].low == old.low, "the fresh cookie was the expired one");
			}
			otherPort.close();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		peer.close();
		closeServerQuietly(server);
	}

	/** `NEVER` is the server as it was: every CONNECT taken at its word, up to the ceiling. **/
	public function testNeverTakesEveryConnectAtItsWordAsBefore():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var peer = new RawPeer();

		try {
			server.bind(0, "127.0.0.1");
			server.joinValidation = NEVER;
			server.listen();
			peer.open();

			for (i in 0...300) {
				inject(server, ReliableDatagramProtocol.encodeConnect(0x500 + i), "127.0.0.1", 21000 + i);
			}
			Assert.equals(ReliableDatagramServerSocket.DEFAULT_MAX_PENDING_CONNECTIONS, server.__pendingCount, "the ceiling did not hold");

			// A real peer's CONNECT, once a slot is free, opens a session at
			// once, and is never sent a cookie.
			var first = server.__sessionAt("127.0.0.1", 21000);
			Require.notNull(first).__dispose(false);
			peer.send(ReliableDatagramProtocol.encodeConnect(0x7777), server.localPort);
			pumpUntil(() -> peer.handshakes > 0, 2.0);
			Assert.isTrue(peer.handshakes > 0, "a CONNECT was not answered with a HANDSHAKE");
			Assert.equals(0, peer.cookies.length, "a cookie was sent under NEVER");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		peer.close();
		closeServerQuietly(server);
	}

	/**
		Under pressure: joins are validated once the threshold of pending
		sessions is reached, and no longer once they drop below it.
	**/
	public function testTheThresholdSwitchesValidationOnAndOff():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var below = new RawPeer();
		var at = new RawPeer();
		var after = new RawPeer();

		try {
			server.bind(0, "127.0.0.1");
			server.joinValidationThreshold = 3;
			server.listen();
			below.open();
			at.open();
			after.open();

			for (i in 0...2) {
				inject(server, ReliableDatagramProtocol.encodeConnect(0x600 + i), "127.0.0.1", 22000 + i);
			}
			below.send(ReliableDatagramProtocol.encodeConnect(0x6100), server.localPort);
			pumpUntil(() -> below.handshakes > 0, 2.0);
			Assert.equals(0, below.cookies.length, "a join below the threshold was sent a cookie");
			Assert.isTrue(below.handshakes > 0, "a join below the threshold was not answered");
			Assert.equals(3, server.__pendingCount);

			at.send(ReliableDatagramProtocol.encodeConnect(0x6200), server.localPort);
			pumpUntil(() -> at.cookies.length > 0 || at.handshakes > 0, 2.0);
			Assert.equals(1, at.cookies.length, "a join at the threshold was not sent a cookie");
			Assert.equals(0, at.handshakes, "a join at the threshold opened a session without one");
			Assert.equals(3, server.__pendingCount);

			// One handshake given up: below the threshold again.
			Require.notNull(server.__sessionAt("127.0.0.1", 22000)).__dispose(false);
			after.send(ReliableDatagramProtocol.encodeConnect(0x6300), server.localPort);
			pumpUntil(() -> after.cookies.length > 0 || after.handshakes > 0, 2.0);
			Assert.equals(0, after.cookies.length, "validation stayed on below the threshold");
			Assert.isTrue(after.handshakes > 0);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		below.close();
		at.close();
		after.close();
		closeServerQuietly(server);
	}

	/**
		Whatever a server sends back to a CONNECT, a cookie, or the
		HANDSHAKE that opens a session, is never larger than the CONNECT:
		every size of payload a 1.0 peer may send. A CONNECT from before 1.0
		is too short to be sent a cookie, and is sent nothing while joins are
		validated.
	**/
	public function testNothingSentBackToAConnectIsLargerThanIt():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var validating = new ReliableDatagramServerSocket();

		try {
			server.bind(0, "127.0.0.1");
			server.joinValidation = NEVER;
			server.listen();
			validating.bind(0, "127.0.0.1");
			validating.joinValidation = ALWAYS;
			validating.listen();

			var lengths:Array<Int> = [for (n in 0...48) n];
			lengths.push(100);
			lengths.push(ReliableDatagramProtocol.MAX_PAYLOAD_SIZE);
			var larger:Array<String> = [];
			var unanswered:Array<String> = [];
			var id:Int = 0x900;
			for (length in lengths) {
				var payload = new ByteArray();
				payload.length = length;
				for (target in [server, validating]) {
					var peer = new RawPeer();
					peer.open();
					var connect = ReliableDatagramProtocol.encodeConnect(id++, payload);
					peer.send(connect, target.localPort);
					pumpUntil(() -> peer.sizes.length > 0, 1.0);
					if (target == validating && peer.cookies.length > 0) {
						// And the HANDSHAKE the cookie's return draws.
						var cookie = peer.cookies[0];
						var back = ReliableDatagramProtocol.encodeConnect(id - 1, payload, 0, true, cookie.high, cookie.low);
						peer.send(back, target.localPort);
						pumpUntil(() -> peer.handshakes > 0, 1.0);
						for (size in peer.sizes) {
							if (size > connect.length) {
								larger.push('$length with a cookie: $size > ${connect.length}');
							}
						}
					}
					if (peer.sizes.length == 0) {
						unanswered.push('$length' + (target == validating ? " validated" : ""));
					}
					for (size in peer.sizes) {
						if (size > connect.length) {
							larger.push('$length' + (target == validating ? " validated" : "") + ': $size > ${connect.length}');
						}
					}
					peer.close();
				}
			}
			Assert.same([], larger, "answers larger than the CONNECT they answered");
			Assert.same([], unanswered, "CONNECTs nothing answered");

			// From before 1.0: seven bytes, and nothing comes back while joins
			// are validated.
			var older = new RawPeer();
			older.open();
			older.send(ReliableDatagramProtocol.encode(CONNECT, 0), validating.localPort);
			pumpUntil(() -> false, 0.3);
			Assert.equals(0, older.sizes.length, "a CONNECT from before 1.0 drew an answer while joins were validated");
			Assert.isNull(validating.__sessionAt("127.0.0.1", older.port), "a CONNECT from before 1.0 opened a session while joins were validated");
			older.close();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeServerQuietly(server);
		closeServerQuietly(validating);
	}

	/**
		A real client through `ALWAYS`: its first CONNECT draws a cookie, its
		second returns it and is admitted, and what it passed reaches `admit`
		and the session as it was, with nothing of the extension.
	**/
	public function testAClientJoinsThroughACookieWithItsPayloadIntact():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:ReliableDatagramSocket = null;
		var asked:Array<String> = [];

		try {
			server.bind(0, "127.0.0.1");
			server.joinValidation = ALWAYS;
			server.admit = (_, _, payload) -> {
				asked.push(payload.readUTFBytes(payload.bytesAvailable));
				return true;
			};
			server.addEventListener(crossbyte.events.ReliableDatagramSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.listen();

			client.connect("127.0.0.1", server.localPort, bytesOf("ticket-42"));
			pumpUntil(() -> client.connected && accepted != null && accepted.connected, 3.0);

			Assert.isTrue(client.connected, "the client never joined through its cookie");
			Assert.same(["ticket-42"], asked, "admit was asked before the cookie came back, or saw the extension");
			if (accepted != null) {
				Assert.equals("ticket-42", textOf(accepted.connectPayload));
			}
			Assert.isNull(client.__connectScratch, "a connected client kept what it built its CONNECTs in");

			// And a message each way.
			var heard:Array<String> = [];
			if (accepted != null) {
				accepted.addEventListener(DatagramSocketDataEvent.DATA, e -> heard.push(e.data.readUTFBytes(e.data.length)));
			}
			client.send(bytesOf("hello"));
			pumpUntil(() -> heard.length > 0, 2.0);
			Assert.same(["hello"], heard);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeQuietly(client);
		closeServerQuietly(server);
	}

	/**
		Two servers dialling each other, each CONNECT finding the session
		its server dialled, need no cookie, whatever `joinValidation` says.
	**/
	public function testPeersThatBothDialAreNotAskedForACookie():Void {
		if (!requireDatagramSupport()) return;

		var alice = new ReliableDatagramServerSocket();
		var bob = new ReliableDatagramServerSocket();

		try {
			alice.bind(0, "127.0.0.1");
			alice.joinValidation = ALWAYS;
			alice.listen();
			bob.bind(0, "127.0.0.1");
			bob.joinValidation = ALWAYS;
			bob.listen();

			var toBob = alice.connect("127.0.0.1", bob.localPort, ReliableDatagramSocket.DEFAULT_TIMEOUT, bytesOf("from alice"));
			var toAlice = bob.connect("127.0.0.1", alice.localPort, ReliableDatagramSocket.DEFAULT_TIMEOUT, bytesOf("from bob"));
			pumpUntil(() -> toBob.connected && toAlice.connected, 5.0);

			Assert.isTrue(toBob.connected && toAlice.connected, "two dialled sessions never connected under ALWAYS");
			Assert.equals("from bob", textOf(toBob.connectPayload));
			Assert.equals("from alice", textOf(toAlice.connectPayload));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		closeServerQuietly(alice);
		closeServerQuietly(bob);
	}

	// ------------------------------------------------------------- resets

	/**
		A frame from an address with no session draws a FIN. One was sent for
		every such frame, however many came: a sender naming someone else's
		address could have the server send that address a datagram for each
		it sent. Now the process holds them to `maxResetsPerSecond`.
	**/
	public function testResetsToStrangersAreHeldToTheProcessAllowance():Void {
		if (!requireDatagramSupport()) return;

		var server = new ReliableDatagramServerSocket();
		var stranger = new DatagramSocket();
		var resets:Int = 0;
		var before:Int = ReliableDatagramServerSocket.maxResetsPerSecond;

		try {
			server.bind(0, "127.0.0.1");
			server.listen();
			stranger.bind(0, "127.0.0.1");
			try stranger.receiveBufferSize = 1 << 20 catch (_:Dynamic) {}
			stranger.addEventListener(DatagramSocketDataEvent.DATA, e -> {
				var frame = ReliableDatagramProtocol.decode(e.data);
				if (frame != null && frame.type == ReliableDatagramFrameType.FIN) {
					resets++;
				}
			});
			stranger.receive();

			ReliableDatagramServerSocket.maxResetsPerSecond = 50;
			ResetBudget.refill();
			var started:Float = haxe.Timer.stamp();

			// Frames as a session sends them, from an address the server has
			// never heard of: each one draws a reset, as far as the allowance
			// goes.
			var frame = ReliableDatagramProtocol.encode(PACKET, 1, bytesOf("x"), false, 1);
			for (i in 0...600) {
				stranger.send(frame, 0, frame.length, "127.0.0.1", server.localPort);
				if (i % 50 == 49) {
					CrossByte.current().pump(0, 0);
				}
			}
			pumpUntil(() -> false, 0.3);
			var took:Float = haxe.Timer.stamp() - started;

			// A full bucket's worth at once, and what it refilled since.
			var allowed:Float = 50 + took * 50 + 2;
			Assert.isTrue(resets >= 40, 'the first $resets resets were not let through at once');
			Assert.isTrue(resets <= allowed, '$resets resets were sent in $took s, past the allowance of $allowed');

			// The allowance comes back with time.
			var then:Int = resets;
			pumpUntil(() -> false, 0.2);
			for (_ in 0...20) {
				stranger.send(frame, 0, frame.length, "127.0.0.1", server.localPort);
			}
			pumpUntil(() -> resets > then, 1.0);
			Assert.isTrue(resets > then, 'no reset was sent once the allowance had filled again ($then before, $resets after; first phase $took s)');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		ReliableDatagramServerSocket.maxResetsPerSecond = before;
		ResetBudget.refill();
		try server.close() catch (_:Dynamic) {}
		try stranger.close() catch (_:Dynamic) {}
	}

	/** Negative lifts the limit, and 0 sends none. **/
	public function testTheAllowanceCanBeLiftedOrClosed():Void {
		var before:Int = ReliableDatagramServerSocket.maxResetsPerSecond;
		var now:Float = haxe.Timer.stamp();

		ResetBudget.refill();
		var taken:Int = 0;
		for (_ in 0...5000) {
			if (ResetBudget.take(-1, now)) {
				taken++;
			}
		}
		Assert.equals(5000, taken, "a negative allowance held resets back");

		taken = 0;
		for (_ in 0...10) {
			if (ResetBudget.take(0, now)) {
				taken++;
			}
		}
		Assert.equals(0, taken, "an allowance of 0 let a reset through");

		// A full bucket is one second's worth, and no more however long it
		// has been idle.
		ResetBudget.refill();
		taken = 0;
		for (_ in 0...30) {
			if (ResetBudget.take(10, now)) {
				taken++;
			}
		}
		Assert.equals(10, taken);
		taken = 0;
		for (_ in 0...30) {
			if (ResetBudget.take(10, now + 100)) {
				taken++;
			}
		}
		Assert.equals(10, taken, "an idle bucket filled past one second's worth");
		// Half a second refills half of it.
		taken = 0;
		for (_ in 0...30) {
			if (ResetBudget.take(10, now + 100.5)) {
				taken++;
			}
		}
		Assert.equals(5, taken);

		ReliableDatagramServerSocket.maxResetsPerSecond = before;
		ResetBudget.refill();
	}

	// ------------------------------------------------------------- helpers

	/** A datagram handed to the server as its socket hands one over, from wherever it says. **/
	private static function inject(server:ReliableDatagramServerSocket, frame:ByteArray, address:String, port:Int):Void {
		var packet = new ByteArray();
		packet.writeBytes(frame, 0, frame.length);
		packet.position = 0;
		server.__receiveDatagram(packet, address, port);
	}

	private static function textOf(bytes:ByteArray):String {
		if (bytes == null) {
			return null;
		}
		var at:Int = bytes.position;
		bytes.position = 0;
		var text:String = bytes.readUTFBytes(bytes.length);
		bytes.position = at;
		return text;
	}

	private static function closeQuietly(socket:ReliableDatagramSocket):Void {
		try {
			if (socket != null) {
				socket.abort();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeServerQuietly(server:ReliableDatagramServerSocket):Void {
		try {
			if (server != null) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function requireDatagramSupport():Bool {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return false;
		}
		return true;
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
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

private typedef Cookie = {id:Int, high:Int, low:Int};

/**
	A plain datagram socket standing in for a peer: it sends frames as
	written, and keeps what comes back, the size of every datagram, the
	cookies, how many HANDSHAKEs, and each FIN's sequence field.
**/
private class RawPeer {
	public var socket:DatagramSocket;
	public var port(get, never):Int;
	public var sizes:Array<Int> = [];
	public var cookies:Array<Cookie> = [];
	public var handshakes:Int = 0;
	public var fins:Array<Int> = [];

	public function new() {}

	public function open():Void {
		socket = new DatagramSocket();
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			sizes.push(e.data.length);
			var frame = ReliableDatagramProtocol.decode(e.data);
			if (frame == null) {
				return;
			}
			switch (frame.type) {
				case HANDSHAKE:
					handshakes++;
				case FIN:
					fins.push(frame.sequence);
				case PATH:
					var bytes:haxe.io.Bytes = frame.payload;
					if (bytes.get(0) == ReliableDatagramProtocol.PATH_COOKIE && bytes.length >= 9) {
						cookies.push({
							id: frame.sequence,
							high: (bytes.get(1) << 24) | (bytes.get(2) << 16) | (bytes.get(3) << 8) | bytes.get(4),
							low: (bytes.get(5) << 24) | (bytes.get(6) << 16) | (bytes.get(7) << 8) | bytes.get(8)
						});
					}
				default:
			}
		});
		socket.receive();
	}

	public function send(frame:ByteArray, to:Int):Void {
		socket.send(frame, 0, frame.length, "127.0.0.1", to);
	}

	public function close():Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private function get_port():Int {
		return socket.localPort;
	}
}
