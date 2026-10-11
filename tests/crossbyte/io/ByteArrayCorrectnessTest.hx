package crossbyte.io;

import crossbyte.errors.EOFError;
import crossbyte.errors.RangeError;
import crossbyte.io.Endian;
import haxe.io.Bytes;
import utest.Assert;

class ByteArrayCorrectnessTest extends utest.Test {
	public function testWriteReadFloatRoundTripsLittleEndian():Void {
		var values:Array<Float> = [0.0, 1.5, -2.25, 3.1415927, -123456.75, 1.0e30, -1.0e-12];

		var ba = new ByteArray();
		ba.endian = Endian.LITTLE_ENDIAN;

		for (value in values) {
			ba.writeFloat(value);
		}

		ba.position = 0;
		ba.endian = Endian.LITTLE_ENDIAN;
		for (value in values) {
			// Float32 carries ~7 significant digits, so assert the round-trip
			// within float32 relative precision rather than exact equality.
			Assert.floatEquals(value, ba.readFloat(), Math.abs(value) * 1e-6 + 1e-12);
		}
		Assert.equals(values.length * 4, ba.position);
	}

	public function testWriteReadFloatRoundTripsBigEndian():Void {
		var values:Array<Float> = [0.0, 1.5, -2.25, 3.1415927, -123456.75, 1.0e30, -1.0e-12];

		var ba = new ByteArray();
		ba.endian = Endian.BIG_ENDIAN;

		for (value in values) {
			ba.writeFloat(value);
		}

		ba.position = 0;
		ba.endian = Endian.BIG_ENDIAN;
		for (value in values) {
			Assert.floatEquals(value, ba.readFloat(), Math.abs(value) * 1e-6 + 1e-12);
		}
		Assert.equals(values.length * 4, ba.position);
	}

	public function testWriteReadDoubleRoundTripsLittleEndian():Void {
		var values:Array<Float> = [0.0, 1.5, -2.25, 3.141592653589793, -1234567.89, 1.0e300, -1.0e-300];

		var ba = new ByteArray();
		ba.endian = Endian.LITTLE_ENDIAN;

		for (value in values) {
			ba.writeDouble(value);
		}

		ba.position = 0;
		ba.endian = Endian.LITTLE_ENDIAN;
		for (value in values) {
			Assert.floatEquals(value, ba.readDouble());
		}
		Assert.equals(values.length * 8, ba.position);
	}

	public function testWriteReadDoubleRoundTripsBigEndian():Void {
		var values:Array<Float> = [0.0, 1.5, -2.25, 3.141592653589793, -1234567.89, 1.0e300, -1.0e-300];

		var ba = new ByteArray();
		ba.endian = Endian.BIG_ENDIAN;

		for (value in values) {
			ba.writeDouble(value);
		}

		ba.position = 0;
		ba.endian = Endian.BIG_ENDIAN;
		for (value in values) {
			Assert.floatEquals(value, ba.readDouble());
		}
		Assert.equals(values.length * 8, ba.position);
	}

	public function testFloatByteLayoutIsBigEndian():Void {
		// IEEE-754 single-precision encoding of 1.0 is 0x3F800000.
		var ba = new ByteArray();
		ba.endian = Endian.BIG_ENDIAN;
		ba.writeFloat(1.0);

		Assert.equals(4, ba.length);
		Assert.equals(0x3F, ba[0]);
		Assert.equals(0x80, ba[1]);
		Assert.equals(0x00, ba[2]);
		Assert.equals(0x00, ba[3]);
	}

	public function testFloatByteLayoutIsLittleEndian():Void {
		// IEEE-754 single-precision encoding of 1.0 is 0x3F800000, byte-reversed.
		var ba = new ByteArray();
		ba.endian = Endian.LITTLE_ENDIAN;
		ba.writeFloat(1.0);

		Assert.equals(4, ba.length);
		Assert.equals(0x00, ba[0]);
		Assert.equals(0x00, ba[1]);
		Assert.equals(0x80, ba[2]);
		Assert.equals(0x3F, ba[3]);
	}

	public function testFloatLayoutMatchesAcrossEndianReversal():Void {
		// The little-endian layout must be the exact byte reversal of the
		// big-endian layout for the same value.
		var value:Float = -2.25;

		var be = new ByteArray();
		be.endian = Endian.BIG_ENDIAN;
		be.writeFloat(value);

		var le = new ByteArray();
		le.endian = Endian.LITTLE_ENDIAN;
		le.writeFloat(value);

		Assert.equals(be[0], le[3]);
		Assert.equals(be[1], le[2]);
		Assert.equals(be[2], le[1]);
		Assert.equals(be[3], le[0]);
	}

	public function testDoubleLayoutMatchesAcrossEndianReversal():Void {
		var value:Float = 3.141592653589793;

		var be = new ByteArray();
		be.endian = Endian.BIG_ENDIAN;
		be.writeDouble(value);

		var le = new ByteArray();
		le.endian = Endian.LITTLE_ENDIAN;
		le.writeDouble(value);

		Assert.equals(8, be.length);
		Assert.equals(8, le.length);
		for (i in 0...8) {
			Assert.equals(be[i], le[7 - i]);
		}
	}

	public function testWriteShortMasksHighBitsLittleEndian():Void {
		var ba = new ByteArray();
		ba.endian = Endian.LITTLE_ENDIAN;
		// 0x1FF has bits outside the low 8; the high byte must be masked.
		ba.writeShort(0x1FF);

		Assert.equals(2, ba.length);
		Assert.equals(0xFF, ba[0]);
		Assert.equals(0x01, ba[1]);

		ba.position = 0;
		Assert.equals(0x1FF, ba.readUnsignedShort());
	}

	public function testWriteShortMasksHighBitsBigEndian():Void {
		var ba = new ByteArray();
		ba.endian = Endian.BIG_ENDIAN;
		ba.writeShort(0x1FF);

		Assert.equals(2, ba.length);
		Assert.equals(0x01, ba[0]);
		Assert.equals(0xFF, ba[1]);

		ba.position = 0;
		Assert.equals(0x1FF, ba.readUnsignedShort());
	}

	public function testWriteShortMasksNegativeValue():Void {
		var ba = new ByteArray();
		ba.endian = Endian.BIG_ENDIAN;
		// -1 must be stored as the low 16 bits (0xFFFF), not as a wider value.
		ba.writeShort(-1);

		Assert.equals(2, ba.length);
		Assert.equals(0xFF, ba[0]);
		Assert.equals(0xFF, ba[1]);

		ba.position = 0;
		Assert.equals(-1, ba.readShort());
	}

	public function testWriteShortMasksLargeNegativeValue():Void {
		var ba = new ByteArray();
		ba.endian = Endian.LITTLE_ENDIAN;
		// High bits beyond 16 are ignored: only 0x8001 is retained.
		ba.writeShort(0xFFFF8001);

		Assert.equals(2, ba.length);
		Assert.equals(0x01, ba[0]);
		Assert.equals(0x80, ba[1]);

		ba.position = 0;
		Assert.equals(0x8001, ba.readUnsignedShort());
	}

	/**
		The word-at-a-time integer accessors agree with the byte-at-a-time
		definition, in both orders, at every alignment.

		`readInt`, `readShort` and their writers make one `getInt32`/`getUInt16`
		access plus a swap for big-endian streams (most network traffic, and all
		of STUN and SCTP), not four (or two) bounds-checked byte accesses.
		`getInt32` is little-endian by definition on every target, so the swap
		is where a mistake would live, and a wrong swap still round-trips
		perfectly against itself: write then read gives the value back while
		every byte on the wire is reversed. So the bytes are checked, not just
		the round trip.

		Every offset from zero to seven, because a word access at an odd offset
		is the case a naive implementation gets wrong and no round-trip test
		notices.
	**/
	public function testIntegerAccessorsAgreeWithTheByteDefinition():Void {
		var values = [0, 1, -1, 255, 256, 65535, 65536, 0x7FFFFFFF, -0x80000000, 0x12345678, -0x12345678];

		for (endian in [Endian.LITTLE_ENDIAN, Endian.BIG_ENDIAN]) {
			for (offset in 0...8) {
				for (value in values) {
					var written = new ByteArray();
					written.endian = endian;

					for (_ in 0...offset) {
						written.writeByte(0xAA);
					}

					written.writeInt(value);

					// The bytes themselves, against the definition: big-endian
					// is most significant first, little-endian is not.
					for (i in 0...4) {
						var shift = endian == Endian.BIG_ENDIAN ? (3 - i) * 8 : i * 8;
						Assert.equals((value >>> shift) & 0xFF, written[offset + i],
							"writeInt byte " + i + " at offset " + offset + " for " + value + " (" + endian + ")");
					}

					written.position = offset;
					Assert.equals(value, written.readInt(), "readInt at offset " + offset + " for " + value);
					Assert.equals(offset + 4, written.position, "readInt left the position wrong");
				}

				// Shorts, signed and unsigned, over the whole 16-bit range's
				// interesting points.
				for (value in [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x1234]) {
					var written = new ByteArray();
					written.endian = endian;

					for (_ in 0...offset) {
						written.writeByte(0xAA);
					}

					written.writeShort(value);

					for (i in 0...2) {
						var shift = endian == Endian.BIG_ENDIAN ? (1 - i) * 8 : i * 8;
						Assert.equals((value >>> shift) & 0xFF, written[offset + i],
							"writeShort byte " + i + " at offset " + offset + " for " + value);
					}

					written.position = offset;
					Assert.equals(value, written.readUnsignedShort(), "readUnsignedShort at offset " + offset);

					written.position = offset;
					var signed = (value & 0x8000) != 0 ? value - 0x10000 : value;
					Assert.equals(signed, written.readShort(), "readShort at offset " + offset + " for " + value);
				}
			}
		}
	}

	/**
		A read that cannot be satisfied throws and moves nothing.

		The multi-byte readers check the whole width up front, rather than
		leaning on `readUnsignedByte` for their bounds check one byte at a time,
		where a truncated stream would advance the position by however many
		bytes happened to be there before throwing, leaving the caller to catch
		an error and then find its cursor somewhere it never put it. Checking
		first makes the read atomic, which is what a caller that catches
		`EOFError` and retries on a longer buffer needs.
	**/
	public function testATruncatedReadThrowsWithoutMovingThePosition():Void {
		for (available in 0...4) {
			var partial = new ByteArray();

			for (_ in 0...available) {
				partial.writeByte(0x5A);
			}

			partial.position = 0;
			Assert.raises(() -> partial.readInt(), EOFError);
			Assert.equals(0, partial.position, "readInt moved the position past a truncated read");
		}

		var one = new ByteArray();
		one.writeByte(0x5A);
		one.position = 0;
		Assert.raises(() -> one.readUnsignedShort(), EOFError);
		Assert.equals(0, one.position, "readUnsignedShort moved the position past a truncated read");
	}

	public function testReadVarUIntRoundTrips():Void {
		var ba = new ByteArray();
		var values:Array<Int> = [0, 1, 127, 128, 16383, 16384, 2097151, 0x0FFFFFFF];

		for (value in values) {
			ba.writeVarUInt(value);
		}

		ba.position = 0;
		for (value in values) {
			Assert.equals(value, ba.readVarUInt());
		}
	}

	public function testReadVarUIntThrowsOnNeverTerminatingVarUInt():Void {
		// Every byte sets the continuation bit (0x80) and never terminates.
		// Refused at the fifth, which has to end a 32-bit varint, as data that
		// is wrong rather than data still to come: an EOFError tells a reader
		// to wait for more, and no more would ever make this one valid.
		var bytes = Bytes.alloc(8);
		for (i in 0...8) {
			bytes.set(i, 0x80);
		}

		var ba:ByteArray = ByteArray.fromBytes(bytes);
		ba.position = 0;

		Assert.raises(() -> ba.readVarUInt(), RangeError);
	}

	/**
		The whole unsigned range the doc promises, at each edge where the
		encoded length changes and at the top bit. A writer looping while a
		signed `v > 0x7F` would send a value with bit 31 set as a single byte:
		0x80000000 would read back as 0, and 0xFFFFFFFF as a varint that never
		ended.
	**/
	public function testVarUIntRoundTripsTheWholeUnsignedRange():Void {
		var values:Array<Int> = [0, 0x7F, 0x80, 0x3FFF, 0x4000, 1 << 30, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF];
		var sizes:Array<Int> = [1, 1, 2, 2, 3, 5, 5, 5, 5];

		for (i in 0...values.length) {
			var ba = new ByteArray();
			ba.writeVarUInt(values[i]);
			Assert.equals(sizes[i], ba.length, 'encoded length of ${StringTools.hex(values[i], 8)}');
		}

		var ba = new ByteArray();
		for (value in values) {
			ba.writeVarUInt(value);
		}
		ba.position = 0;
		for (value in values) {
			Assert.equals(value, ba.readVarUInt(), 'read back ${StringTools.hex(value, 8)}');
		}
		Assert.equals(0, ba.bytesAvailable);
	}

	/**
		A fifth byte carries the last four bits of a 32-bit value and must
		end the varint. Bits past those are refused, not shifted off the top,
		where 2^32 + 1 would read as 1 with nothing to say the value had not fitted.
	**/
	public function testReadVarUIntRefusesAValuePast32Bits():Void {
		// 2^32 + 1, 2^32, and the fifth byte asking for a sixth.
		for (encoded in [[0x81, 0x80, 0x80, 0x80, 0x10], [0x80, 0x80, 0x80, 0x80, 0x10], [0xFF, 0xFF, 0xFF, 0xFF, 0x8F, 0x01]]) {
			var ba = new ByteArray();
			for (byte in encoded) {
				ba.writeByte(byte);
			}
			ba.position = 0;
			Assert.raises(() -> ba.readVarUInt(), RangeError, 'read ${encoded} as a 32-bit value');
			Assert.equals(0, ba.position, "a refused varint moved the position");
		}
	}

	/**
		A varint cut short is an EOFError that leaves the position where it
		was, as a truncated readInt does, so a reader can try again once the
		rest has arrived.
	**/
	public function testATruncatedVarUIntLeavesThePositionAlone():Void {
		var ba = new ByteArray();
		ba.writeByte(0x80);
		ba.writeByte(0x80);
		ba.position = 0;

		Assert.raises(() -> ba.readVarUInt(), EOFError);
		Assert.equals(0, ba.position);

		ba.position = ba.length;
		ba.writeByte(0x01);
		ba.position = 0;
		Assert.equals(1 << 14, ba.readVarUInt());
	}

	public function testWriteBytesClampsOutOfRangeOffsetAndLength():Void {
		var src = new ByteArray();
		for (i in 0...4) {
			src.writeByte(i); // 0,1,2,3
		}

		// Explicit length larger than what remains from offset is clamped.
		var a = new ByteArray();
		a.writeBytes(src, 2, 100);
		Assert.equals(2, a.length);
		Assert.equals(2, a[0]);
		Assert.equals(3, a[1]);

		// Offset at/beyond the source length writes nothing (no over-read).
		var b = new ByteArray();
		b.writeBytes(src, 4, 0);
		Assert.equals(0, b.length);
		b.writeBytes(src, 10, 5);
		Assert.equals(0, b.length);

		// Default length (0) copies from offset to the end.
		var c = new ByteArray();
		c.writeBytes(src, 1);
		Assert.equals(3, c.length);
		Assert.equals(1, c[0]);
		Assert.equals(3, c[2]);
	}

	public function testSetLengthClampsNegativeToZero():Void {
		var ba = new ByteArray();
		ba.writeInt(0x01020304);
		Assert.equals(4, ba.length);

		ba.length = -5;
		Assert.equals(0, ba.length);
		Assert.equals(0, ba.position);
	}

	/**
	 * Growing a buffer must expose zeros, never whatever the allocator
	 * last left in that memory.
	 *
	 * A disclosure property, not a convenience one: the bytes between the
	 * old length and the new one are readable by anything holding the
	 * ByteArray, and on a server that can mean unrelated request data.
	 * Asserted over a span large enough to involve fresh pages rather than
	 * a small block that happens to be zero already.
	 */
	public function testGrowingByAssigningLengthExposesZeros():Void {
		var ba = new ByteArray();
		ba.writeInt(0x01020304);

		ba.length = 64 * 1024;

		var nonZero:Int = 0;
		for (i in 4...ba.length) {
			if (ba[i] != 0) {
				nonZero++;
			}
		}

		Assert.equals(0, nonZero, '$nonZero byte(s) of the grown buffer were not zero');
	}

	/**
	 * The same guarantee when the gap comes from seeking past the end and
	 * writing there: the one case `writeBytes` cannot cover by
	 * overwriting, and so the one the zeroing still has to handle.
	 */
	/**
		A gap that needs no growth is zeroed too.

		`testWritingPastTheEndZeroesTheGap` leaves its hole by seeking 32KB past
		the end of a one-byte array, which forces a reallocation, so zeroing
		done only inside that reallocation would pass it and miss this case.

		The buffer here keeps its capacity and loses only its length, which is
		the ordinary way to reuse one. Everything between the new end and the
		capacity still holds the old contents, and a later write past the end
		would expose all of it unzeroed: bytes the caller never wrote, readable
		by whoever the buffer is handed to.
	**/
	public function testAGapThatNeedsNoGrowthIsZeroedAsWell():Void {
		var ba = new ByteArray();

		// Well past any initial capacity, so shrinking leaves a large region of
		// live bytes sitting behind the logical end.
		for (_ in 0...4096) {
			ba.writeByte(0xC5);
		}

		ba.length = 4;
		Assert.equals(4, ba.length);

		// No growth: the capacity from before comfortably covers this.
		ba.position = 100;
		ba.writeByte(0x11);

		var stale:Int = 0;

		for (i in 4...100) {
			if (ba[i] != 0) {
				stale++;
			}
		}

		Assert.equals(0, stale, stale + " byte(s) of the skipped gap still held the old contents");
		Assert.equals(0x11, ba[100]);
	}

	/** The same for the bulk path, which zeroes only up to where it writes. **/
	public function testABulkWritePastTheEndZeroesOnlyTheGap():Void {
		var ba = new ByteArray();

		for (_ in 0...4096) {
			ba.writeByte(0xC5);
		}

		ba.length = 4;

		var payload = new ByteArray();

		for (i in 0...16) {
			payload.writeByte((i * 3) & 0xFF);
		}

		ba.position = 64;
		ba.writeBytes(payload, 0, payload.length);

		for (i in 4...64) {
			Assert.equals(0, ba[i], "byte " + i + " of the gap was not zeroed");
		}

		for (i in 0...16) {
			Assert.equals((i * 3) & 0xFF, ba[64 + i], "the payload did not land intact");
		}
	}

	/**
		The same for readBytes into a destination past its end: the gap before
		the offset is zeroed, the old contents of a destination cut short do
		not show through it, and what is read lands whole. Only the gap is
		zeroed, since the bytes read cover the rest.
	**/
	public function testReadBytesPastTheEndZeroesOnlyTheGap():Void {
		var ba = new ByteArray();

		for (_ in 0...4096) {
			ba.writeByte(0xC5);
		}

		ba.length = 4;

		var source = new ByteArray();

		for (i in 0...16) {
			source.writeByte((i * 5 + 1) & 0xFF);
		}

		source.position = 0;
		source.readBytes(ba, 64, 16);

		Assert.equals(80, ba.length);

		for (i in 4...64) {
			Assert.equals(0, ba[i], "byte " + i + " of the gap was not zeroed");
		}

		for (i in 0...16) {
			Assert.equals((i * 5 + 1) & 0xFF, ba[64 + i], "what was read did not land intact");
		}
	}

	public function testWritingPastTheEndZeroesTheGap():Void {
		var payload = new ByteArray();
		for (i in 0...256) {
			payload.writeByte((i * 7) & 0xFF);
		}

		var ba = new ByteArray();
		ba.writeByte(0xAA);

		// A deliberate hole between the first byte and the payload.
		ba.position = 32 * 1024;
		ba.writeBytes(payload, 0, payload.length);

		Assert.equals(0xAA, ba[0]);

		var nonZero:Int = 0;
		for (i in 1...32 * 1024) {
			if (ba[i] != 0) {
				nonZero++;
			}
		}
		Assert.equals(0, nonZero, '$nonZero byte(s) of the skipped gap were not zero');

		for (i in 0...payload.length) {
			Assert.equals((i * 7) & 0xFF, ba[32 * 1024 + i]);
		}
	}

	/**
	 * Appending stays byte-exact across many growths, since that is the
	 * path where zeroing is skipped on the grounds that the write covers the
	 * whole grown region.
	 */
	public function testRepeatedAppendsStayIntactAcrossGrowth():Void {
		var chunk = new ByteArray();
		for (i in 0...1024) {
			chunk.writeByte(i & 0xFF);
		}

		var ba = new ByteArray();
		for (_ in 0...64) {
			ba.writeBytes(chunk, 0, chunk.length);
		}

		Assert.equals(64 * 1024, ba.length);

		var corrupt:Int = -1;
		for (i in 0...ba.length) {
			if (ba[i] != (i % 1024) & 0xFF) {
				corrupt = i;
				break;
			}
		}
		Assert.equals(-1, corrupt, 'byte $corrupt corrupted after growth');
	}

	/**
	 * The length in front of a writeUTF string is sixteen bits, so past 65535
	 * it is refused: wrapped, the whole string would go out behind a length
	 * describing some other number of bytes, so the reader would stop short
	 * and every read after it would land in the middle of the string.
	 */
	public function testWriteUTFRefusesWhatItsLengthPrefixCannotState():Void {
		var ba = new ByteArray();
		var raised:Dynamic = null;

		try {
			ba.writeUTF(StringTools.lpad("", "x", 70000));
		} catch (e:Dynamic) {
			raised = e;
		}

		Assert.isTrue(Std.isOfType(raised, crossbyte.errors.RangeError), "70000 bytes did not raise RangeError: " + Std.string(raised));
		// Refused before anything is written, so the record stays in step.
		Assert.equals(0, ba.length);

		var widest:String = StringTools.lpad("", "y", 65535);
		ba.writeUTF(widest);
		ba.writeInt(42);
		ba.position = 0;
		Assert.equals(widest, ba.readUTF());
		Assert.equals(42, ba.readInt());
	}

	/**
		A read with the position far past the end is an EOFError, as one just
		past it is, and leaves the position alone. The checks added the read's
		size to the position, which near 2^31 wrapped negative and passed:
		natively the read then answered 0 as though the bytes were there, the
		interpreter threw OutsideBounds and the jvm an
		ArrayIndexOutOfBoundsException, none of which a reader waiting for
		more bytes catches.
	**/
	public function testAReadFarPastTheEndIsAnEOFError():Void {
		var reads:Array<ByteArray->Dynamic> = [
			b -> b.readInt(), b -> b.readUnsignedInt(), b -> b.readShort(), b -> b.readUnsignedShort(), b -> b.readInt64(),
			b -> b.readDouble(), b -> b.readFloat(), b -> b.readByte(), b -> b.readUnsignedByte(), b -> b.readBoolean(),
			b -> b.readUTFBytes(2), b -> b.readUTF(), b -> b.readVarUInt()
		];
		for (at in [0x7FFFFFFF, 0x7FFFFFFE, 0x7FFFFFFC, 0x7FFFFFF9]) {
			for (i in 0...reads.length) {
				var bytes = new ByteArray();
				bytes.writeInt(1);
				bytes.writeInt(2);
				bytes.position = at;
				var raised:Dynamic = null;
				try {
					reads[i](bytes);
				} catch (e:Dynamic) {
					raised = e;
				}
				Assert.isTrue(Std.isOfType(raised, EOFError), 'read $i at $at raised ' + Std.string(raised));
				Assert.equals(at, (bytes.position : Int), 'read $i at $at moved the position');
			}
		}
	}

	/**
		A write whose end would pass the largest ByteArray, 2^31 - 1 bytes, is
		a RangeError, and writes nothing. Its end wrapped negative, so nothing
		grew: natively the write then asked the buffer to grow itself to 2 GB a
		byte at a time, and the jvm threw ArrayIndexOutOfBoundsException.
	**/
	public function testAWritePastTheLargestByteArrayIsARangeError():Void {
		var writes:Array<{at:Int, write:ByteArray->Void}> = [
			{at: 0x7FFFFFFF, write: b -> b.writeByte(1)},
			{at: 0x7FFFFFFF, write: b -> b.writeBoolean(true)},
			{at: 0x7FFFFFFE, write: b -> b.writeShort(1)},
			{at: 0x7FFFFFFC, write: b -> b.writeInt(1)},
			{at: 0x7FFFFFFE, write: b -> b.writeUnsignedInt(1)},
			{at: 0x7FFFFFFA, write: b -> b.writeDouble(1.5)},
			{at: 0x7FFFFFFE, write: b -> b.writeFloat(1.5)},
			{at: 0x7FFFFFFE, write: b -> b.writeUTFBytes("abc")},
			{at: 0x7FFFFFFF, write: b -> b.writeVarUInt(300)}
		];
		for (i in 0...writes.length) {
			var bytes = new ByteArray();
			bytes.writeInt(7);
			bytes.position = writes[i].at;
			var raised:Dynamic = null;
			try {
				writes[i].write(bytes);
			} catch (e:Dynamic) {
				raised = e;
			}
			Assert.isTrue(Std.isOfType(raised, RangeError), 'write $i raised ' + Std.string(raised));
			Assert.equals(4, (bytes.length : Int), 'write $i changed the length');
		}
	}

	/**
		A position is an Int: one from 2^31 up, which as a UInt is past the
		largest ByteArray, is refused rather than kept as a negative number
		every read and write then went wrong with.
	**/
	public function testAPositionPastTheLargestByteArrayIsRefused():Void {
		var bytes = new ByteArray();
		bytes.writeInt(1);
		Assert.raises(() -> bytes.position = 0xFFFFFFFF, RangeError);
		Assert.raises(() -> bytes.position = 0x80000000, RangeError);
		Assert.equals(4, (bytes.position : Int));
		bytes.position = 0x7FFFFFFF;
		Assert.equals(0x7FFFFFFF, (bytes.position : Int));
	}

	/**
		`readDouble` and `readUTF` cut short leave the position where it was,
		as every other read does, so a reader that catches the EOFError and
		tries again with more bytes reads from the start of the value.
		`readDouble` read two Ints and the first moved the position;
		`readUTF` read its length and then failed on the text.
	**/
	public function testATruncatedDoubleOrUTFLeavesThePositionAlone():Void {
		for (available in 4...8) {
			var partial = new ByteArray();
			for (_ in 0...available) {
				partial.writeByte(0x3F);
			}
			partial.position = 0;
			Assert.raises(() -> partial.readDouble(), EOFError);
			Assert.equals(0, (partial.position : Int), 'readDouble with $available bytes moved the position');
		}

		var text = new ByteArray();
		text.writeShort(5);
		text.writeUTFBytes("abc");
		text.position = 0;
		Assert.raises(() -> text.readUTF(), EOFError);
		Assert.equals(0, (text.position : Int), "readUTF moved the position past its length");
		text.position = text.length;
		text.writeUTFBytes("de");
		text.position = 0;
		Assert.equals("abcde", text.readUTF());
	}

	/**
		Reading by index outside the bytes answers 0, as one inside a gap
		does, on every target. Past `length`, inside the buffer, it answered
		whatever was there before the ByteArray was shortened, natively and on
		the jvm; past the buffer the jvm threw.
	**/
	public function testAnIndexOutsideTheBytesReadsAsZero():Void {
		var bytes = new ByteArray();
		bytes.writeInt(0x11223344);
		bytes.writeInt(0x55667788);
		bytes.length = 4;
		Assert.equals(0, bytes[6]);
		Assert.equals(0, bytes[4]);
		Assert.equals(0, bytes[-1]);
		Assert.equals(0, bytes[1000000]);
		Assert.equals(0x22, bytes[2]);
	}

	/**
		Writing by a negative index is a RangeError, not a write nowhere (or
		an exception of the target's own), and nothing changes.
	**/
	public function testWritingANegativeIndexIsARangeError():Void {
		var bytes = new ByteArray();
		bytes.writeInt(0);
		Assert.raises(() -> bytes[-1] = 7, RangeError);
		Assert.equals(4, (bytes.length : Int));
		bytes[5] = 9;
		Assert.equals(6, (bytes.length : Int));
		Assert.equals(9, bytes[5]);
		Assert.equals(0, bytes[4]);
	}

	/**
		With the position past the end there is nothing to read, not about
		four billion bytes: `bytesAvailable` is a UInt, and length less
		position went negative.
	**/
	public function testNothingIsAvailableWithThePositionPastTheEnd():Void {
		var bytes = new ByteArray();
		bytes.writeInt(1);
		bytes.position = 10;
		Assert.equals(0, (bytes.bytesAvailable : Int));
		bytes.position = 1;
		Assert.equals(3, (bytes.bytesAvailable : Int));
	}
}
