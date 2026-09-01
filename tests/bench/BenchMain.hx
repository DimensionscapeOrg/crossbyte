import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.io.ByteArray;
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
