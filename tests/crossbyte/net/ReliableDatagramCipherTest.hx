package crossbyte.net;

import crossbyte.net._internal.reliable.ChaCha20Poly1305;
import crossbyte.net._internal.reliable.SessionCipher;
import haxe.io.Bytes;
import utest.Assert;

/**
	The cipher an encrypted reliable UDP session seals its datagrams with
	(`SessionCipher`), and the ChaCha20-Poly1305 it falls back to where the
	target has none of its own (`ChaCha20Poly1305`).

	Every expected byte here comes from somewhere else: RFC 8439's own
	vectors, and Node's `crypto` (OpenSSL) for the rest, `export`-free
	scripts that make each input from the formula `fill` repeats. The sealed
	datagrams are computed there end to end (HKDF with Node's HMAC, then the
	AEAD), so a target that produces them here interoperates byte for byte
	with every other: libsodium natively, Node's `crypto` on Node, and this
	package's own code on the jvm and the browser.
**/
@:access(crossbyte.net._internal.reliable.SessionCipher)
class ReliableDatagramCipherTest extends utest.Test {
	/** RFC 8439 2.3.2: the ChaCha20 block function. **/
	public function testTheChaChaBlockIsRfc8439s():Void {
		var key = Bytes.alloc(32);
		for (i in 0...32) {
			key.set(i, i);
		}
		Assert.equals("10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e",
			ChaCha20Poly1305.block(key, 1, Bytes.ofHex("000000090000004a00000000")).toHex());
	}

	/** RFC 8439 2.5.2: Poly1305, with a last block shorter than sixteen bytes. **/
	public function testPoly1305IsRfc8439s():Void {
		var key = Bytes.ofHex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b");
		Assert.equals("a8061dc1305136c6c22b8baf0c0127a9", ChaCha20Poly1305.poly1305(key, Bytes.ofString("Cryptographic Forum Research Group")).toHex());
	}

	/** RFC 8439 2.8.2: the AEAD, sealed and opened. **/
	public function testTheAeadIsRfc8439s():Void {
		var key = Bytes.ofHex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
		var nonce = Bytes.ofHex("070000004041424344454647");
		var aad = Bytes.ofHex("50515253c0c1c2c3c4c5c6c7");
		var plain = Bytes.ofString("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
		var cipher = new ChaCha20Poly1305(key);
		var sealed = Bytes.alloc(plain.length + 16);
		cipher.seal(nonce, 0, aad, 0, aad.length, plain, 0, plain.length, sealed, 0);
		Assert.equals("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116"
			+ "1ae10b594f09e26a7e902ecbd0600691", sealed.toHex());
		var opened = Bytes.alloc(plain.length);
		Assert.isTrue(cipher.open(nonce, 0, aad, 0, aad.length, sealed, 0, plain.length, opened, 0));
		Assert.equals(plain.toString(), opened.toString());

		// In place, both ways.
		var buffer = Bytes.alloc(plain.length + 16);
		buffer.blit(0, plain, 0, plain.length);
		cipher.seal(nonce, 0, aad, 0, aad.length, buffer, 0, plain.length, buffer, 0);
		Assert.equals(sealed.toHex(), buffer.toHex());
		Assert.isTrue(cipher.open(nonce, 0, aad, 0, aad.length, buffer, 0, plain.length, buffer, 0));
		Assert.equals(plain.toString(), buffer.sub(0, plain.length).toString());
	}

	/**
		Every length a datagram can have the AEAD treat differently, empty,
		short of a block, a block, past one, the largest, with AAD of none,
		short, a block and a hello's header, against OpenSSL; and any byte
		changed is refused, with nothing written.
	**/
	public function testTheAeadMatchesOpenSsl():Void {
		var wrong:Array<String> = [];
		for (row in OPENSSL) {
			var seed:Int = row[0];
			var length:Int = row[1];
			var aadLength:Int = row[2];
			var cipher = new ChaCha20Poly1305(fill(32, 7, seed));
			var nonce = fill(12, 13, seed + 3);
			var aad = fill(aadLength, 11, seed + 5);
			var plain = fill(length, 17, seed + 9);
			var sealed = Bytes.alloc(length + 16);
			cipher.seal(nonce, 0, aad, 0, aadLength, plain, 0, length, sealed, 0);
			var tag:String = sealed.sub(length, 16).toHex();
			var digest:String = haxe.crypto.Sha256.make(sealed.sub(0, length)).toHex().substr(0, 16);
			if (tag != row[3] || digest != row[4]) {
				wrong.push('seed $seed, $length bytes, $aadLength of AAD: tag $tag, ciphertext $digest');
				continue;
			}
			var opened = Bytes.alloc(length);
			if (!cipher.open(nonce, 0, aad, 0, aadLength, sealed, 0, length, opened, 0) || opened.compare(plain) != 0) {
				wrong.push('seed $seed did not open');
			}
			if (length > 0) {
				var untouched = Bytes.alloc(length);
				sealed.set(length - 1, sealed.get(length - 1) ^ 0x80);
				if (cipher.open(nonce, 0, aad, 0, aadLength, sealed, 0, length, untouched, 0)) {
					wrong.push('seed $seed opened with a ciphertext byte changed');
				}
				for (i in 0...length) {
					if (untouched.get(i) != 0) {
						wrong.push('seed $seed wrote plaintext for a datagram it refused');
						break;
					}
				}
			}
		}
		Assert.same([], wrong);
	}

	/**
		A sealed datagram, from the key schedule to the bytes on the wire, as
		Node computes it independently: a hello answering a connection id, a
		first sealed datagram, and one at packet number 2^32 + 5, whose low
		half alone is sent. Through whatever this target seals with.
	**/
	public function testASealedDatagramIsTheSameBytesEverywhere():Void {
		var server = new SessionCipher(fill(32, 29, 3), fill(16, 9, 17));
		var client = new SessionCipher(fill(32, 29, 3), fill(16, 5, 200));
		Assert.isTrue(server.derive(client.localRandom));
		Assert.isTrue(client.derive(server.localRandom));
		Assert.equals("e425dc358c6912478a0670c4c243e151", server.rebindKey.toHex());
		Assert.equals(server.rebindKey.toHex(), client.rebindKey.toHex());

		var plain = fill(40, 3, 1);
		var out = Bytes.alloc(128);
		var length:Int = server.seal(plain, 0, plain.length, out, true, 0x01020304);
		Assert.equals(40 + SessionCipher.HELLO_OVERHEAD, length);
		Assert.equals("cf01020304111a232c353e475059626b747d868f9800000000b70808709109df8e5491cbde2f67b06fa083d5f5228c47f19f0755eb241c2c2a6601a3ef4bf65a408015315b1f56707d10122297f0cc9680",
			out.sub(0, length).toHex());
		var opened = Bytes.alloc(64);
		Assert.equals(40, client.open(out, length, opened));
		Assert.equals(plain.toHex(), opened.sub(0, 40).toHex());

		length = client.seal(plain, 0, plain.length, out, false, 0);
		Assert.equals(40 + SessionCipher.OVERHEAD, length);
		Assert.equals("ce000000001454a6eed73464ac490f9715fb0966a0ac64f66d483c2ab855a392ae20bb47fd027b823401932134f9b41c0b485b7d984bd8c7d893a2d60e",
			out.sub(0, length).toHex());
		Assert.equals(40, server.open(out, length, opened));

		// A large one, which Node seals with its own crypto rather than this
		// package's: the same bytes.
		var large = fill(1100, 3, 1);
		var room = Bytes.alloc(1200);
		client.__sendLow = 7;
		length = client.seal(large, 0, large.length, room, false, 0);
		Assert.equals(1121, length);
		Assert.equals("cac93d93efe592a3299bc9a344eda7f1", haxe.crypto.Sha256.make(room.sub(0, length)).toHex().substr(0, 32));
		var back = Bytes.alloc(1200);
		Assert.equals(1100, server.open(room, length, back));
		Assert.equals(large.toHex(), back.sub(0, 1100).toHex());
		// And refused there, changed in its ciphertext or its tag.
		length = client.seal(large, 0, large.length, room, false, 0);
		for (at in [600, length - 1]) {
			room.set(at, room.get(at) ^ 4);
			Assert.equals(SessionCipher.FORGED, server.open(room, length, back), 'a large datagram changed at $at opened');
			room.set(at, room.get(at) ^ 4);
		}
		Assert.equals(1100, server.open(room, length, back));

		client.__sendHigh = 1;
		client.__sendLow = 5;
		length = client.seal(plain, 0, plain.length, out, false, 0);
		Assert.equals("ce0000000532f12271bcf38571119f9cc793b4a97f10501cc4bf5701deb6a2ace62397fd5ee9a83e76ee71b90651dd9df7f94af46a76d539ae3d6ff45b",
			out.sub(0, length).toHex());
	}

	/** Each end's random goes into every key: another random, another key, and another datagram. **/
	public function testEitherRandomChangesEveryKey():Void {
		var plain = fill(40, 3, 1);
		var base = sealedBy(fill(16, 9, 17), fill(16, 5, 200), plain);
		Assert.notEquals(base, sealedBy(fill(16, 9, 18), fill(16, 5, 200), plain), "the sender's random changed nothing");
		Assert.notEquals(base, sealedBy(fill(16, 9, 17), fill(16, 5, 201), plain), "the peer's random changed nothing");
	}

	/** A random equal to this end's, a CONNECT sent back at its sender, is refused: it would give both directions one key. **/
	public function testAnEqualRandomIsRefused():Void {
		var cipher = new SessionCipher(fill(32, 1, 1), fill(16, 3, 3));
		Assert.isFalse(cipher.derive(fill(16, 3, 3)));
		Assert.isFalse(cipher.ready);
		Assert.isTrue(cipher.derive(fill(16, 3, 4)));
		// And once derived, only the same random is the peer's.
		Assert.isTrue(cipher.derive(fill(16, 3, 4)));
		Assert.isFalse(cipher.derive(fill(16, 3, 5)));
	}

	/** Sealed under another key, nothing opens: every datagram is counted as forged. **/
	public function testAnotherKeyOpensNothing():Void {
		var pair = pairOf(fill(32, 1, 1), fill(32, 1, 2));
		var out = Bytes.alloc(128);
		var opened = Bytes.alloc(128);
		var plain = fill(30, 1, 0);
		for (i in 0...3) {
			var length:Int = pair.a.seal(plain, 0, plain.length, out, i == 0, 0);
			Assert.equals(SessionCipher.FORGED, pair.b.open(out, length, opened));
		}
		Assert.equals(3.0, pair.b.forged);
	}

	/**
		Every byte of a sealed datagram, the header, which is authenticated
		as associated data, the ciphertext and the tag, changed in turn, each
		way a bit can flip: refused and counted every time, and the original
		still opens after, since nothing that failed moved the window.
	**/
	public function testEveryByteIsAuthenticated():Void {
		for (hello in [false, true]) {
			var pair = pairOf(fill(32, 1, 1), fill(32, 1, 1));
			var plain = fill(60, 7, 9);
			var out = Bytes.alloc(160);
			var length:Int = pair.a.seal(plain, 0, plain.length, out, hello, 77);
			var opened = Bytes.alloc(160);
			var accepted:Array<Int> = [];
			for (at in 0...length) {
				for (bit in [0x01, 0x80]) {
					var copy = Bytes.alloc(length);
					copy.blit(0, out, 0, length);
					copy.set(at, copy.get(at) ^ bit);
					// A changed first byte is another header length; whatever it
					// reads as, it must not open.
					if (pair.b.open(copy, length, opened) >= 0) {
						accepted.push(at);
					}
				}
			}
			Assert.same([], accepted, 'bytes accepted changed (hello $hello)');
			Assert.equals(length * 2 * 1.0, pair.b.forged + pair.b.late + pair.b.replayed);
			Assert.equals(plain.length, pair.b.open(out, length, opened), "the original no longer opened");
		}
	}

	/**
		Datagrams opened in any order, each once: a second copy is a replay,
		one older than the window is late, and neither is decrypted.
	**/
	public function testTheReplayWindow():Void {
		var pair = pairOf(fill(32, 1, 1), fill(32, 1, 1));
		var sent:Array<Bytes> = [];
		var plain = fill(20, 1, 1);
		for (i in 0...2100) {
			var out = Bytes.alloc(64);
			var length:Int = pair.a.seal(plain, 0, plain.length, out, false, 0);
			sent.push(out.sub(0, length));
		}
		var opened = Bytes.alloc(64);
		function open(i:Int):Int {
			return pair.b.open(sent[i], sent[i].length, opened);
		}
		// Out of order, within the window.
		Assert.equals(20, open(5));
		Assert.equals(20, open(3));
		Assert.equals(20, open(4));
		Assert.equals(20, open(0));
		Assert.equals(SessionCipher.REPLAYED, open(4));
		Assert.equals(SessionCipher.REPLAYED, open(5));
		// Far ahead: 2000 is the highest, and the window is the 1024 below it.
		Assert.equals(20, open(2000));
		Assert.equals(20, open(2000 - SessionCipher.REPLAY_WINDOW + 1), "the oldest number in the window was refused");
		Assert.equals(SessionCipher.LATE, open(2000 - SessionCipher.REPLAY_WINDOW), "one below the window opened");
		Assert.equals(SessionCipher.LATE, open(6));
		Assert.equals(SessionCipher.REPLAYED, open(2000));
		Assert.equals(20, open(1999));
		Assert.equals(20, open(2099));
		Assert.equals(SessionCipher.REPLAYED, open(1999));
		Assert.equals(4.0, pair.b.replayed);
		Assert.equals(2.0, pair.b.late);
		Assert.equals(0.0, pair.b.forged);
	}

	/**
		Only the packet number's low 32 bits are sent: the receiver takes the
		full number nearest the next it expects, across the wrap of the low
		half and over a gap, and a number the window passed long ago is late
		however its low bits read.
	**/
	public function testThePacketNumberCarriesAcrossItsLowHalf():Void {
		var pair = pairOf(fill(32, 1, 1), fill(32, 1, 1));
		var plain = fill(20, 1, 1);
		var out = Bytes.alloc(64);
		var opened = Bytes.alloc(64);
		// Both ends well into the low half's range, as after four billion
		// datagrams: the receiver has opened up to 0xFFFFFFE0.
		pair.a.__sendLow = 0xFFFFFFF0;
		pair.b.__opened = true;
		pair.b.__highLow = 0xFFFFFFE0;
		var before:Array<Bytes> = [];
		for (i in 0...40) {
			var length:Int = pair.a.seal(plain, 0, plain.length, out, false, 0);
			before.push(out.sub(0, length));
		}
		Assert.equals(1, pair.a.__sendHigh, "the sender's number did not carry");
		// The receiver hears from the sender first just past the wrap.
		Assert.equals(20, pair.b.open(before[20], before[20].length, opened));
		Assert.equals(1, pair.b.__highHigh);
		Assert.equals(4, pair.b.__highLow);
		// Then those from before it, below the wrap, within the window.
		Assert.equals(20, pair.b.open(before[3], before[3].length, opened));
		Assert.equals(20, pair.b.open(before[39], before[39].length, opened));
		Assert.equals(SessionCipher.REPLAYED, pair.b.open(before[3], before[3].length, opened));

		// A gap of a million: bridged.
		pair.a.__sendLow = (pair.a.__sendLow + 1000000) | 0;
		var length:Int = pair.a.seal(plain, 0, plain.length, out, false, 0);
		Assert.equals(20, pair.b.open(out, length, opened));
		// And an old datagram, now far below: late, though its low bits are near.
		Assert.equals(SessionCipher.LATE, pair.b.open(before[30], before[30].length, opened));
	}

	/** Natively, on Node and on the jvm, with a secure random source; nowhere without one. **/
	public function testWhereItIsSupported():Void {
		#if (cpp || nodejs || jvm)
		Assert.isTrue(SessionCipher.isSupported);
		#else
		Assert.isFalse(SessionCipher.isSupported);
		#end
		Assert.equals(21, SessionCipher.OVERHEAD);
		Assert.equals(41, SessionCipher.HELLO_OVERHEAD);
	}

	/** Disposed, a cipher seals nothing, and its keys are zeros. **/
	public function testDisposeWipesTheKeys():Void {
		var pair = pairOf(fill(32, 1, 1), fill(32, 1, 1));
		var rebind:Bytes = pair.a.rebindKey;
		pair.a.dispose();
		Assert.equals("00000000000000000000000000000000", rebind.toHex());
		Assert.equals(-1, pair.a.seal(fill(8, 1, 1), 0, 8, Bytes.alloc(64), false, 0));
	}

	static function sealedBy(senderRandom:Bytes, peerRandom:Bytes, plain:Bytes):String {
		var cipher = new SessionCipher(fill(32, 29, 3), senderRandom);
		cipher.derive(peerRandom);
		var out = Bytes.alloc(128);
		var length:Int = cipher.seal(plain, 0, plain.length, out, false, 0);
		return out.sub(0, length).toHex();
	}

	static function pairOf(keyA:Bytes, keyB:Bytes):{a:SessionCipher, b:SessionCipher} {
		var a = new SessionCipher(keyA, fill(16, 3, 1));
		var b = new SessionCipher(keyB, fill(16, 3, 2));
		a.derive(b.localRandom);
		b.derive(a.localRandom);
		return {a: a, b: b};
	}

	static function fill(length:Int, step:Int, start:Int):Bytes {
		var out = Bytes.alloc(length);
		for (i in 0...length) {
			out.set(i, (i * step + start) & 255);
		}
		return out;
	}

	// From Node's crypto: seed, plaintext length, AAD length, the tag, and
	// the first eight bytes of the ciphertext's SHA-256.
	static final OPENSSL:Array<Array<Dynamic>> = [
		[1, 0, 0, "4421041863085ed43300b5bb4bf9d586", "e3b0c44298fc1c14"],
		[2, 0, 5, "27c681bdaf82c0d6e36589938d2996e8", "e3b0c44298fc1c14"],
		[3, 0, 16, "226ff26d08e438a768984d1da00cfe2c", "e3b0c44298fc1c14"],
		[4, 0, 25, "cf60a4c5d229f42ac9d3361c717f64f5", "e3b0c44298fc1c14"],
		[5, 1, 0, "c92f02bc2e75f3402683e13c1ef3465d", "149488d869cbef08"],
		[6, 1, 5, "793d00d9780f1bce564af6dc32cc31ef", "7941cb07924fdc7b"],
		[7, 1, 16, "bae7ee91234b5f710168f70da07872b3", "18ac3e7343f01689"],
		[8, 1, 25, "85b88cba7a2e7e31f78624b017fce6b5", "a25513c7e0f6eaa8"],
		[9, 15, 0, "eea81ee22299d6ccf799c05b74946e15", "d71443c38c323f9f"],
		[10, 15, 5, "f15a73604c32bf8ce6e03e0c572d7c0b", "8a5cef27d2eb45f9"],
		[11, 15, 16, "80f8939700ca41fb62dcd41b627e248b", "ee757926e1a806a5"],
		[12, 15, 25, "d09b10758c885b72ffd6e23dac8769df", "b6dc10816ccb6638"],
		[13, 16, 0, "43e9eaa58c60608cc1c1101c64593203", "5ae3037a26be6179"],
		[14, 16, 5, "7353de913857c102d1b00f991abee944", "81c487a18849ab5a"],
		[15, 16, 16, "c208a2e242f60d74bbca8a5e121d877b", "dc222b397c43f1ed"],
		[16, 16, 25, "675c02edc6d1a75e89a3ad9a0cb37642", "f95b4ed03fa54d8f"],
		[17, 17, 0, "496578696456af9ad8d4c4e4e292eb9b", "f109198847a6b146"],
		[18, 17, 5, "9efdbe067883d5981ac7342d01fa2c88", "850d33fd2775f336"],
		[19, 17, 16, "fce4508dc9c1faf06cbe99aba955434e", "3a2babf436b0fb5f"],
		[20, 17, 25, "58b9e3642e24cc91d51ba3c94ab506cd", "7ae72f23c926bcfc"],
		[21, 63, 0, "718814ae735b96dc5e43bd13c8dd3529", "e601922d6a806292"],
		[22, 63, 5, "3c6a2a974621cd867fcb2a95d498eb6e", "4afef7ec76892b49"],
		[23, 63, 16, "34f251984b574215e8d28e90a3f85d45", "419f117b85fb4ece"],
		[24, 63, 25, "068aabf47d355b9f896ce679973c9db7", "8f5ce1b09e424227"],
		[25, 64, 0, "d4dbeedb8143225871573584cfdc8a11", "4b544679dd896e1d"],
		[26, 64, 5, "4b374b4df02810fc09ce3680f01c515a", "7b15f758d79f05f3"],
		[27, 64, 16, "9f90f5bb401fc6657275842fd46bb76c", "5e28eb4bdb94254c"],
		[28, 64, 25, "b27cbae3b8af091ad3030a0ccf0c64ad", "8323ac89895c87c0"],
		[29, 65, 0, "adac933d2995807df102b83842cfc8f5", "aebc2cd33af8e72d"],
		[30, 65, 5, "72d3a13cbb5c86f0e16618a20abe9798", "9abffb3a1f4e7a5d"],
		[31, 65, 16, "9f684b496efed63a1079ff6e3508cfa2", "35c0633e30109207"],
		[32, 65, 25, "c9ca59832fcd6c140208a62ea9351f25", "36551222def56103"],
		[33, 100, 0, "901b6e24c21e5f3d48ff43bc45ae9a0a", "a9d17cfcc0b4cd99"],
		[34, 100, 5, "d4526457ea29af3fa4fcb7718b362a99", "f55bff17ac1bba2e"],
		[35, 100, 16, "8cac38223c9cf950bea1381cd8fa28ac", "f52dc16ec60457d2"],
		[36, 100, 25, "b35f15ce25ff986edf7d360c59adc808", "2ec3e6c77e781ca0"],
		[37, 129, 0, "406f19499baa948207d100822f19323a", "1ee0b098f40820d0"],
		[38, 129, 5, "72af37b70934618bec1bfef63557e0dd", "ce13187729eaeeb5"],
		[39, 129, 16, "beb31ca1d356a928ca077e0196571bb1", "e64fe609bb99e170"],
		[40, 129, 25, "79e9dfb976b6d6b7069e44e8cbcd931a", "fa425e5420987671"],
		[41, 1179, 0, "6eeb2d8492345690203d15c8658218aa", "317a70a502830687"],
		[42, 1179, 5, "69fab72b236eeb90b0d9853fc445a3f6", "52ea250162e73726"],
		[43, 1179, 16, "304f581ede830e17ade186d0b303b320", "f3487cf899415ba9"],
		[44, 1179, 25, "819de08571fbff895da7f42ad2e2fb02", "e47b499d774e5468"],
		[45, 1200, 0, "b8ddde1a57460ef411a656527f6dae17", "4545463adbab3b5a"],
		[46, 1200, 5, "ad2f6ac4194f7f8f5a622873ec1bb513", "198e6969b0b6fec9"],
		[47, 1200, 16, "f55570724667058b1c20682438f89c50", "e74d01acf7caa7e4"],
		[48, 1200, 25, "274caae907e8319bed6716c17061bde1", "501d569022a25ae7"]
	];
}
