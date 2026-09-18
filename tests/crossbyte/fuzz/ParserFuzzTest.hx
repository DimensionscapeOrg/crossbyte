package crossbyte.fuzz;

import crossbyte._internal.deflatex.Deflater;
import crossbyte._internal.deflatex.Inflater;
import crossbyte._internal.http.h2.hpack.HpackDecoder;
import crossbyte._internal.http.h2.hpack.HpackEncoder;
import crossbyte._internal.http.h2.hpack.HpackHeader;
import crossbyte._internal.http.h2.hpack.HpackHuffman;
import crossbyte._internal.lz4.Lz4;
import crossbyte.db.postgres._internal.PostgresWire;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.stun.StunMessage;
import crossbyte.net.rtc._internal.sctp.DcepMessage;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import haxe.io.Bytes;
import utest.Assert;

/**
 * Hands every parser that reads bytes off a wire a great many inputs nobody
 * meant it to see, and asserts the process is still here afterwards.
 *
 * Each of these decodes something a remote peer chose: a STUN binding from any
 * host that can reach the socket, an SCTP chunk from a browser's data channel,
 * an HPACK block from an HTTP/2 client, a compressed body from a server the
 * caller merely named. Reading such a parser is how most of its bugs are
 * found, and reading is exactly what missed the two that turned up in this
 * codebase by other means: a length that overflowed when added to a position,
 * and a decoder with no ceiling on what it would allocate.
 *
 * **Throwing is a pass.** A parser handed nonsense is entitled to refuse it,
 * loudly, and every call here is wrapped. What is not allowed is to crash the
 * process, to run away with the clock, or to return a result larger than the
 * ceiling it was given. The first of those is asserted by this file finishing
 * at all -- on cpp a bad read takes the whole runner with it -- and the other
 * two are measured.
 *
 * Inputs come three ways, and the last two matter most. Random bytes mostly
 * bounce off the first length or magic check. Truncating a *valid* encoding
 * walks the parser to the end of every field it reads, which is where a
 * missing bounds check lives. Flipping one byte of a valid encoding keeps the
 * shape and changes a number, which is where a length field that is trusted
 * shows itself.
 *
 * The generator is a seeded xorshift rather than `Math.random`, so a failure
 * reproduces from the seed printed beside it.
 */
class ParserFuzzTest extends utest.Test {
	/** Inputs per parser per strategy. Enough to be worth running in CI. **/
	private static inline var ROUNDS:Int = 400;

	/** No single input may take longer than this. A parser that does is looping. **/
	private static inline var SLOWEST_INPUT_SECONDS:Float = 2.0;

	/** The ceiling handed to the decompressors, and asserted against. **/
	private static inline var CEILING:Int = 64 * 1024;

	private var __state:Int;

	public function setup():Void {
		// Fixed, so a red run is reproducible. Change it to widen the search.
		__state = 0x5EED1234;
	}

	public function testEverySeedStillDecodes():Void {
		// The canary for this whole file. The truncation and mutation passes
		// are only worth anything while the thing being truncated and mutated
		// is a message the parser accepts; a seed that stops decoding turns
		// both of them into several thousand ways of testing one early
		// rejection, and nothing would say so.
		for (parser in __parsers()) {
			var seed:Bytes = parser.seed();
			if (seed == null) {
				continue;
			}

			try {
				var decoded:Dynamic = parser.run(seed);
				Assert.notNull(decoded, parser.name + " returned null for its own seed corpus");
			} catch (e:Dynamic) {
				Assert.fail(parser.name + " cannot decode its own seed corpus: " + Std.string(e));
			}
		}
	}

	public function testParsersSurviveRandomBytes():Void {
		for (parser in __parsers()) {
			for (round in 0...ROUNDS) {
				__feed(parser, __randomBytes(__nextInt(0, 512)), "random", round);
			}
		}

		Assert.pass("every parser survived random input");
	}

	public function testParsersSurviveTruncatedValidInput():Void {
		// Every prefix of a valid encoding, which walks each parser to the end
		// of every field it reads and one byte short of it.
		for (parser in __parsers()) {
			var seed:Bytes = parser.seed();
			if (seed == null || seed.length == 0) {
				continue;
			}

			for (length in 0...seed.length) {
				__feed(parser, seed.sub(0, length), "truncated to " + length, length);
			}
		}

		Assert.pass("every parser survived a truncated valid encoding");
	}

	public function testParsersSurviveSingleByteMutations():Void {
		// The shape stays valid and a number changes, which is how a length
		// field that is believed rather than checked gives itself away.
		for (parser in __parsers()) {
			var seed:Bytes = parser.seed();
			if (seed == null || seed.length == 0) {
				continue;
			}

			for (round in 0...ROUNDS) {
				var mutant:Bytes = seed.sub(0, seed.length);
				var at:Int = __nextInt(0, mutant.length);
				mutant.set(at, __nextInt(0, 256));
				__feed(parser, mutant, "byte " + at + " mutated", round);
			}
		}

		Assert.pass("every parser survived a mutated valid encoding");
	}

	public function testDecompressorsNeverExceedTheirCeiling():Void {
		// The guard these grew this month. A decoder that refuses only after
		// it has finished allocating has already spent what the ceiling was
		// there to protect.
		var bombs:Array<{name:String, run:Bytes->Int}> = [
			{name: "Lz4", run: b -> Lz4.decompress(b, CEILING).length},
			{name: "Inflater", run: b -> Inflater.apply(b, CEILING).length},
		];

		var zeros:Bytes = Bytes.alloc(CEILING * 4);

		for (bomb in bombs) {
			// A real bomb first: four times the ceiling from a tiny stream.
			var packed:Bytes = bomb.name == "Lz4" ? Lz4.compress(zeros) : Deflater.apply(zeros);
			Assert.raises(() -> bomb.run(packed), null, bomb.name + " decoded past its ceiling");

			// Then nonsense, which must either refuse or stay inside it.
			for (round in 0...ROUNDS) {
				var input:Bytes = __randomBytes(__nextInt(0, 256));
				try {
					var produced:Int = bomb.run(input);
					Assert.isTrue(produced <= CEILING, bomb.name + " returned " + produced + " bytes past a ceiling of " + CEILING);
				} catch (_:Dynamic) {
					// Refusing is the other correct answer.
				}
			}
		}
	}

	// --- the parsers under test ------------------------------------------

	private function __parsers():Array<Parser> {
		return [
			{
				name: "StunMessage.decode",
				seed: () -> __stunSeed(),
				run: b -> StunMessage.decode(ByteArray.fromBytes(b))
			},
			{
				name: "SctpPacket.decode",
				// verify:false on purpose. With the checksum on, almost every
				// input is refused before the chunk walk this is here to
				// exercise, and the fuzzer would be testing one CRC.
				seed: () -> __sctpSeed(),
				run: b -> SctpPacket.decode(ByteArray.fromBytes(b), false)
			},
			{
				name: "DcepMessage.decode",
				seed: () -> __dcepSeed(),
				run: b -> DcepMessage.decode(ByteArray.fromBytes(b))
			},
			{
				name: "HpackDecoder.decode",
				seed: () -> __hpackSeed(),
				run: b -> new HpackDecoder().decode(b)
			},
			{
				name: "HpackHuffman.decode",
				seed: () -> __hpackSeed(),
				run: b -> HpackHuffman.decode(b, 0, b.length)
			},
			{
				name: "Inflater.apply",
				seed: () -> Deflater.apply(Bytes.ofString("the quick brown fox jumps over the lazy dog")),
				run: b -> Inflater.apply(b, CEILING)
			},
			{
				name: "Lz4.decompress",
				seed: () -> Lz4.compress(Bytes.ofString("the quick brown fox jumps over the lazy dog")),
				run: b -> Lz4.decompress(b, CEILING)
			},
			{
				name: "PostgresWire.decodeResult",
				seed: () -> null,
				run: b -> PostgresWire.decodeResult(b)
			},
			{
				name: "PostgresWire.decodeByteaHex",
				seed: () -> Bytes.ofString("\\xdeadbeef"),
				run: b -> PostgresWire.decodeByteaHex(b)
			}
		];
	}

	private function __stunSeed():Bytes {
		var transactionId:ByteArray = new ByteArray();
		for (i in 0...12) {
			transactionId.writeByte(i);
		}

		return new StunMessage(0x0001, transactionId).encode();
	}

	private function __sctpSeed():Bytes {
		return new SctpPacket(5000, 5000, 0x12345678).encode();
	}

	private function __dcepSeed():Bytes {
		return new DcepMessage(0x03, 0x00, 0, 0, "chat", "json").encode();
	}

	private function __hpackSeed():Bytes {
		return new HpackEncoder().encode([
			new HpackHeader(":method", "GET"),
			new HpackHeader(":path", "/"),
			new HpackHeader("user-agent", "crossbyte-fuzz")
		]);
	}

	// --- running one input ------------------------------------------------

	private function __feed(parser:Parser, input:Bytes, how:String, round:Int):Void {
		var started:Float = haxe.Timer.stamp();

		try {
			parser.run(input);
		} catch (_:Dynamic) {
			// Refusing is a pass. The failures this hunts are the ones that
			// never reach a catch: a bad read, or a loop that does not end.
		}

		var elapsed:Float = haxe.Timer.stamp() - started;
		if (elapsed > SLOWEST_INPUT_SECONDS) {
			Assert.fail(parser.name + " took " + elapsed + "s on one input (" + how + ", round " + round + ", seed 0x5EED1234): " + __hexOf(input));
		}
	}

	// --- deterministic input ---------------------------------------------

	/** xorshift32. Seeded, because "it failed once on my machine" is not a bug report. **/
	private function __next():Int {
		__state ^= __state << 13;
		__state ^= __state >>> 17;
		__state ^= __state << 5;
		return __state;
	}

	private function __nextInt(low:Int, high:Int):Int {
		if (high <= low) {
			return low;
		}

		var span:Int = high - low;
		var value:Int = __next();
		if (value < 0) {
			value = -(value + 1);
		}

		return low + (value % span);
	}

	private function __randomBytes(length:Int):Bytes {
		var out:Bytes = Bytes.alloc(length);
		for (i in 0...length) {
			out.set(i, __nextInt(0, 256));
		}

		return out;
	}

	private function __hexOf(input:Bytes):String {
		var out:StringBuf = new StringBuf();
		var shown:Int = input.length < 64 ? input.length : 64;

		for (i in 0...shown) {
			out.add(StringTools.hex(input.get(i), 2));
		}

		if (shown < input.length) {
			out.add("... (" + input.length + " bytes)");
		}

		return out.toString();
	}
}

private typedef Parser = {
	var name:String;
	var seed:Void->Null<Bytes>;
	var run:Bytes->Dynamic;
};
