package crossbyte.io;

import crossbyte.errors.EOFError;
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

		`readInt`, `readShort` and their writers moved from four (or two)
		bounds-checked byte accesses to one `getInt32`/`getUInt16` plus a swap
		for big-endian streams -- most network traffic, and all of STUN and
		SCTP. `getInt32` is little-endian by definition on every target, so the
		swap is where a mistake would live, and a wrong swap still round-trips
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

		The multi-byte readers used to lean on `readUnsignedByte` for their
		bounds check, one byte at a time, so a truncated stream advanced the
		position by however many bytes happened to be there before throwing --
		leaving the caller to catch an error and then find its cursor somewhere
		it never put it. Checking the whole width up front makes the read
		atomic, which is what a caller that catches `EOFError` and retries on a
		longer buffer needs.
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

	public function testReadVarIntRoundTrips():Void {
		var ba = new ByteArray();
		var values:Array<Int> = [0, 1, 127, 128, 16383, 16384, 2097151, 0x0FFFFFFF];

		for (value in values) {
			ba.writeVarInt(value);
		}

		ba.position = 0;
		for (value in values) {
			Assert.equals(value, ba.readVarInt());
		}
	}

	public function testReadVarIntThrowsOnNeverTerminatingVarInt():Void {
		#if final
		Assert.pass();
		return;
		#end

		// Every byte sets the continuation bit (0x80) and never terminates.
		var bytes = Bytes.alloc(8);
		for (i in 0...8) {
			bytes.set(i, 0x80);
		}

		var ba:ByteArray = ByteArray.fromBytes(bytes);
		ba.position = 0;

		Assert.raises(() -> ba.readVarInt(), EOFError);
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
	 * writing there — the one case `writeBytes` cannot cover by
	 * overwriting, and so the one the zeroing still has to handle.
	 */
	/**
		A gap that needs no growth is zeroed too.

		`testWritingPastTheEndZeroesTheGap` leaves its hole by seeking 32KB past
		the end of a one-byte array, which forces a reallocation -- and the
		zeroing lived inside that reallocation, so the case it covers is the
		only case it could ever have caught.

		The buffer here keeps its capacity and loses only its length, which is
		the ordinary way to reuse one. Everything between the new end and the
		capacity is still holding the old contents, and a later write past the
		end exposes all of it: bytes the caller never wrote, readable by
		whoever the buffer is handed to. Ninety-six of ninety-six, measured
		before this was fixed.
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
	 * path where zeroing is now skipped on the grounds that the write
	 * covers the whole grown region.
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
}
