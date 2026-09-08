package crossbyte._internal.http.h2;

import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import utest.Assert;
import crossbyte.test.Require;

/**
 * The HTTP/2 framing layer and client connection.
 *
 * Driven over a `BytesInput`/`BytesOutput` pair rather than a socket: the
 * whole state machine is a function of the bytes it is fed, so a canned server
 * side makes every case here deterministic and portable to targets that have
 * no sockets at all.
 */
class H2Test extends utest.Test {
	// ---------------------------------------------------------------- frames

	public function testFrameHeaderRoundTripsThroughTheWireFormat():Void {
		var payload:Bytes = Bytes.ofString("hello");
		var frame = new H2Frame(H2FrameType.DATA, H2Flags.END_STREAM, 1, payload);
		var encoded:Bytes = frame.toBytes();

		// 9-octet header plus the payload.
		Assert.equals(9 + 5, encoded.length);
		Assert.equals(5, H2Frame.lengthOf(encoded));

		var back:H2Frame = H2Frame.read(encoded);
		Assert.equals(H2FrameType.DATA, back.type);
		Assert.equals(1, back.streamId);
		Assert.isTrue(back.has(H2Flags.END_STREAM));
		Assert.equals("hello", back.payload.toString());
	}

	public function testReservedBitIsIgnoredOnReadAndClearedOnWrite():Void {
		var out = new BytesBuffer();
		// A stream id with the high bit set. §4.1 says a sender leaves the
		// reserved bit clear and a receiver ignores it, so the value must
		// survive as 31 bits rather than arriving negative.
		H2Frame.writeHeader(out, 0, H2FrameType.PING, 0, 0x7fffffff);
		var encoded:Bytes = out.getBytes();

		Assert.equals(0x7f, encoded.get(5));

		var withReserved:Bytes = encoded.sub(0, encoded.length);
		withReserved.set(5, 0xff);
		Assert.equals(0x7fffffff, H2Frame.read(withReserved).streamId);
	}

	public function testPaddingIsStrippedAndOverlongPaddingIsRejected():Void {
		// Pad length 3, two content bytes, three pad bytes.
		var padded:Bytes = Bytes.ofHex("0361620000" + "00");
		Assert.equals("ab", H2Frame.stripPadding(padded.sub(0, 6), 1).toString());

		// A pad length that swallows the payload must not be read as an empty
		// frame: the arithmetic would underflow into a huge length.
		Assert.raises(() -> H2Frame.stripPadding(Bytes.ofHex("ff6162"), 1), H2ConnectionError);
	}

	// -------------------------------------------------------------- settings

	public function testSettingsPayloadOnlyCarriesChangedValues():Void {
		var settings = new H2Settings();
		Assert.equals(0, settings.toPayload().length);

		settings.enablePush = false;
		settings.maxFrameSize = 32768;
		// Six octets per entry, two entries.
		Assert.equals(12, settings.toPayload().length);
	}

	public function testSettingsRoundTripAndUnknownIdentifiersAreIgnored():Void {
		var sent = new H2Settings();
		sent.enablePush = false;
		sent.initialWindowSize = 100000;
		sent.maxFrameSize = 32768;

		var received = new H2Settings();
		received.applyPayload(sent.toPayload());

		Assert.isFalse(received.enablePush);
		Assert.equals(100000, received.initialWindowSize);
		Assert.equals(32768, received.maxFrameSize);

		// Identifier 0xff is not assigned. §6.5.2 requires it be skipped, and
		// that is what makes the protocol extensible.
		received.applyPayload(Bytes.ofHex("00ff00000001"));
		Assert.equals(32768, received.maxFrameSize);
	}

	public function testSettingsRejectsOutOfRangeValues():Void {
		// Below the 16384 floor.
		Assert.raises(() -> new H2Settings().applyPayload(Bytes.ofHex("000500000100")), H2ConnectionError);
		// ENABLE_PUSH must be 0 or 1.
		Assert.raises(() -> new H2Settings().applyPayload(Bytes.ofHex("000200000002")), H2ConnectionError);
		// A payload that is not a multiple of six.
		Assert.raises(() -> new H2Settings().applyPayload(Bytes.ofHex("0005000001")), H2ConnectionError);
	}

	// ------------------------------------------------------------ connection

	public function testClientSendsPrefaceThenSettingsThenHeaders():Void {
		var server = new ServerScript();
		server.settings();
		var connection = server.connect();

		connection.request("GET", "http", "example.com", "/", []);
		var written:Bytes = server.written();

		// §3.4: the preface is the very first thing on the connection.
		Assert.equals(H2Connection.PREFACE, written.sub(0, H2Connection.PREFACE.length).toString());

		var frames:Array<H2Frame> = ServerScript.parseFrames(written, H2Connection.PREFACE.length);
		Assert.equals(H2FrameType.SETTINGS, frames[0].type);
		Assert.equals(0, frames[0].streamId);
		Assert.equals(H2FrameType.HEADERS, frames[1].type);
		// Client streams are odd and start at 1 (§5.1.1).
		Assert.equals(1, frames[1].streamId);
		Assert.isTrue(frames[1].has(H2Flags.END_HEADERS));
		// No body, so the request half closes immediately.
		Assert.isTrue(frames[1].has(H2Flags.END_STREAM));
	}

	public function testResponseHeadersAndBodyAreAssembled():Void {
		var server = new ServerScript();
		server.settings();
		server.response(1, [new HpackHeader(":status", "200"), new HpackHeader("content-type", "text/plain")], "hello", true);

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);
		connection.pumpUntilClosed(stream);

		Assert.equals(200, stream.status);
		Assert.equals("hello", stream.takeBody().toString());
		Assert.isTrue(stream.endOfStream);
		Assert.isTrue(stream.isClosed());

		// :status is consumed into the field above rather than left in the
		// list, so a caller never has to filter pseudo-headers out.
		Assert.equals(1, stream.headers.length);
		Assert.equals("content-type", stream.headers[0].name);
	}

	public function testSettingsFromThePeerAreAcknowledged():Void {
		var server = new ServerScript();
		server.settings();
		server.response(1, [new HpackHeader(":status", "204")], "", true);

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);
		connection.pumpUntilClosed(stream);

		var frames:Array<H2Frame> = ServerScript.parseFrames(server.written(), H2Connection.PREFACE.length);
		var acked:Bool = false;
		for (frame in frames) {
			if (frame.type == H2FrameType.SETTINGS && frame.has(H2Flags.ACK)) {
				acked = true;
				Assert.equals(0, frame.payload.length);
			}
		}
		Assert.isTrue(acked);
	}

	public function testHeaderBlockSplitAcrossContinuationIsReassembled():Void {
		var server = new ServerScript();
		server.settings();
		server.splitResponse(1, [new HpackHeader(":status", "200"), new HpackHeader("x-long", "0123456789abcdef")]);
		server.data(1, "body", true);

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);
		connection.pumpUntilClosed(stream);

		Assert.equals(200, stream.status);
		Assert.equals("0123456789abcdef", stream.headers[0].value);
		Assert.equals("body", stream.takeBody().toString());
	}

	public function testFrameInterleavedIntoAHeaderBlockIsRejected():Void {
		var server = new ServerScript();
		server.settings();
		// A HEADERS without END_HEADERS, then a PING before the CONTINUATION.
		// §6.10 forbids this outright -- and a PING is exactly the frame an
		// implementation is most likely to wave through, since it is
		// otherwise always legal.
		server.rawHeaders(1, [new HpackHeader(":status", "200")], false);
		server.ping();

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);

		Assert.raises(() -> connection.pumpUntilClosed(stream), H2ConnectionError);
	}

	public function testContinuationWithoutHeadersIsRejected():Void {
		var server = new ServerScript();
		server.settings();
		server.frame(H2FrameType.CONTINUATION, H2Flags.END_HEADERS, 1, Bytes.alloc(0));

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);

		Assert.raises(() -> connection.pumpUntilClosed(stream), H2ConnectionError);
	}

	public function testOversizedFrameIsRejectedBeforeItIsAllocated():Void {
		var server = new ServerScript();
		server.settings();
		// A header claiming 100000 bytes against our 16384 default. The length
		// field is 24 bits, so honouring it would mean allocating whatever the
		// peer asked for.
		var out = new BytesBuffer();
		H2Frame.writeHeader(out, 100000, H2FrameType.DATA, 0, 1);
		server.raw(out.getBytes());

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);

		Assert.raises(() -> connection.pumpUntilClosed(stream), H2ConnectionError);
	}

	public function testPingIsEchoedWithTheAckFlag():Void {
		var server = new ServerScript();
		server.settings();
		server.ping();
		server.response(1, [new HpackHeader(":status", "200")], "", true);

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);
		connection.pumpUntilClosed(stream);

		var echoed:H2Frame = null;
		for (frame in ServerScript.parseFrames(server.written(), H2Connection.PREFACE.length)) {
			if (frame.type == H2FrameType.PING && frame.has(H2Flags.ACK)) {
				echoed = frame;
			}
		}

		Require.notNull(echoed);
		// §6.7: the opaque data comes back byte for byte.
		Assert.equals("0102030405060708", echoed.payload.toHex());
	}

	public function testRstStreamClosesOnlyThatStream():Void {
		var server = new ServerScript();
		server.settings();
		server.rstStream(1, H2ErrorCode.REFUSED_STREAM);

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);
		connection.pumpUntilClosed(stream);

		Assert.isTrue(stream.isClosed());
		Assert.equals(H2ErrorCode.REFUSED_STREAM, stream.resetCode);
		// The connection itself is still usable, which is the whole point of
		// the stream/connection error split in §5.4.
		Assert.isNull(connection.goAwayCode);
	}

	public function testGoAwayRefusesStreamsAboveTheLastProcessedId():Void {
		var server = new ServerScript();
		server.settings();
		server.goAway(1, H2ErrorCode.NO_ERROR);

		var connection = server.connect();
		var first = connection.request("GET", "http", "example.com", "/a", []);
		var second = connection.request("GET", "http", "example.com", "/b", []);
		connection.pumpUntilClosed(second);

		Assert.equals(H2ErrorCode.NO_ERROR, connection.goAwayCode);
		Assert.equals(1, connection.goAwayLastStreamId);

		// Stream 3 is above the last id the peer processed, so it was never
		// handled and is safe to retry. Stream 1 may have been.
		Assert.isTrue(second.isClosed());
		Assert.equals(H2ErrorCode.REFUSED_STREAM, second.resetCode);
		Assert.isNull(first.resetCode);
	}

	public function testWindowUpdateIsSentOnceHalfTheWindowIsConsumed():Void {
		var server = new ServerScript();
		server.settings();

		// Default window is 65535, so ~40 KB of body crosses the halfway mark.
		var chunk:String = StringTools.rpad("", "x", 8192);
		server.rawHeaders(1, [new HpackHeader(":status", "200")], true);
		for (_ in 0...5) {
			server.data(1, chunk, false);
		}
		server.data(1, "end", true);

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);
		connection.pumpUntilClosed(stream);

		Assert.equals(8192 * 5 + 3, stream.bodyLength);

		var connectionUpdates:Int = 0;
		var streamUpdates:Int = 0;
		for (frame in ServerScript.parseFrames(server.written(), H2Connection.PREFACE.length)) {
			if (frame.type == H2FrameType.WINDOW_UPDATE) {
				if (frame.streamId == 0) {
					connectionUpdates++;
				} else {
					streamUpdates++;
				}
			}
		}

		// Both windows have to be replenished. Topping up only the stream is a
		// stall that appears solely on transfers past 64 KB, which is exactly
		// the kind that never shows up in a small test.
		Assert.isTrue(connectionUpdates > 0);
		Assert.isTrue(streamUpdates > 0);
	}

	public function testZeroWindowUpdateOnTheConnectionIsFatal():Void {
		var server = new ServerScript();
		server.settings();
		server.frame(H2FrameType.WINDOW_UPDATE, 0, 0, Bytes.ofHex("00000000"));

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);

		Assert.raises(() -> connection.pumpUntilClosed(stream), H2ConnectionError);
	}

	public function testRequestBodyIsSentAsDataWithEndStream():Void {
		var server = new ServerScript();
		server.settings();
		server.response(1, [new HpackHeader(":status", "200")], "", true);

		var connection = server.connect();
		var stream = connection.request("POST", "http", "example.com", "/submit", [new HpackHeader("content-type", "text/plain")],
			Bytes.ofString("payload"));
		connection.pumpUntilClosed(stream);

		var frames:Array<H2Frame> = ServerScript.parseFrames(server.written(), H2Connection.PREFACE.length);
		var headers:H2Frame = null;
		var data:H2Frame = null;
		for (frame in frames) {
			if (frame.type == H2FrameType.HEADERS) {
				headers = frame;
			}
			if (frame.type == H2FrameType.DATA) {
				data = frame;
			}
		}

		Require.notNull(headers);
		// With a body, HEADERS must not carry END_STREAM -- the DATA does.
		Assert.isFalse(headers.has(H2Flags.END_STREAM));
		Require.notNull(data);
		Assert.equals("payload", data.payload.toString());
		Assert.isTrue(data.has(H2Flags.END_STREAM));
	}

	public function testPushPromiseIsRejectedWhenPushIsDisabled():Void {
		var server = new ServerScript();
		server.settings();
		// We advertise ENABLE_PUSH=0, so §8.4 makes this a connection error
		// rather than something to ignore.
		server.frame(H2FrameType.PUSH_PROMISE, H2Flags.END_HEADERS, 1, Bytes.ofHex("00000002"));

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);

		Assert.raises(() -> connection.pumpUntilClosed(stream), H2ConnectionError);
	}

	public function testUnknownFrameTypeIsDiscarded():Void {
		var server = new ServerScript();
		server.settings();
		// §4.1 requires an unrecognised type be ignored, which is what allows
		// extensions to be deployed without breaking existing peers.
		server.frame(0x63, 0, 0, Bytes.ofString("extension"));
		server.response(1, [new HpackHeader(":status", "200")], "ok", true);

		var connection = server.connect();
		var stream = connection.request("GET", "http", "example.com", "/", []);
		connection.pumpUntilClosed(stream);

		Assert.equals(200, stream.status);
		Assert.equals("ok", stream.takeBody().toString());
	}
}

/**
 * A canned server side.
 *
 * Frames are queued in order and handed to the connection as one input
 * stream, which is enough to script every case above without a socket.
 */
private class ServerScript {
	private var __out:BytesBuffer = new BytesBuffer();
	private var __encoder:HpackEncoder = new HpackEncoder(4096);
	private var __sink:BytesOutput;

	public function new() {}

	public function connect():H2Connection {
		__sink = new BytesOutput();

		var settings = new H2Settings();
		// Matches the client default and keeps PUSH_PROMISE a protocol error.
		settings.enablePush = false;

		return new H2Connection(new BytesInput(__out.getBytes()), __sink, settings);
	}

	public function written():Bytes {
		return __sink.getBytes();
	}

	public function raw(bytes:Bytes):Void {
		__out.addBytes(bytes, 0, bytes.length);
	}

	public function frame(type:H2FrameType, flags:Int, streamId:Int, payload:Bytes):Void {
		H2Frame.writeHeader(__out, payload.length, type, flags, streamId);
		if (payload.length > 0) {
			__out.addBytes(payload, 0, payload.length);
		}
	}

	public function settings():Void {
		frame(H2FrameType.SETTINGS, 0, 0, Bytes.alloc(0));
	}

	public function ping():Void {
		frame(H2FrameType.PING, 0, 0, Bytes.ofHex("0102030405060708"));
	}

	public function rstStream(streamId:Int, code:H2ErrorCode):Void {
		var payload = Bytes.alloc(4);
		payload.set(3, cast code);
		frame(H2FrameType.RST_STREAM, 0, streamId, payload);
	}

	public function goAway(lastStreamId:Int, code:H2ErrorCode):Void {
		var payload = Bytes.alloc(8);
		payload.set(3, lastStreamId);
		payload.set(7, cast code);
		frame(H2FrameType.GOAWAY, 0, 0, payload);
	}

	public function rawHeaders(streamId:Int, headers:Array<HpackHeader>, endHeaders:Bool):Void {
		var flags:Int = endHeaders ? H2Flags.END_HEADERS : 0;
		frame(H2FrameType.HEADERS, flags, streamId, __encoder.encode(headers));
	}

	public function data(streamId:Int, body:String, endStream:Bool):Void {
		frame(H2FrameType.DATA, endStream ? H2Flags.END_STREAM : 0, streamId, Bytes.ofString(body));
	}

	public function response(streamId:Int, headers:Array<HpackHeader>, body:String, endStream:Bool):Void {
		var hasBody:Bool = body.length > 0;
		frame(H2FrameType.HEADERS, H2Flags.END_HEADERS | ((!hasBody && endStream) ? H2Flags.END_STREAM : 0), streamId, __encoder.encode(headers));
		if (hasBody) {
			data(streamId, body, endStream);
		}
	}

	/** A header block deliberately split across HEADERS and CONTINUATION. */
	public function splitResponse(streamId:Int, headers:Array<HpackHeader>):Void {
		var block:Bytes = __encoder.encode(headers);
		var half:Int = block.length >> 1;

		frame(H2FrameType.HEADERS, 0, streamId, block.sub(0, half));
		frame(H2FrameType.CONTINUATION, H2Flags.END_HEADERS, streamId, block.sub(half, block.length - half));
	}

	public static function parseFrames(bytes:Bytes, offset:Int):Array<H2Frame> {
		var out:Array<H2Frame> = [];
		var position:Int = offset;

		while (position + H2Frame.HEADER_SIZE <= bytes.length) {
			var length:Int = H2Frame.lengthOf(bytes, position);
			if (position + H2Frame.HEADER_SIZE + length > bytes.length) {
				break;
			}
			out.push(H2Frame.read(bytes, position));
			position += H2Frame.HEADER_SIZE + length;
		}

		return out;
	}
}
