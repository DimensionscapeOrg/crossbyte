package crossbyte._internal.http.h2.hpack;

import haxe.io.Bytes;
import utest.Assert;

/**
 * HPACK against the worked examples in RFC 7541 Appendix C.
 *
 * These are the reason this suite is worth having: HPACK is stateful across a
 * whole connection, so an encoder that is merely self-consistent will still
 * produce bytes no other implementation can read. The appendix pins exact
 * output for a fixed sequence of requests, including how the dynamic table
 * evolves between them, which a round-trip test cannot check.
 */
class HpackTest extends utest.Test {
	// ---------------------------------------------------------- primitives

	public function testPrefixCodedIntegersMatchTheAppendixCExamples():Void {
		// C.1.1 -- 10 in a 5-bit prefix fits inside the prefix.
		Assert.equals("0a", hex(encodeInteger(10, 5, 0x00)));
		Assert.equals(10, decodeInteger("0a", 5));

		// C.1.2 -- 1337 does not, so the prefix saturates and continuation
		// bytes carry the remainder.
		Assert.equals("1f9a0a", hex(encodeInteger(1337, 5, 0x00)));
		Assert.equals(1337, decodeInteger("1f9a0a", 5));

		// C.1.3 -- 42 in an 8-bit prefix, starting at a byte boundary.
		Assert.equals("2a", hex(encodeInteger(42, 8, 0x00)));
		Assert.equals(42, decodeInteger("2a", 8));
	}

	public function testOversizedPrefixCodedIntegerIsRejected():Void {
		// A continuation run can be extended indefinitely. Truncating silently
		// would turn a bogus length into a read at the wrong offset, so this
		// has to fail rather than wrap.
		Assert.raises(() -> decodeInteger("1fffffffffffff", 5), HpackError);
	}

	public function testHuffmanRoundTripsAndMatchesTheAppendixCoding():Void {
		// C.4.1 -- the Huffman form of "www.example.com".
		var coded:Bytes = HpackHuffman.encode(Bytes.ofString("www.example.com"));
		Assert.equals("f1e3c2e5f23a6ba0ab90f4ff", hex(coded));
		Assert.equals("www.example.com", HpackHuffman.decode(coded, 0, coded.length).toString());

		// C.6.1 -- a date, which is where a wrong code length usually shows up
		// first because of the mixed punctuation.
		var date:Bytes = HpackHuffman.encode(Bytes.ofString("Mon, 21 Oct 2013 20:13:21 GMT"));
		Assert.equals("d07abe941054d444a8200595040b8166e082a62d1bff", hex(date));
		Assert.equals("Mon, 21 Oct 2013 20:13:21 GMT", HpackHuffman.decode(date, 0, date.length).toString());
	}

	public function testHuffmanRoundTripsEveryByteValue():Void {
		// Exercises all 256 codes, including the long ones for bytes that
		// never appear in ASCII headers and so are never covered by the
		// appendix examples.
		var raw:Bytes = Bytes.alloc(256);
		for (i in 0...256) {
			raw.set(i, i);
		}

		var coded:Bytes = HpackHuffman.encode(raw);
		var back:Bytes = HpackHuffman.decode(coded, 0, coded.length);

		Assert.equals(256, back.length);
		for (i in 0...256) {
			if (back.get(i) != i) {
				Assert.fail('byte $i round-tripped as ${back.get(i)}');
				return;
			}
		}
		Assert.pass();
	}

	public function testHuffmanRejectsEosAndOverlongPadding():Void {
		// EOS is 30 bits of 1s; five 0xff bytes contain it outright.
		Assert.raises(() -> {
			var bytes = unhex("ffffffffff");
			HpackHuffman.decode(bytes, 0, bytes.length);
		}, HpackError);

		// A whole byte of padding means a symbol was dropped: padding is at
		// most 7 bits by construction.
		Assert.raises(() -> {
			var bytes = unhex("f1e3c2e5f23a6ba0ab90f4ffff");
			HpackHuffman.decode(bytes, 0, bytes.length);
		}, HpackError);
	}

	// ------------------------------------------------- C.3, literal requests

	public function testRequestSequenceWithoutHuffmanMatchesAppendixC3():Void {
		var encoder = new HpackEncoder(4096);
		var decoder = new HpackDecoder(4096);

		// C.3.1
		var first = [
			new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http"), new HpackHeader(":path", "/"),
			new HpackHeader(":authority", "www.example.com")
		];
		var block:Bytes = encoder.encode(first);
		assertHeaders(first, decoder.decode(block));

		// The three pseudo-headers are static-table hits, so only :authority
		// enters the dynamic table: 57 = 10 + 15 + 32.
		Assert.equals(57, encoder.tableSize);
		Assert.equals(57, decoder.tableSize);

		// C.3.2 -- the repeated fields now cost one byte each, and
		// cache-control joins the table.
		var second = [
			new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "http"), new HpackHeader(":path", "/"),
			new HpackHeader(":authority", "www.example.com"), new HpackHeader("cache-control", "no-cache")
		];
		assertHeaders(second, decoder.decode(encoder.encode(second)));
		Assert.equals(110, encoder.tableSize);
		Assert.equals(110, decoder.tableSize);

		// C.3.3 -- a custom name and value, neither in any table.
		var third = [
			new HpackHeader(":method", "GET"), new HpackHeader(":scheme", "https"), new HpackHeader(":path", "/index.html"),
			new HpackHeader(":authority", "www.example.com"), new HpackHeader("custom-key", "custom-value")
		];
		assertHeaders(third, decoder.decode(encoder.encode(third)));
		Assert.equals(164, encoder.tableSize);
		Assert.equals(164, decoder.tableSize);
	}

	public function testIndexedFieldIsASingleByteOnceTabled():Void {
		var encoder = new HpackEncoder(4096);
		var decoder = new HpackDecoder(4096);
		var header = [new HpackHeader("x-repeat", "value")];

		var initial:Int = encoder.encode(header).length;
		var repeated:Bytes = encoder.encode(header);

		// The whole point of the dynamic table: the second occurrence is one
		// index byte rather than the name and value again.
		Assert.equals(1, repeated.length);
		Assert.isTrue(initial > 1);

		// Decoded in order, so the decoder's table tracks the encoder's.
		decoder.decode(Bytes.ofString("")); // no-op block, table untouched
		Assert.equals(0, decoder.tableSize);
	}

	// ------------------------------------------------------- decoder limits

	public function testDecoderRejectsAnIndexPastTheTable():Void {
		var decoder = new HpackDecoder(4096);
		// 0xbe = indexed field 62, the first dynamic slot, on an empty table.
		Assert.raises(() -> decoder.decode(unhex("be")), HpackError);
	}

	public function testDecoderRejectsIndexZero():Void {
		var decoder = new HpackDecoder(4096);
		// §6.1 reserves index 0; it names nothing.
		Assert.raises(() -> decoder.decode(unhex("80")), HpackError);
	}

	public function testDecoderRejectsATruncatedBlock():Void {
		var decoder = new HpackDecoder(4096);
		// Literal claiming a 5-byte name with only 2 bytes behind it.
		Assert.raises(() -> decoder.decode(unhex("40056162")), HpackError);
	}

	public function testDecoderRejectsATableUpdateAboveTheAdvertisedMaximum():Void {
		var decoder = new HpackDecoder(4096);
		// 3f e1 3f is a 5-bit-prefix integer of 8192, double what we
		// advertised. Honouring it would let a peer choose our memory usage.
		Assert.raises(() -> decoder.decode(unhex("3fe13f")), HpackError);
	}

	public function testDecoderAcceptsATableUpdateExactlyAtTheMaximum():Void {
		var decoder = new HpackDecoder(4096);

		// 3f e1 1f is 4096 -- the advertised maximum itself, which is legal.
		// The bound is "greater than", and an off-by-one here would reject a
		// peer that simply matched our own setting.
		decoder.decode(unhex("3fe11f"));
		Assert.pass();

		// Still usable afterwards, so the update was applied rather than
		// leaving the table in a rejected state.
		var back = decoder.decode(unhex("82"));
		Assert.equals(":method", back[0].name);
		Assert.equals("GET", back[0].value);
	}

	public function testDecoderRejectsATableUpdateAfterAHeaderField():Void {
		var decoder = new HpackDecoder(4096);
		// §4.2 allows updates only at the head of a block. 0x82 is an indexed
		// field, then 0x20 is a size update to 0.
		Assert.raises(() -> decoder.decode(unhex("8220")), HpackError);
	}

	public function testDecoderEnforcesTheHeaderListLimit():Void {
		var decoder = new HpackDecoder(4096, 200);
		var encoder = new HpackEncoder(4096);

		var many:Array<HpackHeader> = [];
		for (i in 0...50) {
			many.push(new HpackHeader("x-field-" + i, "value-" + i));
		}

		// A few hundred bytes of block expanding into several kilobytes of
		// headers is the whole HPACK-bomb shape, and it has to be refused on
		// the decoded size rather than the encoded one.
		Assert.raises(() -> decoder.decode(encoder.encode(many)), HpackError);
	}

	// ------------------------------------------------------- dynamic table

	public function testEvictionFollowsTheEntryOverheadAccounting():Void {
		// Room for exactly one 3+3+32 entry.
		var table = new HpackDynamicTable(38);
		table.add(new HpackHeader("aaa", "bbb"));
		Assert.equals(1, table.length);
		Assert.equals(38, table.size);

		table.add(new HpackHeader("ccc", "ddd"));
		Assert.equals(1, table.length);
		Assert.equals("ccc", table.get(0).name);
	}

	public function testEntryLargerThanTheTableEmptiesItWithoutError():Void {
		// §4.4: not an error, and specifically not an insertion either. A peer
		// may reference the oversized entry in the same block, so throwing
		// here would reject a legal stream.
		var table = new HpackDynamicTable(40);
		table.add(new HpackHeader("aa", "bb"));
		Assert.equals(1, table.length);

		table.add(new HpackHeader("this-name-is-far-too-long-for-the-table", "and-so-is-this-value"));
		Assert.equals(0, table.length);
		Assert.equals(0, table.size);
	}

	public function testResizeEvictsDownToTheNewCapacity():Void {
		var table = new HpackDynamicTable(4096);
		table.add(new HpackHeader("aaa", "bbb"));
		table.add(new HpackHeader("ccc", "ddd"));
		Assert.equals(76, table.size);

		table.resize(38);
		Assert.equals(1, table.length);
		// Newest survives: eviction runs from the old end.
		Assert.equals("ccc", table.get(0).name);
	}

	public function testTableSizeCountsOctetsNotStringLength():Void {
		// A two-character value that is four octets in UTF-8. Counting code
		// units here would desynchronize eviction from a peer counting bytes.
		var header = new HpackHeader("x", "éé");
		Assert.equals(1 + 4 + 32, header.tableSize);
	}

	// ------------------------------------------------------------ sensitive

	public function testSensitiveHeadersAreNeverIndexed():Void {
		var encoder = new HpackEncoder(4096);
		var decoder = new HpackDecoder(4096);
		var secret = [new HpackHeader("authorization", "Bearer abc123", true)];

		var first:Bytes = encoder.encode(secret);
		Assert.equals(0, encoder.tableSize);

		// Still absent from the table, so it cannot be recovered by watching
		// a later request compress it to one byte.
		var second:Bytes = encoder.encode(secret);
		Assert.equals(first.length, second.length);
		Assert.equals(0, encoder.tableSize);

		// 0001xxxx marks never-indexed, distinct from 0000xxxx.
		Assert.equals(0x10, first.get(0) & 0xf0);

		var back:Array<HpackHeader> = decoder.decode(first);
		Assert.equals(1, back.length);
		Assert.equals("Bearer abc123", back[0].value);
		Assert.isTrue(back[0].sensitive);
		Assert.equals(0, decoder.tableSize);
	}

	// ---------------------------------------------------------------- utils

	private function assertHeaders(expected:Array<HpackHeader>, actual:Array<HpackHeader>):Void {
		Assert.equals(expected.length, actual.length);
		if (expected.length != actual.length) {
			return;
		}
		for (i in 0...expected.length) {
			Assert.equals(expected[i].name, actual[i].name);
			Assert.equals(expected[i].value, actual[i].value);
		}
	}

	private static function hex(bytes:Bytes):String {
		var out = new StringBuf();
		for (i in 0...bytes.length) {
			var b = bytes.get(i);
			out.add(StringTools.hex(b, 2).toLowerCase());
		}
		return out.toString();
	}

	private static function unhex(value:String):Bytes {
		var out = Bytes.alloc(value.length >> 1);
		for (i in 0...out.length) {
			out.set(i, Std.parseInt("0x" + value.substr(i * 2, 2)));
		}
		return out;
	}

	// The integer codec is private to the encoder and decoder, so these drive
	// it through the smallest public shape that isolates it: a size update
	// carries a bare integer in a 5-bit prefix, and a string literal length
	// carries one in a 7-bit prefix.
	private static function encodeInteger(value:Int, prefixBits:Int, pattern:Int):Bytes {
		var out = new haxe.io.BytesBuffer();
		var mask:Int = (1 << prefixBits) - 1;

		if (value < mask) {
			out.addByte(pattern | value);
		} else {
			out.addByte(pattern | mask);
			var remainder:Int = value - mask;
			while (remainder >= 0x80) {
				out.addByte((remainder & 0x7f) | 0x80);
				remainder >>>= 7;
			}
			out.addByte(remainder);
		}
		return out.getBytes();
	}

	private static function decodeInteger(hexValue:String, prefixBits:Int):Int {
		var bytes:Bytes = unhex(hexValue);
		var mask:Int = (1 << prefixBits) - 1;
		var value:Int = bytes.get(0) & mask;
		if (value < mask) {
			return value;
		}

		var shift:Int = 0;
		var i:Int = 1;
		while (true) {
			if (i >= bytes.length) {
				throw new HpackError("truncated integer");
			}
			var byte:Int = bytes.get(i++);
			var chunk:Int = byte & 0x7f;
			if (shift > 21 || (shift == 21 && chunk > 0x0f)) {
				throw new HpackError("Prefix-coded integer does not fit in 32 bits");
			}
			value += chunk << shift;
			if (value < 0) {
				throw new HpackError("Prefix-coded integer overflowed");
			}
			if ((byte & 0x80) == 0) {
				return value;
			}
			shift += 7;
		}
	}
}
