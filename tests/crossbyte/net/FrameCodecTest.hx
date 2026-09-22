package crossbyte.net;

import crossbyte.errors.IOError;
import crossbyte.io.ByteArray;
import utest.Assert;

/**
	Message boundaries over a transport that does not keep them.

	Bytes in and bytes out, so every target runs these -- unlike the cases
	that need a live socket, which are gated on the targets that have one.
**/
class FrameCodecTest extends utest.Test {
	/** A message survives being cut anywhere, including inside its header. **/
	public function testAMessageArrivesHoweverItIsSplit():Void {
		var payload = counting(300);
		var wire = FrameCodec.encode(payload);

		// Every split point, header included. Reported once rather than per
		// cut, so three hundred passes do not print nine hundred dots.
		var wrong:String = null;

		for (cut in 1...wire.length) {
			var codec = new FrameCodec();
			codec.feed(slice(wire, 0, cut));

			if (codec.next() != null) {
				wrong = "a message went up after only " + cut + " of " + wire.length + " bytes";
				break;
			}

			codec.feed(slice(wire, cut, wire.length - cut));
			var got = codec.next();

			if (got == null) {
				wrong = "nothing arrived once all " + wire.length + " bytes had, split at " + cut;
				break;
			}

			if (!same(payload, got)) {
				wrong = "the message came back wrong, split at " + cut;
				break;
			}
		}

		Assert.isNull(wrong, wrong);
	}

	/** Several in one read come out one at a time, in order. **/
	public function testSeveralMessagesInOneReadComeOutInOrder():Void {
		var codec = new FrameCodec();
		var packed = new ByteArray();

		for (i in 0...5) {
			var frame = FrameCodec.encode(counting(10 + i * 7));
			packed.writeBytes(frame, 0, frame.length);
		}

		packed.position = 0;
		codec.feed(packed);

		for (i in 0...5) {
			var got = codec.next();
			Assert.notNull(got, "message " + i + " of five did not arrive");

			if (got != null) {
				Assert.equals(10 + i * 7, got.length, "message " + i + " came back the wrong length");
			}
		}

		Assert.isNull(codec.next(), "a sixth message arrived from five");
		Assert.equals(0, codec.buffered, "the reader is still holding bytes after the last message");
	}

	/**
		A declared length is a claim, and is refused before anything is held.

		Four bytes claiming two gigabytes is all it takes. A reader that waits
		for the bytes before judging the figure has already agreed to hold
		however many were asked for -- which is the shape that made the
		WebSocket reader buffer indefinitely on ten bytes.
	**/
	public function testAnImpossibleLengthIsRefusedBeforeAnythingIsHeld():Void {
		var codec = new FrameCodec(1024);
		var header = new ByteArray();
		header.endian = crossbyte.io.Endian.BIG_ENDIAN;
		header.writeUnsignedInt(1024 * 1024 * 1024);
		header.position = 0;

		codec.feed(header);

		var refused:Bool = false;

		try {
			codec.next();
		} catch (e:IOError) {
			refused = true;
		}

		Assert.isTrue(refused, "a gigabyte was accepted against a limit of 1024 bytes");
		Assert.isTrue(codec.buffered <= FrameCodec.HEADER_SIZE,
			"the reader held " + codec.buffered + " bytes for a frame it refused");
	}

	/** A payload of exactly the limit is fine; one byte more is not. **/
	public function testTheLimitItselfIsAllowed():Void {
		var codec = new FrameCodec(64);
		codec.feed(FrameCodec.encode(counting(64)));

		var got = codec.next();
		Assert.notNull(got, "a payload of exactly the limit was refused");

		var over = new FrameCodec(64);
		over.feed(FrameCodec.encode(counting(65)));

		Assert.raises(function():Void {
			over.next();
		}, IOError);
	}

	/** An empty message is a message, not the absence of one. **/
	public function testAnEmptyMessageStillArrives():Void {
		var codec = new FrameCodec();
		codec.feed(FrameCodec.encode(new ByteArray()));

		var got = codec.next();

		Assert.notNull(got, "an empty message was swallowed");

		if (got != null) {
			Assert.equals(0, got.length);
		}
	}

	// ------------------------------------------------------------------

	static function same(a:ByteArray, b:ByteArray):Bool {
		if (a.length != b.length) {
			return false;
		}

		for (i in 0...a.length) {
			if (a[i] != b[i]) {
				return false;
			}
		}

		return true;
	}

	static function counting(length:Int):ByteArray {
		var bytes = new ByteArray();

		for (i in 0...length) {
			bytes.writeByte((i * 31 + 7) & 0xFF);
		}

		bytes.position = 0;
		return bytes;
	}

	static function slice(source:ByteArray, at:Int, length:Int):ByteArray {
		var out = new ByteArray();
		source.position = at;
		source.readBytes(out, 0, length);
		out.position = 0;
		return out;
	}
}
