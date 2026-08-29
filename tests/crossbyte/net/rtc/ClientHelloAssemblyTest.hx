package crossbyte.net.rtc;

import crossbyte.net.rtc._internal.ClientHelloAssembly;
import haxe.io.Bytes;
import utest.Assert;

/**
	Putting a ClientHello back together after a browser sent it in pieces.

	Bytes in and bytes out, so it runs on every target even though only a native
	one has DTLS underneath. The geometry in these cases is the geometry that
	actually broke: a 1413 byte message split at 1175, which is what Chrome sent
	and what mbedtls refused with "bad client hello message: 1187 != 12 + 1413".

	The live proof that this shape is real is `ci/interop/run.js`, which runs a
	genuine `RTCPeerConnection` against this stack. It needs a browser and does
	not run here, so these cases hold the same ground without one.
**/
class ClientHelloAssemblyTest extends utest.Test {
	static inline var RECORD_HEADER:Int = 13;
	static inline var HANDSHAKE_HEADER:Int = 12;

	/** What Chrome sent: one message, two datagrams, neither usable alone. **/
	public function testTwoFragmentsBecomeTheMessageThatWasSent():Void {
		var message = counting(1413);
		var assembly = new ClientHelloAssembly();

		Assert.isNull(assembly.accept(fragment(message, 0, 1175, 0)));

		var whole = assembly.accept(fragment(message, 1175, 238, 0));

		Assert.notNull(whole);

		if (whole == null) {
			return;
		}

		Assert.equals(RECORD_HEADER + HANDSHAKE_HEADER + 1413, whole.length);
		Assert.equals(0, Bytes.ofData(message.getData()).compare(whole.sub(RECORD_HEADER + HANDSHAKE_HEADER, 1413)));
	}

	/**
		The rebuilt message says it was never fragmented.

		Not cosmetic. RFC 6347 has the handshake hash computed as though every
		message arrived in one piece, so a reassembly that kept the last
		fragment's offset and length would hand mbedtls a transcript the peer's
		Finished disagrees with -- and the handshake would fail several flights
		later, for a reason pointing nowhere near here.
	**/
	public function testTheRebuiltMessageLooksUnfragmented():Void {
		var assembly = new ClientHelloAssembly();
		var message = counting(1413);

		assembly.accept(fragment(message, 0, 1175, 7));

		var whole = assembly.accept(fragment(message, 1175, 238, 7));

		Assert.notNull(whole);

		if (whole == null) {
			return;
		}

		var body = RECORD_HEADER;

		Assert.equals(1, whole.get(body));
		Assert.equals(1413, uint24(whole, body + 1));
		// The message sequence is the peer's and has to survive: mbedtls copies
		// it and answers with the next one.
		Assert.equals(7, (whole.get(body + 4) << 8) | whole.get(body + 5));
		Assert.equals(0, uint24(whole, body + 6));
		Assert.equals(1413, uint24(whole, body + 9));

		// And the record's own length field covers the whole message.
		Assert.equals(HANDSHAKE_HEADER + 1413, (whole.get(11) << 8) | whole.get(12));
	}

	/** Datagrams reorder. The last gap to close is what completes the message. **/
	public function testFragmentsArrivingOutOfOrderStillAssemble():Void {
		var message = counting(900);
		var assembly = new ClientHelloAssembly();

		Assert.isNull(assembly.accept(fragment(message, 600, 300, 0)));
		Assert.isNull(assembly.accept(fragment(message, 0, 200, 0)));

		var whole = assembly.accept(fragment(message, 200, 400, 0));

		Assert.notNull(whole);

		if (whole == null) {
			return;
		}

		Assert.equals(0, Bytes.ofData(message.getData()).compare(whole.sub(RECORD_HEADER + HANDSHAKE_HEADER, 900)));
	}

	/**
		A retransmitted flight does not look like progress.

		DTLS retransmits on a timer, so the same fragment arrives more than
		once. Counting bytes rather than tracking which ones arrived would call
		a message complete after enough duplicates and hand mbedtls a buffer
		with a hole in it -- which parses, because the hole is zeroes.
	**/
	public function testARepeatedFragmentDoesNotCompleteTheMessage():Void {
		var message = counting(900);
		var assembly = new ClientHelloAssembly();

		Assert.isNull(assembly.accept(fragment(message, 0, 450, 0)));
		Assert.isNull(assembly.accept(fragment(message, 0, 450, 0)));
		Assert.isNull(assembly.accept(fragment(message, 0, 450, 0)));

		Assert.notNull(assembly.accept(fragment(message, 450, 450, 0)));
	}

	/** Fragments may overlap; a peer is free to re-split on retransmission. **/
	public function testOverlappingFragmentsMerge():Void {
		var message = counting(500);
		var assembly = new ClientHelloAssembly();

		Assert.isNull(assembly.accept(fragment(message, 0, 300, 0)));
		Assert.isNull(assembly.accept(fragment(message, 200, 200, 0)));

		var whole = assembly.accept(fragment(message, 350, 150, 0));

		Assert.notNull(whole);

		if (whole == null) {
			return;
		}

		Assert.equals(0, Bytes.ofData(message.getData()).compare(whole.sub(RECORD_HEADER + HANDSHAKE_HEADER, 500)));
	}

	/**
		A ClientHello that fits is handed on untouched.

		The same object, not a copy that happens to match: every handshake
		mbedtls could already complete on its own should not start going through
		a reassembler on the way.
	**/
	public function testAnUnfragmentedClientHelloIsNotTouched():Void {
		var assembly = new ClientHelloAssembly();
		var datagram = fragment(counting(200), 0, 200, 0);

		Assert.isTrue(datagram == assembly.accept(datagram));
	}

	/**
		So is everything that is not a ClientHello.

		Encrypted records are the reason this matters. Their bytes at these
		offsets are ciphertext, which will occasionally read as a handshake
		type, a plausible length and an offset -- so the epoch is checked, and
		a record at any epoch above zero is left alone whatever it looks like.
	**/
	public function testRecordsThatAreNotAClientHelloPassThrough():Void {
		var assembly = new ClientHelloAssembly();

		var applicationData = fragment(counting(400), 0, 200, 0);
		applicationData.set(0, 23);
		Assert.isTrue(applicationData == assembly.accept(applicationData));

		// A handshake record at epoch 1: encrypted, and not to be read.
		var encrypted = fragment(counting(400), 0, 200, 0);
		encrypted.set(4, 1);
		Assert.isTrue(encrypted == assembly.accept(encrypted));

		// A handshake message that is not a ClientHello.
		var other = fragment(counting(400), 0, 200, 0);
		other.set(RECORD_HEADER, 2);
		Assert.isTrue(other == assembly.accept(other));
	}

	/**
		A declared length nothing could use is refused before it is allocated.

		Three bytes of length means a peer can claim sixteen megabytes in a
		datagram of two hundred, and a reassembler that believes it has spent
		sixteen megabytes on the strength of one unauthenticated packet -- once
		per packet, from anyone who can reach the port.
	**/
	public function testAnImpossibleLengthIsRefused():Void {
		var assembly = new ClientHelloAssembly();
		var datagram = fragment(counting(400), 0, 200, 0);

		// Rewrite the message length to something past the cap, leaving this a
		// first fragment of a message far larger than any record could hold.
		datagram.set(RECORD_HEADER + 1, 0xFF);
		datagram.set(RECORD_HEADER + 2, 0xFF);
		datagram.set(RECORD_HEADER + 3, 0xFF);

		Assert.isNull(assembly.accept(datagram));

		// Which on its own proves nothing: a reassembler that believed the
		// length would also return null here, having first set aside sixteen
		// megabytes to wait in. What separates the two is whether anything was
		// kept at all.
		Assert.equals(0, assembly.pending);
	}

	/**
		A peer that starts over abandons what was collected for the old one.

		The halves here are chosen so that keeping them would be invisible in
		the result and fatal anyway: the first message covers the front of the
		buffer and the second sends only its back, so an assembly that did not
		start over would find every byte accounted for, call the message
		complete a flight early, and hand mbedtls a ClientHello whose first four
		hundred bytes came from a message the peer has abandoned.
	**/
	public function testANewMessageReplacesAPartialOne():Void {
		var assembly = new ClientHelloAssembly();
		var abandoned = counting(600);

		Assert.isNull(assembly.accept(fragment(abandoned, 0, 400, 0)));

		var second = differentBytes(600);

		Assert.isNull(assembly.accept(fragment(second, 400, 200, 1)));

		var whole = assembly.accept(fragment(second, 0, 400, 1));

		Assert.notNull(whole);

		if (whole == null) {
			return;
		}

		Assert.equals(0, second.compare(whole.sub(RECORD_HEADER + HANDSHAKE_HEADER, 600)));
	}

	/**
		A datagram may hold several records, and only the fragment is held back.

		DTLS allows records to be packed together, so a fragment can share a
		datagram with something that has nothing to wait for. Holding the whole
		datagram until the ClientHello completed would delay records that were
		ready, and dropping them would lose them.
	**/
	public function testOtherRecordsInTheSameDatagramAreStillDelivered():Void {
		var assembly = new ClientHelloAssembly();

		var alert = Bytes.alloc(RECORD_HEADER + 2);
		alert.set(0, 21);
		alert.set(1, 0xFE);
		alert.set(2, 0xFD);
		alert.set(12, 2);

		var piece = fragment(counting(900), 0, 450, 0);
		var packed = Bytes.alloc(piece.length + alert.length);
		packed.blit(0, piece, 0, piece.length);
		packed.blit(piece.length, alert, 0, alert.length);

		var passed = assembly.accept(packed);

		Assert.notNull(passed);

		if (passed == null) {
			return;
		}

		// The alert alone: the fragment was absorbed, and nothing else was.
		Assert.equals(alert.length, passed.length);
		Assert.equals(0, alert.compare(passed));
	}

	// ------------------------------------------------------------------

	/** One DTLS record carrying one fragment of a ClientHello. **/
	static function fragment(message:Bytes, offset:Int, length:Int, sequence:Int):Bytes {
		var datagram = Bytes.alloc(RECORD_HEADER + HANDSHAKE_HEADER + length);

		datagram.set(0, 22);
		datagram.set(1, 0xFE);
		datagram.set(2, 0xFD);
		// Epoch 0; the record sequence number is left at zero, which no part of
		// reassembly reads.
		datagram.set(11, ((HANDSHAKE_HEADER + length) >> 8) & 0xFF);
		datagram.set(12, (HANDSHAKE_HEADER + length) & 0xFF);

		var body = RECORD_HEADER;
		datagram.set(body, 1);
		writeUint24(datagram, body + 1, message.length);
		datagram.set(body + 4, (sequence >> 8) & 0xFF);
		datagram.set(body + 5, sequence & 0xFF);
		writeUint24(datagram, body + 6, offset);
		writeUint24(datagram, body + 9, length);
		datagram.blit(body + HANDSHAKE_HEADER, message, offset, length);

		return datagram;
	}

	/** Distinguishable bytes, so a fragment landing at the wrong offset shows. **/
	static function counting(length:Int):Bytes {
		var bytes = Bytes.alloc(length);

		for (i in 0...length) {
			bytes.set(i, (i * 31 + 7) & 0xFF);
		}

		return bytes;
	}

	/** Distinguishable from `counting`, so bytes from the wrong message show. **/
	static function differentBytes(length:Int):Bytes {
		var bytes = Bytes.alloc(length);

		for (i in 0...length) {
			bytes.set(i, (i * 17 + 200) & 0xFF);
		}

		return bytes;
	}

	static function uint24(bytes:Bytes, at:Int):Int {
		return (bytes.get(at) << 16) | (bytes.get(at + 1) << 8) | bytes.get(at + 2);
	}

	static function writeUint24(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, (value >> 16) & 0xFF);
		bytes.set(at + 1, (value >> 8) & 0xFF);
		bytes.set(at + 2, value & 0xFF);
	}
}
