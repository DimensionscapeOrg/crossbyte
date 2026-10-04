package crossbyte.net.rtc;

import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import utest.Assert;
import crossbyte.test.Require;
#if cpp
import crossbyte.net.rtc._internal.NativeDtlsSession;
#end

/**
	Two DTLS sessions handed each other's datagrams, with no network between
	them.

	The transport owns no socket for the same reason the ICE agent does not,
	the one it would want is already carrying connectivity checks, and the
	same benefit follows: a real handshake, retransmission timers and all, runs
	to completion here deterministically.

	Native only, because mbedTLS is. Elsewhere these assert that it says so.
**/
class DtlsTransportTest extends utest.Test {
	private function unsupported():Bool {
		if (!DtlsTransport.isSupported) {
			Assert.isFalse(DtlsTransport.isSupported);
			return true;
		}

		return false;
	}

	public function testSupportIsReportedHonestly():Void {
		if (!DtlsCertificate.isSupported) {
			Assert.isFalse(DtlsTransport.isSupported, "a transport claimed support on a target with no certificates to run it with");
			return;
		}

		Assert.isTrue(DtlsTransport.isSupported);
	}

	/**
		An established session with nothing to do costs nothing to poll.

		Nothing in an established session runs on a timer: records are read as
		they arrive and written as they are sent. It was stepped every tick
		regardless, three native calls per idle peer, finding nothing each
		time. Counted rather than timed: the steps are what cost.
	**/
	public function testAnIdleEstablishedSessionIsNotStepped():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var heard:String = null;

		pair.server.onMessage = function(payload) {
			payload.position = 0;
			heard = payload.readUTFBytes(payload.length);
		};

		if (!pair.run(() -> pair.client.connected && pair.server.connected)) {
			Assert.fail("the DTLS handshake never completed");
			pair.close();
			return;
		}

		#if cpp
		var before:Int = @:privateAccess pair.client.__steps + @:privateAccess pair.server.__steps;

		for (i in 0...100) {
			pair.client.poll(1000 + i);
			pair.server.poll(1000 + i);
		}

		Assert.equals(before, @:privateAccess pair.client.__steps + @:privateAccess pair.server.__steps,
			"polling an idle established session stepped it");
		#end

		// And it still carries what is sent, because arrival is what reads it.
		pair.client.send(text("still here"));
		pair.run(() -> heard != null);
		Assert.equals("still here", heard);

		pair.close();
	}

	/**
		A handshake between two peers who each know only the other's
		fingerprint.

		This is the whole arrangement WebRTC uses in place of a certificate
		authority, and it either works end to end or it does not.
	**/
	public function testTwoPeersHandshakeAndCarryData():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var delivered:String = null;
		var back:String = null;

		pair.server.onMessage = function(payload) {
			payload.position = 0;
			delivered = payload.readUTFBytes(payload.length);
		};

		pair.client.onMessage = function(payload) {
			payload.position = 0;
			back = payload.readUTFBytes(payload.length);
		};

		Assert.isTrue(pair.run(() -> pair.client.connected && pair.server.connected), "the DTLS handshake never completed");

		pair.client.send(text("from the client"));
		pair.run(() -> delivered != null);
		Assert.equals("from the client", delivered);

		pair.server.send(text("from the server"));
		pair.run(() -> back != null);
		Assert.equals("from the server", back, "the session carried data one way only");

		pair.close();
	}

	/**
		Records reach `onMessage` in the transport's own payload, read into
		again for each: each is right in its call, one read inside the call
		gets a payload of its own, a payload kept past its call is what each
		mode says, and a listener that throws leaves the next right.
	**/
	public function testEachRecordIsRightInWhatTheTransportHandsOutAgain():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var heard:Array<String> = [];
		var kept:Array<ByteArray> = [];
		var outerAfter:String = null;
		pair.server.onMessage = function(payload:ByteArray) {
			kept.push(payload);
			var said:String = payload.readUTFBytes(payload.length);
			heard.push(said);
			if (said == "outer") {
				// The next record is read while this one is being handled.
				pair.client.send(text("nested, and longer"));
				pair.deliverToServer();
				payload.position = 0;
				outerAfter = payload.readUTFBytes(payload.length);
			} else if (said == "throws") {
				throw "a listener's own failure";
			}
		};

		Assert.isTrue(pair.run(() -> pair.client.connected && pair.server.connected), "the DTLS handshake never completed");
		for (message in ["first", "second, longer", "outer"]) {
			pair.client.send(text(message));
			pair.run(() -> heard.indexOf(message) >= 0);
		}
		pair.client.send(text("throws"));
		var thrown:Dynamic = null;
		try {
			pair.run(() -> heard.indexOf("throws") >= 0);
		} catch (e:Dynamic) {
			thrown = e;
		}
		pair.client.send(text("after the throw"));
		pair.run(() -> heard.indexOf("after the throw") >= 0);

		Assert.same(["first", "second, longer", "outer", "nested, and longer", "throws", "after the throw"], heard);
		Assert.equals("outer", outerAfter, "a record read inside onMessage changed the one it was handling");
		Assert.equals("a listener's own failure", Std.string(thrown), "onMessage's throw did not come back out");
		if (kept.length == 6) {
			Assert.isTrue(kept[3] != kept[2], "a record read inside onMessage was handed the payload still out");
			#if cpp
			Assert.isFalse(@:privateAccess pair.server.__arrivalOut, "something was left out after its call");
			#end
			#if crossbyte_check_events
			Assert.equals(0, kept[0].length, "a payload kept past its call was left alive");
			#elseif crossbyte_fresh_events
			Assert.equals("first", kept[0].toString());
			#else
			Assert.isTrue(kept[0] == kept[1] && kept[1] == kept[2] && kept[2] == kept[4] && kept[4] == kept[5], "the transport's payload was not read into again");
			Assert.equals(0, kept[0].length, "a payload kept past its call still read whole");
			#end
		}
		pair.close();
	}

	/**
		Red team. Each record reaches `onMessage` in the byte order a
		`ByteArray` made for it has, `ByteArray.defaultEndian`, as it did when
		each had one of its own. The transport's one payload is read into
		again for each, and its `endian` was never set again: a handler that
		read one record big-endian left every record after it big-endian.
	**/
	public function testEachRecordStartsInTheDefaultByteOrder():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var orders:Array<String> = [];
		var values:Array<Int> = [];
		pair.server.onMessage = function(payload:ByteArray) {
			orders.push(payload.endian);
			if (orders.length == 1) {
				payload.endian = crossbyte.io.Endian.BIG_ENDIAN;
			}
			values.push(payload.readUnsignedShort());
		};

		Assert.isTrue(pair.run(() -> pair.client.connected && pair.server.connected), "the DTLS handshake never completed");
		// The same two bytes in each: 0x01 then 0x02.
		pair.client.send(text("\x01\x02 first"));
		pair.run(() -> orders.length >= 1);
		pair.client.send(text("\x01\x02 second"));
		pair.run(() -> orders.length >= 2);

		var standard:String = ByteArray.defaultEndian;
		var swapped:Int = standard == crossbyte.io.Endian.BIG_ENDIAN ? 0x0102 : 0x0201;
		Assert.same([standard, standard], orders, "a record did not start in the default byte order: " + orders.join(", "));
		Assert.same([0x0102, swapped], values, "the second record was read in the byte order the first one's handler chose: " + values.join(", "));
		pair.close();
	}

	/**
		Closing before it completes tells whoever was waiting.

		Every path that settled this future ran from the handshake, and closing
		is what stops the handshake, so a caller that closed mid-negotiation
		was left holding a future that could not settle either way. The same gap
		existed in every class in this stack that hands one out.
	**/
	public function testClosingBeforeTheHandshakeCompletesTellsWhoeverWaited():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var secured:Bool = false;
		var failure:String = null;
		pair.client.established.then(_ -> secured = true, error -> failure = error);

		pair.client.close();

		Assert.isFalse(secured, "a closed session reported a completed handshake");
		Assert.notNull(failure, "closing left `established` pending forever");
	}

	/**
		A peer that closes its session is heard, and its last words are not lost.

		mbedtls reported the peer's close_notify and this transport went on as
		though nothing had happened: `connected` stayed true, `send` kept
		encrypting into a session nobody was reading, and nothing above it
		could tell a peer that said goodbye from one that had merely gone
		quiet. The one sign it gave was an internal state nothing read.
	**/
	public function testThePeerClosingTheSessionIsReported():Void {
		if (unsupported()) return;

		var pair = Pair.make();
		var heard:Array<String> = [];
		var reasons:Array<String> = [];

		pair.server.onMessage = function(payload) {
			payload.position = 0;
			heard.push(payload.readUTFBytes(payload.length));
		};

		pair.server.onClose = reason -> reasons.push(reason);

		if (!pair.run(() -> pair.client.connected && pair.server.connected)) {
			Assert.fail("the DTLS handshake never completed");
			pair.close();
			return;
		}

		// A message and then the goodbye, in one flight: both are meant.
		pair.client.send(text("last words"));
		pair.client.close();

		pair.run(() -> reasons.length > 0);

		Assert.equals(1, reasons.length, "the peer's close_notify was reported " + reasons.length + " times rather than once");
		Assert.isFalse(pair.server.connected, "a session the peer closed still reports itself connected");
		Assert.equals("last words", heard.length > 0 ? heard[0] : null, "the message sent before the close_notify was lost");

		if (reasons.length > 0) {
			Assert.isTrue(reasons[0].indexOf("closed") >= 0, "the reason does not say the peer closed the session: " + reasons[0]);
		}

		Assert.raises(() -> pair.server.send(text("into the void")), ArgumentError);

		pair.close();
	}

	/**
		Closing without telling the peer sends nothing.

		For a path already known to be dead, consent expired, where RFC
		7675 asks the sender to stop transmitting, goodbyes included.
	**/
	public function testClosingQuietlySendsNothing():Void {
		if (unsupported()) return;

		var pair = Pair.make();

		if (!pair.run(() -> pair.client.connected && pair.server.connected)) {
			Assert.fail("the DTLS handshake never completed");
			pair.close();
			return;
		}

		var sent:Int = 0;
		pair.client.onSend = _ -> sent++;
		pair.client.close(false);

		Assert.equals(0, sent, "a close that was not to notify the peer sent " + sent + " datagrams");

		// And the default does send one, or the case above proves nothing.
		var other = Pair.make();

		if (!other.run(() -> other.client.connected && other.server.connected)) {
			Assert.fail("the DTLS handshake never completed");
			pair.close();
			other.close();
			return;
		}

		var notified:Int = 0;
		other.client.onSend = _ -> notified++;
		other.client.close();

		Assert.isTrue(notified > 0, "closing sent the peer no close_notify");

		pair.close();
		other.close();
	}

	/**
		A client whose ClientHello nobody answers gives up in seconds.

		mbedtls's own schedule resends a flight after one second and doubles to
		a minute, failing after 123 seconds, two minutes of a session, and the
		socket and listener above it, held for a peer that was never there.
		Resent at one, two, four and eight seconds now, and given up on at
		fifteen.
	**/
	public function testAHandshakeNobodyAnswersIsGivenUpInSeconds():Void {
		if (unsupported()) return;

		var client = new DtlsTransport(DtlsCertificate.generate("client", 30), DtlsCertificate.generate("server", 30).fingerprint, true);
		var sent:Int = 0;
		client.onSend = _ -> sent++;

		var failure:String = null;
		var failedAt:Float = -1;
		var now:Float = 0;
		client.established.then(_ -> {}, function(error:String):Void {
			failure = error;
			failedAt = now;
		});

		while (failure == null && now < 200) {
			client.poll(now);
			now += 0.1;
		}

		Assert.notNull(failure, "a handshake nobody answered never failed");
		Assert.isTrue(failedAt >= 0 && failedAt <= 20, "a handshake nobody answered took " + failedAt + " s to fail");
		Assert.isTrue(sent >= 4, "the ClientHello was sent " + sent + " times before giving up");

		if (failure != null) {
			Assert.isTrue(failure.indexOf("timed out") >= 0, "the failure does not say the handshake timed out: " + failure);
		}

		client.close();
	}

	/**
		Sessions opened, used and closed on several threads at once stay
		separate.

		Every session lives in one process-wide table, keyed by a handle from
		one process-wide counter, and neither was guarded: peers on two child
		runtimes inserted into, erased from and searched the same map at the
		same moment. A lookup that lands mid-rebalance follows a stale node,
		a live handle reads as gone, or a closed one as live, and two opens
		that race on the counter get the same handle, so each then drives the
		other's session.
	**/
	public function testSessionsOnSeveralThreadsStaySeparate():Void {
		#if cpp
		if (unsupported()) return;

		var certificate = DtlsCertificate.generate("threads", 1);
		var threads:Int = 4;
		var rounds:Int = 400;
		var results = new sys.thread.Deque<String>();

		for (t in 0...threads) {
			sys.thread.Thread.create(function():Void {
				var problem:String = null;

				try {
					for (round in 0...rounds) {
						var handle:Int = NativeDtlsSession.open(((t + round) & 1) == 0, certificate.certificatePem, certificate.privateKeyPem);

						if (handle <= 0) {
							problem = "a session would not open: " + handle;
							break;
						}

						// Looked up over and over while the other threads insert
						// and erase around it.
						for (_ in 0...500) {
							if (NativeDtlsSession.error(handle) != 0) {
								problem = "a live session's handle stopped finding it";
								break;
							}
						}

						NativeDtlsSession.close(handle);

						if (problem == null && NativeDtlsSession.error(handle) == 0) {
							problem = "a closed session's handle still found one";
						}

						if (problem != null) {
							break;
						}
					}
				} catch (e:Dynamic) {
					problem = Std.string(e);
				}

				results.add(problem == null ? "" : problem);
			});
		}

		var problems:Array<String> = [];

		for (_ in 0...threads) {
			var problem:String = results.pop(true);

			if (problem != "") {
				problems.push(problem);
			}
		}

		Assert.equals(0, problems.length, problems.join("; "));
		#else
		Assert.isFalse(DtlsTransport.isSupported);
		#end
	}

	/**
		The case the fingerprint exists for.

		An attacker who can answer gets a perfectly good DTLS handshake, the
		cryptography is not what identifies the peer here, because there is no
		authority to appeal to. What identifies it is that the certificate
		presented hashes to what arrived over signalling. So this hands a peer a
		certificate that is not the one that was promised, and requires that the
		session is refused *after* the handshake succeeds.
	**/
	public function testAHandshakeWithTheWrongCertificateIsRefused():Void {
		if (unsupported()) return;

		var impostor = DtlsCertificate.generate("impostor", 30);
		var pair = Pair.make(impostor);
		var failure:String = null;

		pair.client.established.then(_ -> {}, error -> failure = error);
		pair.run(() -> failure != null);

		Require.notNull(failure, "a certificate that was not the one signalled was accepted");
		Assert.isFalse(pair.client.connected, "the transport reported itself connected to the wrong peer");
		Assert.isTrue(failure.indexOf("fingerprint") >= 0, "the refusal does not say what was wrong: " + failure);

		pair.close();
	}

	/**
		There is no way to build one of these that skips the check.

		Making the fingerprint a constructor argument is deliberate: an
		implementation that lets it be supplied later has a window in which the
		session is established and unverified, and something will eventually use
		it in that window.
	**/
	public function testATransportCannotBeBuiltWithoutAFingerprint():Void {
		if (!DtlsCertificate.isSupported) {
			Assert.raises(() -> new DtlsTransport(null, "AA:BB", true), ArgumentError);
			return;
		}

		var certificate = DtlsCertificate.generate("crossbyte-test", 30);

		Assert.raises(() -> new DtlsTransport(certificate, null, true), ArgumentError);
		Assert.raises(() -> new DtlsTransport(certificate, "", true), ArgumentError);
		Assert.raises(() -> new DtlsTransport(null, certificate.fingerprint, true), ArgumentError);
	}

	/**
		One socket, several protocols, told apart by the first byte.

		RFC 7983 is what lets ICE checks and an encrypted session share a port:
		below 2 is STUN, 20 to 63 is DTLS. A transport that took everything
		would swallow the connectivity checks still keeping the path alive.
	**/
	public function testTrafficThatIsNotDtlsIsLeftAlone():Void {
		var stun = new ByteArray();
		stun.writeByte(0x00);
		stun.writeByte(0x01);
		stun.position = 0;
		Assert.isFalse(DtlsTransport.looksLikeDtls(stun), "a STUN binding request was taken for DTLS");

		var media = new ByteArray();
		media.writeByte(0x80);
		media.position = 0;
		Assert.isFalse(DtlsTransport.looksLikeDtls(media));

		var handshake = new ByteArray();
		handshake.writeByte(22);
		handshake.position = 0;
		Assert.isTrue(DtlsTransport.looksLikeDtls(handshake), "a DTLS handshake record was not recognised");

		Assert.isFalse(DtlsTransport.looksLikeDtls(null));
		Assert.isFalse(DtlsTransport.looksLikeDtls(new ByteArray()));
	}

	/**
		Sending before the session exists is refused rather than guessed at.

		The alternatives are to drop the message or to buffer it, and a
		transport that quietly does one where the caller assumed the other is
		worse than one that says no.
	**/
	public function testSendingBeforeTheHandshakeIsRefused():Void {
		if (unsupported()) return;

		var pair = Pair.make();

		Assert.raises(() -> pair.client.send(text("too early")), ArgumentError);

		pair.close();
	}

	private static function text(value:String):ByteArray {
		var out = new ByteArray();
		out.writeUTFBytes(value);
		out.position = 0;
		return out;
	}
}

/** A client and a server, and the queues that stand in for a network. **/
private class Pair {
	public var client:DtlsTransport;
	public var server:DtlsTransport;

	private var toServer:Array<ByteArray> = [];
	private var toClient:Array<ByteArray> = [];
	private var now:Float = 0;

	/**
		@param serverCertificate A certificate for the server that is *not* the
		one the client was told to expect, for the case that matters.
	**/
	public static function make(?serverCertificate:DtlsCertificate):Pair {
		var clientCertificate = DtlsCertificate.generate("client", 30);
		var promised = DtlsCertificate.generate("server", 30);
		var presented = serverCertificate != null ? serverCertificate : promised;

		var pair = new Pair();
		pair.client = new DtlsTransport(clientCertificate, promised.fingerprint, true);
		pair.server = new DtlsTransport(presented, clientCertificate.fingerprint, false);

		pair.client.onSend = payload -> pair.toServer.push(payload);
		pair.server.onSend = payload -> pair.toClient.push(payload);

		return pair;
	}

	private function new() {}

	public function run(done:Void->Bool):Bool {
		for (_ in 0...400) {
			client.poll(now);
			server.poll(now);

			var outbound = toServer;
			toServer = [];

			for (payload in outbound) {
				server.receive(payload, now);
			}

			var inbound = toClient;
			toClient = [];

			for (payload in inbound) {
				client.receive(payload, now);
			}

			if (done()) {
				return true;
			}

			now += 0.02;
		}

		return done();
	}

	/** What the client has sent, to the server now, without moving time. **/
	public function deliverToServer():Void {
		var outbound = toServer;
		toServer = [];
		for (payload in outbound) {
			server.receive(payload, now);
		}
	}

	public function close():Void {
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}
}
