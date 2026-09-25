import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.io.BitReader;
import crossbyte.io.BitWriter;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net.rtc._internal.ClientHelloAssembly;
import crossbyte.net.rtc._internal.sctp.Crc32c;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.net.rtc._internal.sctp.SctpPacket.SctpChunk;
import haxe.io.Bytes;

/**
	The performance suite: what the critical paths cost, measured rather than
	assumed.

	Each case is one operation the framework performs per unit of real work --
	per datagram, per connectivity check, per event, per message -- so a
	regression here is a regression multiplied by traffic. The harness reports
	the best of several samples; see `Bench` for why.

	Run it natively (`haxe ci/bench.hxml`, then the exe in `export/bench`);
	numbers from other targets measure those targets, which is occasionally the
	question but usually not. CI runs it so it cannot rot, and ignores the
	numbers, because a shared runner's timings gate nothing honestly.

	It found real waste on its first run: the DTLS transport was copying every
	record byte-at-a-time -- seven times the cost of the blit that replaced it,
	on every datagram of every connection.
**/
@:access(crossbyte.core.CrossByte)
class BenchMain {
	static function main():Void {
		new CrossByte(true, DEFAULT, true);

		Sys.println("CrossByte performance suite -- best of 5 samples, calibrated reps");
		Bench.header();

		byteArray();
		bitPacking();
		reliableFrames();
		checksumsAndHashes();
		stun();
		sctp();
		dtlsFraming();
		eventsAndFutures();

		Sys.println("");
		Sys.println("done. Numbers compare shapes of code on this machine today;");
		Sys.println("they are not comparable across machines or days.");
	}

	// ------------------------------------------------------------------

	static function byteArray():Void {
		Bench.section("ByteArray");

		var kilobyte = filled(1024);
		var four = filled(4096);

		Bench.run("writeByte x1024 (stream build)", function():Void {
			var out = new ByteArray();

			for (i in 0...1024) {
				out.writeByte(i & 0xFF);
			}
		}, 1024);

		Bench.run("writeBytes 4KB (blit append)", function():Void {
			var out = new ByteArray();
			out.writeBytes(four, 0, four.length);
		}, 4096);

		Bench.run("readInt x256 (big-endian stream)", function():Void {
			kilobyte.position = 0;

			for (_ in 0...256) {
				kilobyte.readInt();
			}
		}, 1024);

		Bench.run("readUnsignedByte x1024", function():Void {
			kilobyte.position = 0;

			for (_ in 0...1024) {
				kilobyte.readUnsignedByte();
			}
		}, 1024);

		// Big-endian is the network order and the one that pays for a swap;
		// little-endian is the bare word load.
		var little = filled(1024);
		little.endian = crossbyte.io.Endian.LITTLE_ENDIAN;

		Bench.run("readInt x256 (little-endian, no swap)", function():Void {
			little.position = 0;

			for (_ in 0...256) {
				little.readInt();
			}
		}, 1024);

		Bench.run("writeInt x256 (big-endian stream)", function():Void {
			var out = new ByteArray();

			for (i in 0...256) {
				out.writeInt(i);
			}
		}, 1024);
	}

	/**
		A snapshot of 64 view slots, the shape the arena sample sends every
		step: a 10-bit slot, a 4-bit generation, x and y to 12 bits each and a
		flag -- 39 bits a record packed, against the same values written
		byte-aligned at 8 bytes a record, which is what the arena does.
	**/
	static function bitPacking():Void {
		Bench.section("Bits");

		var records = 64;
		var slots = [for (i in 0...records) (i * 37) & 0x3FF];
		var generations = [for (i in 0...records) i & 0xF];
		var xs = [for (i in 0...records) (i * 613) & 0xFFF];
		var ys = [for (i in 0...records) (i * 911) & 0xFFF];
		var moving = [for (i in 0...records) (i & 1) == 1];
		var worldXs = [for (i in 0...records) xs[i] * (2000 / 4095)];
		var worldYs = [for (i in 0...records) ys[i] * (2000 / 4095)];

		var writer = new BitWriter();
		Bench.run("pack 64 records x 39 bits", function():Void {
			writer.reset();
			for (i in 0...records) {
				writer.writeBits(slots[i], 10);
				writer.writeBits(generations[i], 4);
				writer.writeBits(xs[i], 12);
				writer.writeBits(ys[i], 12);
				writer.writeBool(moving[i]);
			}
			writer.finish();
		});

		Bench.run("pack 64, positions quantized from floats", function():Void {
			writer.reset();
			for (i in 0...records) {
				writer.writeBits(slots[i], 10);
				writer.writeBits(generations[i], 4);
				writer.writeQuantized(worldXs[i], 0, 2000, 12);
				writer.writeQuantized(worldYs[i], 0, 2000, 12);
				writer.writeBool(moving[i]);
			}
			writer.finish();
		});

		var aligned = new ByteArray();
		Bench.run("byte-aligned 64 records x 8 bytes", function():Void {
			aligned.position = 0;
			for (i in 0...records) {
				aligned.writeShort(slots[i]);
				aligned.writeByte(generations[i]);
				aligned.writeShort(xs[i]);
				aligned.writeShort(ys[i]);
				aligned.writeByte(moving[i] ? 1 : 0);
			}
		});

		var packed = writer.toByteArray();
		var reader = new BitReader();
		var sink = 0;
		Bench.run("unpack 64 records x 39 bits", function():Void {
			reader.reset(packed);
			for (_ in 0...records) {
				sink += reader.readBits(10);
				sink += reader.readBits(4);
				sink += reader.readBits(12);
				sink += reader.readBits(12);
				sink += reader.readBool() ? 1 : 0;
			}
		});

		Bench.run("byte-aligned read 64 records", function():Void {
			aligned.position = 0;
			for (_ in 0...records) {
				sink += aligned.readShort();
				sink += aligned.readByte();
				sink += aligned.readShort();
				sink += aligned.readShort();
				sink += aligned.readByte();
			}
		});

		// The sink is printed so no target can decide the reads do nothing.
		Sys.println("  (" + packed.length + " bytes packed against " + aligned.length + " byte-aligned; sink " + (sink & 0xFF) + ")");
	}

	/** One reliable datagram frame, per packet sent and per packet heard. **/
	static function reliableFrames():Void {
		Bench.section("RUDP");

		var payload = filled(100);
		var scratch = new ByteArray();
		scratch.length = ReliableDatagramProtocol.MAX_FRAME_SIZE;

		Bench.run("encode a 100B frame into the scratch", function():Void {
			ReliableDatagramProtocol.encodeInto(scratch, PACKET, 12345, payload, 0, 100, false, 678, false);
		});

		Bench.run("encode a 100B frame of its own", function():Void {
			ReliableDatagramProtocol.encode(PACKET, 12345, payload, false, 678);
		});

		var frame = ReliableDatagramProtocol.encode(PACKET, 12345, payload, false, 678);
		Bench.run("decode a 100B frame", function():Void {
			ReliableDatagramProtocol.decode(frame);
		});
	}

	static function checksumsAndHashes():Void {
		Bench.section("Checksums");

		var datagram = filled(1200);
		var chunk = filled(65536);

		Bench.run("CRC-32C over 1200B (per SCTP packet)", function():Void {
			Crc32c.of(datagram);
		}, 1200);

		#if cpp
		Bench.run("BLAKE3 over 64KB (native extension)", function():Void {
			crossbyte.crypto.Blake3.hash(chunk);
		}, 65536);
		#end

		// The portable backend unless `crossbyte-lz4` is installed and
		// `-D crossbyte_lz4_native` is set, in which case this measures that
		// instead -- worth knowing before reading the number as the ceiling.
		Bench.run("LZ4 round trip 64KB", function():Void {
			var work = new ByteArray();
			work.writeBytes(chunk, 0, chunk.length);
			work.compress(LZ4);
			work.uncompress(LZ4);
		}, 65536);
	}

	static function stun():Void {
		Bench.section("STUN");

		var password = "VOkJxbRl1RmTxUk/WvJxBt";
		var request = StunMessage.bindingRequest();
		request.attributes.push(StunMessage.username("evtj:h6vY"));
		request.attributes.push(StunMessage.priority(1862270975));
		var signed = request.encodeSigned(password);

		Bench.run("encodeSigned (HMAC-SHA1, per check sent)", function():Void {
			request.encodeSigned(password);
		}, signed.length);

		Bench.run("decode + verifyIntegrity (per check heard)", function():Void {
			signed.position = 0;
			var message = StunMessage.decode(signed);
			message.verifyIntegrity(password);
		}, signed.length);
	}

	static function sctp():Void {
		Bench.section("SCTP");

		var payload = filled(1024);
		var chunk = new SctpChunk(0, 3, payload);
		var packet = new SctpPacket(5000, 5000, 0x12345678, [chunk]);
		var encoded = packet.encode();

		Bench.run("encode 1KB DATA packet (per chunk sent)", function():Void {
			packet.encode();
		}, encoded.length);

		Bench.run("decode + checksum (per chunk heard)", function():Void {
			encoded.position = 0;
			SctpPacket.decode(encoded);
		}, encoded.length);
	}

	static function dtlsFraming():Void {
		Bench.section("DTLS");

		// An application-data record: the shape of every datagram after the
		// handshake, and the one the ClientHello assembly must wave through.
		var record = Bytes.alloc(1213);
		record.set(0, 23);
		record.set(1, 0xFE);
		record.set(2, 0xFD);
		record.set(11, (1200 >> 8) & 0xFF);
		record.set(12, 1200 & 0xFF);

		var assembly = new ClientHelloAssembly();

		Bench.run("assembly pass-through (per server datagram)", function():Void {
			assembly.accept(record);
		}, record.length);

		// And the path that does the work: a ClientHello the size Chrome
		// sends, arriving in pieces. Worth its own figure because what a
		// fragment costs depends on how many are already held, so this is
		// where a change that reintroduced a per-fragment pass over the whole
		// of them would show up rather than in the line above.
		var message = Bytes.alloc(1413);

		for (i in 0...message.length) {
			message.set(i, (i * 31 + 7) & 0xFF);
		}

		var pieces:Array<Bytes> = [];
		var offset:Int = 0;

		while (offset < message.length) {
			var carried:Int = offset + 400 <= message.length ? 400 : message.length - offset;
			pieces.push(clientHelloFragment(message, offset, carried));
			offset += carried;
		}

		var fragmented = new ClientHelloAssembly();
		var carriedBytes:Int = 0;

		for (piece in pieces) {
			carriedBytes += piece.length;
		}

		Bench.run("assembly of a fragmented ClientHello (per handshake)", function():Void {
			for (piece in pieces) {
				fragmented.accept(piece);
			}
		}, carriedBytes);
	}

	/** One DTLS record carrying one fragment of a ClientHello. **/
	static function clientHelloFragment(message:Bytes, offset:Int, length:Int):Bytes {
		var record = Bytes.alloc(ClientHelloAssembly.RECORD_HEADER + ClientHelloAssembly.HANDSHAKE_HEADER + length);

		record.set(0, 22);
		record.set(1, 0xFE);
		record.set(2, 0xFD);
		record.set(11, ((ClientHelloAssembly.HANDSHAKE_HEADER + length) >> 8) & 0xFF);
		record.set(12, (ClientHelloAssembly.HANDSHAKE_HEADER + length) & 0xFF);

		var body = ClientHelloAssembly.RECORD_HEADER;
		record.set(body, 1);
		writeUint24(record, body + 1, message.length);
		writeUint24(record, body + 6, offset);
		writeUint24(record, body + 9, length);
		record.blit(body + ClientHelloAssembly.HANDSHAKE_HEADER, message, offset, length);

		return record;
	}

	static function writeUint24(bytes:Bytes, at:Int, value:Int):Void {
		bytes.set(at, (value >> 16) & 0xFF);
		bytes.set(at + 1, (value >> 8) & 0xFF);
		bytes.set(at + 2, value & 0xFF);
	}

	static function eventsAndFutures():Void {
		Bench.section("Events");

		var one = new EventDispatcher();
		one.addEventListener("bench", function(_:Event):Void {});

		var eight = new EventDispatcher();

		for (_ in 0...8) {
			eight.addEventListener("bench", function(_:Event):Void {});
		}

		var event = new Event("bench");

		Bench.run("dispatch, 1 listener", function():Void {
			one.dispatchEvent(event);
		});

		Bench.run("dispatch, 8 listeners", function():Void {
			eight.dispatchEvent(event);
		});

		Bench.section("Future");

		Bench.run("new + then + resolve", function():Void {
			var future = new crossbyte.Future<Int>();
			future.then(function(_:Int):Void {}, function(_:String):Void {});
			@:privateAccess future.__resolve(1);
		});
	}

	// ------------------------------------------------------------------

	static function filled(length:Int):ByteArray {
		var out = new ByteArray();

		for (i in 0...length) {
			out.writeByte((i * 31 + 7) & 0xFF);
		}

		out.position = 0;
		return out;
	}
}
