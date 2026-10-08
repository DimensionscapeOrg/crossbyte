package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol.ReliableDatagramFrameType;
import crossbyte.net._internal.reliable.ResetBudget;
import crossbyte.net._internal.reliable.SessionCipher;
import haxe.io.Bytes;
import utest.Assert;

/**
	Encrypted reliable UDP sessions over real sockets
	(`ReliableDatagramSocket.encryptionKey`,
	`ReliableDatagramServerSocket.encryptionKeyFor`): the handshake that
	negotiates it, what goes on the wire, and every way it fails closed.

	Between the client and the server sits `Wire`, a relay written for the
	tests, which records every datagram each way and can lose, reorder,
	change or add to them.
**/
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
class ReliableDatagramEncryptionTest extends utest.Test {
	public function setup():Void {
		ResetBudget.refill();
	}

	/** What the API refuses, and where encryption is not supported at all, that it says so. **/
	public function testTheApiRefusesWhatItCannotDo():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isEncryptionSupported);
			return;
		}
		var socket = new ReliableDatagramSocket();
		if (!ReliableDatagramSocket.isEncryptionSupported) {
			// HashLink, neko, the interpreter: no secure random source.
			Assert.raises(() -> socket.encryptionKey = key(1), IllegalOperationError);
			Assert.isFalse(socket.encrypted);
			socket.abort();
			return;
		}
		Assert.isFalse(socket.encrypted);
		Assert.raises(() -> socket.encryptionKey = Bytes.alloc(16), ArgumentError);
		Assert.raises(() -> socket.encryptionKey = Bytes.alloc(33), ArgumentError);
		socket.encryptionKey = key(1);
		Assert.isTrue(socket.encrypted);
		socket.encryptionKey = null;
		Assert.isFalse(socket.encrypted);
		socket.encryptionKey = key(1);

		// A CONNECT payload of an encrypted session fits one sealed frame.
		var large = new ByteArray();
		large.length = ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE + 1;
		Assert.raises(() -> socket.connect("127.0.0.1", 9, large), crossbyte.errors.RangeError);

		var server = new ReliableDatagramServerSocket();
		server.bind(0, "127.0.0.1");
		server.listen();
		socket.connect("127.0.0.1", server.localPort);
		Assert.raises(() -> socket.encryptionKey = key(2), IllegalOperationError);
		Assert.raises(() -> server.connect("127.0.0.1", 9, 1000, null, Bytes.alloc(31)), ArgumentError);
		socket.abort();
		server.close();
		Assert.equals(21, ReliableDatagramSocket.ENCRYPTION_OVERHEAD);
		Assert.equals(1179, ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE);
	}

	/**
		Every kind of message both ways (reliable, a reliable one in five
		fragments, unreliable, sequenced) arrives, and on the wire nothing
		after the client's CONNECT is in the clear: every datagram either way
		is sealed, the hellos first, and no message's bytes appear in any.
	**/
	public function testAnEncryptedSessionCarriesEveryKindOfMessage():Void {
		if (!requireEncryption()) return;
		var pair = Pair.open(key(7), key(7));
		if (pair == null) {
			Assert.fail("the encrypted pair never connected");
			return;
		}
		try {
			Assert.isTrue(pair.client.encrypted && pair.session.encrypted);
			var big = marked(5000);
			pair.client.send(Pair.text("reliable"));
			pair.client.send(big);
			pair.client.send(Pair.text("unreliable"), 0, 0, DeliveryMode.UNRELIABLE);
			pair.client.send(Pair.text("sequenced"), 0, 0, DeliveryMode.sequenced(2));
			pair.session.send(Pair.text("back"));
			pair.session.send(Pair.text("back unreliable"), 0, 0, DeliveryMode.UNRELIABLE);
			Pair.pumpUntil(() -> pair.serverGot.length >= 4 && pair.clientGot.length >= 2, 5.0);
			Assert.same(["reliable", "big:5000", "unreliable", "sequenced"], pair.serverGot);
			Assert.same(["back", "back unreliable"], pair.clientGot);

			var first:Array<Int> = [];
			var plainAfterConnect:Int = 0;
			var markers:Int = 0;
			for (d in pair.wire.out.concat(pair.wire.back)) {
				var b:Int = d.get(0);
				if (b == SessionCipher.SEALED || b == SessionCipher.SEALED_HELLO) {
					if (first.indexOf(b) < 0) first.push(b);
				}
				markers += count(d, "fragment-marker");
			}
			for (d in pair.wire.back) {
				if (d.get(0) != SessionCipher.SEALED && d.get(0) != SessionCipher.SEALED_HELLO) plainAfterConnect++;
			}
			var sawConnect:Bool = false;
			for (d in pair.wire.out) {
				var sealed:Bool = d.get(0) == SessionCipher.SEALED || d.get(0) == SessionCipher.SEALED_HELLO;
				if (!sealed) {
					var frame = ReliableDatagramProtocol.decode(ByteArray.fromBytes(d));
					if (frame != null && frame.type == CONNECT && (frame.features & ReliableDatagramProtocol.FEATURE_ENCRYPT) != 0) {
						sawConnect = true;
					} else {
						plainAfterConnect++;
					}
				}
			}
			Assert.isTrue(sawConnect, "no encrypted CONNECT went");
			Assert.equals(0, plainAfterConnect, "something but the CONNECT went in the clear");
			Assert.equals(0, markers, "a message's bytes were on the wire in the clear");
			Assert.equals(0.0, pair.client.unauthenticatedDatagrams + pair.session.unauthenticatedDatagrams);
			Assert.equals(0.0, pair.client.replayedDatagrams + pair.session.replayedDatagrams);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	/**
		Reliable messages both ways through a path that loses 15% of what
		crosses each way and swaps neighbours: every one arrives once and in
		order, and none of the duplicates retransmission makes is taken twice.
	**/
	public function testUnderLossAndReordering():Void {
		if (!requireEncryption()) return;
		var pair = Pair.open(key(9), key(9));
		if (pair == null) {
			Assert.fail("the encrypted pair never connected");
			return;
		}
		try {
			pair.wire.loss = 0.15;
			pair.wire.reorder = true;
			for (i in 0...60) {
				pair.client.send(Pair.text("c" + i));
				pair.session.send(Pair.text("s" + i));
				if (i % 4 == 0) {
					pair.client.send(Pair.text("u" + i), 0, 0, DeliveryMode.UNRELIABLE);
				}
				Pair.pumpUntil(() -> false, 0.004);
			}
			Pair.pumpUntil(() -> countPrefix(pair.serverGot, "c") >= 60 && countPrefix(pair.clientGot, "s") >= 60, 15.0);
			Assert.same([for (i in 0...60) "c" + i], [for (m in pair.serverGot) if (m.charAt(0) == "c") m]);
			Assert.same([for (i in 0...60) "s" + i], [for (m in pair.clientGot) if (m.charAt(0) == "s") m]);
			Assert.isTrue(pair.wire.dropped > 0, "the path lost nothing");
			Assert.equals(0.0, pair.client.unauthenticatedDatagrams + pair.session.unauthenticatedDatagrams);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	/**
		The two ends hold different keys: the client's attempt ends at the
		server's first answer, with an `ioError` that says so and then
		`close`; the server announces no session; nothing but the CONNECT
		went in the clear.
	**/
	public function testAWrongKeyFailsCleanly():Void {
		if (!requireEncryption()) return;
		var attempt = Attempt.run(key(1), key(2));
		Assert.isTrue(attempt.closed, "the client did not close");
		Assert.notNull(attempt.error, "no ioError said why");
		if (attempt.error != null) {
			Assert.isTrue(attempt.error.indexOf("different keys") >= 0, attempt.error);
		}
		Assert.isTrue(attempt.took < 2.0, 'the mismatch took ${attempt.took} s to report');
		Assert.equals(0, attempt.accepted, "the server announced a session");
		Assert.isFalse(attempt.connected, "the client connected");
		attempt.close();
	}

	/** A client asks for encryption and the server's `encryptionKeyFor` gives none: refused, at once, saying why. **/
	public function testAServerWithoutAKeyRefuses():Void {
		if (!requireEncryption()) return;
		var attempt = Attempt.run(null, key(3));
		Assert.isTrue(attempt.closed);
		Assert.notNull(attempt.error);
		if (attempt.error != null) {
			Assert.isTrue(attempt.error.indexOf("has no key") >= 0, attempt.error);
		}
		Assert.isTrue(attempt.took < 2.0, 'the refusal took ${attempt.took} s');
		Assert.equals(0, attempt.accepted);
		Assert.isTrue(attempt.server.__pendingCount == 0, "a session was opened for the refused CONNECT");
		attempt.close();
	}

	/** The server gives every session a key, and a client asked for none: refused, saying why; no session in the clear. **/
	public function testAServerThatEncryptsRefusesAPeerWithoutAKey():Void {
		if (!requireEncryption()) return;
		var attempt = Attempt.run(key(4), null);
		Assert.isTrue(attempt.closed);
		Assert.notNull(attempt.error);
		if (attempt.error != null) {
			Assert.isTrue(attempt.error.indexOf("encrypts this session") >= 0, attempt.error);
		}
		Assert.equals(0, attempt.accepted, "a session was opened in the clear");
		attempt.close();
	}

	/**
		A server from before encryption reads past the random as past padding
		and answers in the clear: the client refuses it, saying so, and sends
		it nothing more in the clear.
	**/
	public function testAnOlderServerFailsClosed():Void {
		if (!requireEncryption()) return;
		var old = new OldServer();
		var client = new ReliableDatagramSocket();
		var error:String = null;
		var closed:Bool = false;
		client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> error = e.text);
		client.addEventListener(Event.CLOSE, _ -> closed = true);
		client.encryptionKey = key(5);
		client.connect("127.0.0.1", old.port);
		Pair.pumpUntil(() -> closed, 3.0);
		Assert.isTrue(closed, "the client went on with a peer that does not encrypt");
		Assert.notNull(error);
		if (error != null) {
			Assert.isTrue(error.indexOf("without encryption") >= 0, error);
		}
		Assert.isFalse(client.connected);
		Assert.isTrue(old.connects > 0);
		Assert.equals(0, old.others, "the client sent something but CONNECTs to a peer in the clear");
		client.abort();
		old.close();
	}

	/**
		A CONNECT that asks for no encryption (from a peer on 1.0, or one
		from before 1.0) opens no session on a server that encrypts: the
		1.0 one is told why, and the older one, whose CONNECT is too short to
		answer with more, is dropped.
	**/
	public function testAnOlderClientIsNotLetIn():Void {
		if (!requireEncryption()) return;
		var server = new ReliableDatagramServerSocket();
		server.bind(0, "127.0.0.1");
		server.encryptionKeyFor = (_, _, _) -> key(6);
		server.listen();
		var raw = new RawPeer();
		var oneZero = ReliableDatagramProtocol.encodeConnect(0x1234);
		raw.send(oneZero, server.localPort);
		var older = ReliableDatagramProtocol.encode(CONNECT, 0x4321);
		raw.send(older, server.localPort);
		Pair.pumpUntil(() -> raw.got.length > 0, 1.0);
		Pair.pumpUntil(() -> false, 0.2);
		Assert.equals(0, server.__pendingCount, "a session was opened in the clear");
		Assert.equals(1, raw.got.length, "the answers were " + raw.got.length);
		if (raw.got.length > 0) {
			var frame = ReliableDatagramProtocol.decode(ByteArray.fromBytes(raw.got[0]));
			Assert.equals(ReliableDatagramFrameType.PATH, frame.type);
			Assert.equals(0x1234, (frame.sequence : Int));
			Assert.equals(ReliableDatagramProtocol.PATH_REFUSE, (frame.payload : Bytes).get(0));
			Assert.equals(ReliableDatagramProtocol.REFUSE_ENCRYPTION_REQUIRED, (frame.payload : Bytes).get(1));
			Assert.isTrue(raw.got[0].length <= oneZero.length, "the refusal was larger than the CONNECT");
		}
		raw.close();
		server.close();
	}

	/**
		Two peers that dial each other at once, as through NAT, each with the
		same key: each takes the other's random from its CONNECT, and the
		session comes up encrypted both ways.
	**/
	public function testTwoEncryptedPeersThatBothDial():Void {
		if (!requireEncryption()) return;
		var a = new ReliableDatagramServerSocket();
		var b = new ReliableDatagramServerSocket();
		a.bind(0, "127.0.0.1");
		b.bind(0, "127.0.0.1");
		a.listen();
		b.listen();
		var fromA:Array<String> = [];
		var fromB:Array<String> = [];
		var toB = a.connect("127.0.0.1", b.localPort, 5000, null, key(8));
		var toA = b.connect("127.0.0.1", a.localPort, 5000, null, key(8));
		toB.addEventListener(DatagramSocketDataEvent.DATA, (e:DatagramSocketDataEvent) -> fromB.push(e.data.readUTFBytes(e.data.length)));
		toA.addEventListener(DatagramSocketDataEvent.DATA, (e:DatagramSocketDataEvent) -> fromA.push(e.data.readUTFBytes(e.data.length)));
		Pair.pumpUntil(() -> toA.connected && toB.connected, 5.0);
		Assert.isTrue(toA.connected && toB.connected, "the two dialling peers never connected");
		if (toA.connected && toB.connected) {
			toB.send(Pair.text("hello b"));
			toA.send(Pair.text("hello a"));
			Pair.pumpUntil(() -> fromA.length > 0 && fromB.length > 0, 3.0);
			Assert.same(["hello b"], fromA);
			Assert.same(["hello a"], fromB);
			Assert.isTrue(toA.__cipher.ready && toB.__cipher.ready);
		}
		a.close();
		b.close();
	}

	/**
		A datagram in the clear, made to look like the server's (a message,
		an acknowledgement, a FIN), reaches the connected client through the
		path: none of it is delivered or acted on, the session stays up, and
		each is counted.
	**/
	public function testFramesInTheClearAreDroppedAndCounted():Void {
		if (!requireEncryption()) return;
		var pair = Pair.open(key(10), key(10));
		if (pair == null) {
			Assert.fail("the encrypted pair never connected");
			return;
		}
		try {
			var before:Float = pair.client.unauthenticatedDatagrams;
			pair.wire.toClient(ReliableDatagramProtocol.encode(UNRELIABLE, 0, Pair.text("forged")));
			pair.wire.toClient(ReliableDatagramProtocol.encode(PACKET, 1, Pair.text("forged reliable"), false, 1));
			pair.wire.toClient(ReliableDatagramProtocol.encode(FIN, 5, null, false, null, false, true));
			pair.wire.toServer(ReliableDatagramProtocol.encode(UNRELIABLE, 0, Pair.text("forged up")));
			Pair.pumpUntil(() -> false, 0.3);
			Assert.same([], pair.clientGot, "a datagram in the clear was delivered");
			Assert.same([], pair.serverGot, "a datagram in the clear was delivered to the server");
			Assert.isTrue(pair.client.connected && pair.session.connected, "a FIN in the clear ended the session");
			Assert.equals(before + 3, pair.client.unauthenticatedDatagrams);
			Assert.equals(1.0, pair.session.unauthenticatedDatagrams);
			// And it still works.
			pair.client.send(Pair.text("after"));
			Pair.pumpUntil(() -> pair.serverGot.length > 0, 2.0);
			Assert.same(["after"], pair.serverGot);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	/**
		An encrypted session's frames carry at most 1,179 bytes, so no
		datagram it sends is larger than the largest in the clear: a reliable
		message split, small ones bundled, the largest unreliable and
		sequenced ones, both ways, every datagram on the wire at most 1,211
		bytes, and the largest exactly that. One byte more, unreliable, is
		refused.
	**/
	public function testASealedDatagramFitsTheSamePath():Void {
		if (!requireEncryption()) return;
		var plain = new ReliableDatagramSocket();
		Assert.equals(1200, plain.maxPayloadSize);
		plain.encryptionKey = key(11);
		Assert.equals(1179, plain.maxPayloadSize);
		plain.abort();
		var pair = Pair.open(key(11), key(11));
		if (pair == null) {
			Assert.fail("the encrypted pair never connected");
			return;
		}
		try {
			Assert.equals(ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE, pair.client.maxPayloadSize);
			Assert.equals(ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE, pair.session.maxPayloadSize);
			var full = marked(ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE);
			Assert.raises(() -> pair.client.send(marked(ReliableDatagramSocket.MAX_ENCRYPTED_PAYLOAD_SIZE + 1), 0, 0, DeliveryMode.UNRELIABLE),
				crossbyte.errors.RangeError);
			for (socket in [pair.client, pair.session]) {
				socket.send(marked(5000));
				for (i in 0...40) {
					socket.send(Pair.text("small " + i));
				}
				socket.send(full, 0, 0, DeliveryMode.UNRELIABLE);
				socket.send(full, 0, 0, DeliveryMode.sequenced(1));
			}
			Pair.pumpUntil(() -> pair.serverGot.length >= 43 && pair.clientGot.length >= 43, 5.0);
			Assert.equals(43, pair.serverGot.length);
			Assert.equals(43, pair.clientGot.length);
			var largest:Int = 0;
			for (d in pair.wire.out.concat(pair.wire.back)) {
				if (d.length > largest) {
					largest = d.length;
				}
			}
			Assert.equals(ReliableDatagramProtocol.MAX_FRAME_SIZE, largest, 'the largest datagram on the wire was $largest bytes');
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	/**
		A player moving with encryption: the NAT gives the client a new port
		mid-stream, and the session follows it, every message both ways once
		and in order, on the same session object, the REBIND's proof keyed with
		the session's own rebind key, which both ends derived and no datagram
		carried. The server's hello, carrying no key, is no larger than the
		CONNECT it answers.
	**/
	public function testAnEncryptedSessionFollowsItsPlayer():Void {
		if (!requireEncryption()) return;
		var pair = Pair.open(key(12), key(12), true);
		if (pair == null) {
			Assert.fail("the encrypted pair never connected");
			return;
		}
		try {
			var derived:Bytes = pair.client.__cipher.rebindKey;
			Assert.notNull(pair.client.__rebindKey, "the client has no rebind key");
			Assert.isTrue(pair.client.__rebindKey == derived, "the client's rebind key is not the derived one");
			Assert.isTrue(pair.session.__rebindKey != null && pair.session.__rebindKey.toHex() == derived.toHex(),
				"the server's session does not hold the same derived key");
			var leaked:Int = 0;
			for (d in pair.wire.out.concat(pair.wire.back)) {
				leaked += countBytes(d, derived);
			}
			Assert.equals(0, leaked, "the rebind key crossed the wire");
			var connect:Int = 0;
			for (d in pair.wire.out) {
				if (d.get(0) == 0xCB) {
					connect = d.length;
					break;
				}
			}
			for (d in pair.wire.back) {
				if (d.get(0) == SessionCipher.SEALED_HELLO) {
					Assert.isTrue(d.length <= connect, 'the server answered a ${connect}-byte CONNECT with ${d.length} bytes');
					break;
				}
			}

			var oldPort:Int = pair.session.remotePort;
			for (i in 0...20) {
				pair.client.send(Pair.text("c" + i));
				pair.session.send(Pair.text("s" + i));
				Pair.pumpUntil(() -> false, 0.004);
			}
			pair.wire.remap();
			for (i in 20...50) {
				if (pair.client.connected) {
					pair.client.send(Pair.text("c" + i));
				}
				if (pair.session.connected) {
					pair.session.send(Pair.text("s" + i));
				}
				Pair.pumpUntil(() -> false, 0.004);
			}
			Pair.pumpUntil(() -> pair.serverGot.length >= 50 && pair.clientGot.length >= 50, 10.0);
			Assert.same([for (i in 0...50) "c" + i], pair.serverGot);
			Assert.same([for (i in 0...50) "s" + i], pair.clientGot);
			Assert.equals(1, pair.accepted.length, "the server announced another session");
			Assert.isTrue(pair.client.connected && pair.session.connected, "the session did not survive the move");
			Assert.equals(pair.wire.outsidePort, pair.session.remotePort, "the session is not at the new port");
			Assert.notEquals(oldPort, pair.session.remotePort);
			Assert.isTrue(pair.session == pair.server.__sessionAt("127.0.0.1", pair.wire.outsidePort));
			// Sealed wherever it went: nothing in the clear from the client but
			// its CONNECT and its REBINDs.
			var plain:Int = 0;
			var rebinds:Int = 0;
			for (d in pair.wire.out) {
				if (d.get(0) != SessionCipher.SEALED && d.get(0) != SessionCipher.SEALED_HELLO) {
					var frame = ReliableDatagramProtocol.decode(ByteArray.fromBytes(d));
					if (frame != null && frame.type == PATH) {
						rebinds++;
					} else if (frame == null || frame.type != CONNECT) {
						plain++;
					}
				}
			}
			Assert.isTrue(rebinds > 0, "no REBIND went");
			Assert.equals(0, plain, "the client sent frames in the clear");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	/**
		A REBIND whose proof is keyed with anything but the derived key (as
		one made with a key seen in the clear would be) moves nothing.
	**/
	public function testARebindProvedWithoutTheSessionKeyIsRefused():Void {
		if (!requireEncryption()) return;
		var pair = Pair.open(key(13), key(13), true);
		if (pair == null) {
			Assert.fail("the encrypted pair never connected");
			return;
		}
		try {
			var home:Int = pair.session.remotePort;
			var forger = new RawPeer();
			// A frame in the clear from the forger's address draws a reset
			// carrying the challenge for that address.
			forger.send(ReliableDatagramProtocol.encode(PACKET, 1, Pair.text("x"), false, 1), pair.server.localPort);
			Pair.pumpUntil(() -> forger.got.length > 0, 1.0);
			Assert.isTrue(forger.got.length > 0, "no reset came");
			if (forger.got.length > 0) {
				var reset = ReliableDatagramProtocol.decode(ByteArray.fromBytes(forger.got[0]));
				var challenge:Int = reset.sequence;
				Assert.notEquals(0, challenge);
				var id:Int = pair.session.__peerConnectionId;
				var input = Bytes.alloc(9);
				input.set(0, 0x52);
				setInt(input, 1, id);
				setInt(input, 5, challenge);
				var hash = new crossbyte.net._internal.reliable.SipHash(Bytes.alloc(16));
				hash.hash(input, 0, 9);
				var body = new ByteArray();
				body.length = 13;
				var b:Bytes = body;
				b.set(0, ReliableDatagramProtocol.PATH_REBIND);
				setInt(b, 1, challenge);
				setInt(b, 5, hash.high);
				setInt(b, 9, hash.low);
				forger.send(ReliableDatagramProtocol.encode(PATH, id, body), pair.server.localPort);
				Pair.pumpUntil(() -> false, 0.3);
			}
			Assert.equals(home, pair.session.remotePort, "a forged REBIND moved the session");
			forger.close();
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		pair.close();
	}

	static function setInt(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, value >>> 24);
		bytes.set(at + 1, (value >>> 16) & 0xFF);
		bytes.set(at + 2, (value >>> 8) & 0xFF);
		bytes.set(at + 3, value & 0xFF);
	}

	static function countBytes(data:Bytes, needle:Bytes):Int {
		var found:Int = 0;
		var at:Int = 0;
		while (at + needle.length <= data.length) {
			var match:Bool = true;
			for (i in 0...needle.length) {
				if (data.get(at + i) != needle.get(i)) {
					match = false;
					break;
				}
			}
			if (match) {
				found++;
			}
			at++;
		}
		return found;
	}

	// ------------------------------------------------------------ helpers

	public static function requireEncryption():Bool {
		if (!ReliableDatagramSocket.isEncryptionSupported) {
			// No UDP, or no secure random source: the flag says so, and the
			// setter refuses (testTheApiRefusesWhatItCannotDo).
			Assert.isFalse(ReliableDatagramSocket.isEncryptionSupported);
			return false;
		}
		return true;
	}

	public static function key(seed:Int):Bytes {
		var out = Bytes.alloc(32);
		for (i in 0...32) {
			out.set(i, (i * 31 + seed * 17) & 255);
		}
		return out;
	}

	/** `length` bytes, a marker repeated through them: what must never be seen on the wire. **/
	static function marked(length:Int):ByteArray {
		var bytes = new ByteArray();
		var marker = "fragment-marker";
		while (bytes.length < length) {
			bytes.writeUTFBytes(marker);
		}
		bytes.length = length;
		bytes.position = 0;
		return bytes;
	}

	static function count(data:Bytes, text:String):Int {
		var found:Int = 0;
		var at:Int = 0;
		while (at + text.length <= data.length) {
			var match:Bool = true;
			for (i in 0...text.length) {
				if (data.get(at + i) != StringTools.fastCodeAt(text, i)) {
					match = false;
					break;
				}
			}
			if (match) {
				found++;
			}
			at++;
		}
		return found;
	}

	static function countPrefix(list:Array<String>, prefix:String):Int {
		var n:Int = 0;
		for (m in list) {
			if (StringTools.startsWith(m, prefix)) n++;
		}
		return n;
	}
}

/** A server and a client connected through a `Wire`, each message each way kept. **/
@:access(crossbyte.net.ReliableDatagramServerSocket)
@:access(crossbyte.net.ReliableDatagramSocket)
private class Pair {
	public var server:ReliableDatagramServerSocket;
	public var wire:Wire;
	public var client:ReliableDatagramSocket;
	public var session:ReliableDatagramSocket;
	public var accepted:Array<ReliableDatagramSocket> = [];
	public var serverGot:Array<String> = [];
	public var clientGot:Array<String> = [];

	public function new() {}

	public static function open(serverKey:Null<Bytes>, clientKey:Null<Bytes>, allowRebind:Bool = false):Null<Pair> {
		var pair = new Pair();
		pair.server = new ReliableDatagramServerSocket();
		pair.server.bind(0, "127.0.0.1");
		pair.server.allowRebind = allowRebind;
		pair.server.encryptionKeyFor = (_, _, _) -> serverKey;
		pair.server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent):Void {
			pair.accepted.push(e.socket);
			e.socket.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent):Void {
				pair.serverGot.push(describe(d.data));
			});
		});
		pair.server.listen();
		pair.wire = new Wire(pair.server.localPort);
		pair.client = new ReliableDatagramSocket();
		pair.client.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent):Void {
			pair.clientGot.push(describe(d.data));
		});
		if (clientKey != null) {
			pair.client.encryptionKey = clientKey;
		}
		pair.client.connect("127.0.0.1", pair.wire.port);
		pumpUntil(() -> pair.client.connected && pair.accepted.length > 0 && pair.accepted[0].connected, 5.0);
		if (!pair.client.connected || pair.accepted.length == 0) {
			pair.close();
			return null;
		}
		pair.session = pair.accepted[0];
		return pair;
	}

	static function describe(data:ByteArray):String {
		if (data.length > 100) {
			return "big:" + data.length;
		}
		return data.readUTFBytes(data.length);
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
		if (wire != null) {
			wire.close();
		}
	}

	public static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		var last = haxe.Timer.stamp();
		while (!done() && haxe.Timer.stamp() < deadline) {
			var now = haxe.Timer.stamp();
			runtime.pump(now - last, 0);
			last = now;
			Wire.tickAll();
			crossbyte.sys.System.sleep(0.001);
		}
	}
}

/** One client's attempt at a server, with each side's key or none, run until it connects or ends. **/
@:access(crossbyte.net.ReliableDatagramServerSocket)
private class Attempt {
	public var server:ReliableDatagramServerSocket;
	public var client:ReliableDatagramSocket;
	public var error:String = null;
	public var closed:Bool = false;
	public var connected:Bool = false;
	public var accepted:Int = 0;
	public var took:Float = 0;

	public function new() {}

	public static function run(serverKey:Null<Bytes>, clientKey:Null<Bytes>):Attempt {
		var attempt = new Attempt();
		attempt.server = new ReliableDatagramServerSocket();
		attempt.server.bind(0, "127.0.0.1");
		attempt.server.encryptionKeyFor = (_, _, _) -> serverKey;
		attempt.server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, _ -> attempt.accepted++);
		attempt.server.listen();
		attempt.client = new ReliableDatagramSocket();
		attempt.client.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> attempt.error = e.text);
		attempt.client.addEventListener(Event.CLOSE, _ -> attempt.closed = true);
		attempt.client.addEventListener(Event.CONNECT, _ -> attempt.connected = true);
		if (clientKey != null) {
			attempt.client.encryptionKey = clientKey;
		}
		var started:Float = haxe.Timer.stamp();
		attempt.client.connect("127.0.0.1", attempt.server.localPort);
		Pair.pumpUntil(() -> attempt.closed, 5.0);
		attempt.took = haxe.Timer.stamp() - started;
		Pair.pumpUntil(() -> false, 0.1);
		return attempt;
	}

	public function close():Void {
		try client.abort() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}
}

/**
	A path between a client and a server, for the tests: what the client
	sends to `port` goes on to the server from one socket, and what comes
	back goes back to the client. Records every datagram each way (`out`,
	`back`), and can lose a share from a fixed sequence, swap neighbours,
	change one before it goes, or send one of its own either way.
**/
private class Wire {
	public var port(get, never):Int;
	public var outsidePort(get, never):Int;
	public var out:Array<Bytes> = [];
	public var back:Array<Bytes> = [];
	public var loss:Float = 0;
	public var reorder:Bool = false;
	public var dropped:Int = 0;
	public var change:Null<(Bytes, Bool) -> Void> = null;
	public var hold:Bool = false;
	public var held:Array<Bytes> = [];

	var inside:DatagramSocket;
	var outside:DatagramSocket;
	var outsides:Array<DatagramSocket> = [];
	var serverPort:Int;
	var clientPort:Int = 0;
	var random:Int = 4242;
	var pendingOut:Null<Bytes> = null;
	var pendingBack:Null<Bytes> = null;
	var pendingOutAt:Float = 0;
	var pendingBackAt:Float = 0;

	// Every wire open, so the pump can let go of what one holds.
	static var open:Array<Wire> = [];

	/** A datagram held for one to follow it goes alone after 10 ms: reordered, not held until something else is sent. **/
	public static function tickAll():Void {
		var now:Float = haxe.Timer.stamp();
		for (wire in open) {
			if (wire.pendingOut != null && now - wire.pendingOutAt > 0.01) {
				var held = wire.pendingOut;
				wire.pendingOut = null;
				wire.send(held, true);
			}
			if (wire.pendingBack != null && now - wire.pendingBackAt > 0.01) {
				var held = wire.pendingBack;
				wire.pendingBack = null;
				wire.send(held, false);
			}
		}
	}

	public function new(serverPort:Int) {
		this.serverPort = serverPort;
		inside = new DatagramSocket();
		inside.bind(0, "127.0.0.1");
		inside.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			clientPort = e.srcPort;
			forward(copy(e.data), true);
		});
		inside.receive();
		remap();
		open.push(this);
	}

	/** A new outside port for the client, from now on, as a NAT that remaps does; the old one forwards nothing more. **/
	public function remap():Void {
		var socket = new DatagramSocket();
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			if (socket == outside) {
				forward(copy(e.data), false);
			}
		});
		socket.receive();
		outsides.push(socket);
		outside = socket;
	}

	function forward(data:Bytes, up:Bool):Void {
		(up ? out : back).push(data);
		if (lost()) {
			dropped++;
			return;
		}
		if (change != null) {
			change(data, up);
		}
		if (hold && up) {
			held.push(data);
			return;
		}
		if (reorder) {
			// Each datagram waits for the next, which goes first.
			var pending:Null<Bytes> = up ? pendingOut : pendingBack;
			if (pending == null) {
				if (up) {
					pendingOut = data;
					pendingOutAt = haxe.Timer.stamp();
				} else {
					pendingBack = data;
					pendingBackAt = haxe.Timer.stamp();
				}
				return;
			}
			if (up) pendingOut = null else pendingBack = null;
			send(data, up);
			send(pending, up);
			return;
		}
		send(data, up);
	}

	public function send(data:Bytes, up:Bool):Void {
		var bytes = ByteArray.fromBytes(data);
		if (up) {
			outside.send(bytes, 0, data.length, "127.0.0.1", serverPort);
		} else if (clientPort != 0) {
			inside.send(bytes, 0, data.length, "127.0.0.1", clientPort);
		}
	}

	/** A datagram of the test's own to the client, as though from the server. **/
	public function toClient(data:ByteArray):Void {
		send(copy(data), false);
	}

	/** And to the server, as though from the client. **/
	public function toServer(data:ByteArray):Void {
		send(copy(data), true);
	}

	public static function copy(data:ByteArray):Bytes {
		var out = Bytes.alloc(data.length);
		out.blit(0, data, 0, data.length);
		return out;
	}

	public function close():Void {
		open.remove(this);
		try inside.close() catch (_:Dynamic) {}
		for (socket in outsides) {
			try socket.close() catch (_:Dynamic) {}
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
		return outside.localPort;
	}
}

/**
	A server from before encryption, written by hand: it answers every
	CONNECT with a HANDSHAKE in the clear, echoing the connection id as a
	1.0 server does, and counts what else it is sent.
**/
private class OldServer {
	public var port(get, never):Int;
	public var connects:Int = 0;
	public var others:Int = 0;

	var socket:DatagramSocket;

	public function new() {
		socket = new DatagramSocket();
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			var frame = ReliableDatagramProtocol.decode(e.data);
			if (frame == null || frame.type != CONNECT) {
				others++;
				return;
			}
			connects++;
			var payload = new ByteArray();
			payload.length = ReliableDatagramProtocol.HANDSHAKE_PAYLOAD_SIZE;
			var bytes:Bytes = payload;
			var id:Int = frame.sequence;
			bytes.set(0, id >>> 24);
			bytes.set(1, (id >>> 16) & 0xFF);
			bytes.set(2, (id >>> 8) & 0xFF);
			bytes.set(3, id & 0xFF);
			var answer = ReliableDatagramProtocol.encode(HANDSHAKE, 1000, payload);
			socket.send(answer, 0, answer.length, e.srcAddress, e.srcPort);
		});
		socket.receive();
	}

	public function close():Void {
		try socket.close() catch (_:Dynamic) {}
	}

	function get_port():Int {
		return socket.localPort;
	}
}

/** A socket of the test's own: sends what it is given, and keeps every datagram that comes back. **/
private class RawPeer {
	public var got:Array<Bytes> = [];

	var socket:DatagramSocket;

	public function new() {
		socket = new DatagramSocket();
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, (e:DatagramSocketDataEvent) -> got.push(Wire.copy(e.data)));
		socket.receive();
	}

	public function send(data:ByteArray, port:Int):Void {
		socket.send(data, 0, data.length, "127.0.0.1", port);
	}

	public function close():Void {
		try socket.close() catch (_:Dynamic) {}
	}
}
