package crossbyte.fuzz;

import crossbyte.io.ByteArray;
import crossbyte.net.rtc._internal.sctp.SctpAssociation;
import crossbyte.net.rtc._internal.sctp.SctpAssociationState;
import crossbyte.net.rtc._internal.sctp.SctpDataChunk;
import crossbyte.net.rtc._internal.sctp.SctpDataTransfer;
import crossbyte.net.rtc._internal.sctp.SctpPacket;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;

/**
	Sends an established association traffic nobody meant it to see, then asks
	what it is still holding.

	`ParserFuzzTest` already hands `SctpPacket.decode` nonsense as a pure
	function. What it cannot reach is the state each side accumulates *across*
	packets -- the reassembly buffer, the ordering queue, the record of which
	transmission numbers have arrived. That state is where every SCTP bug found
	in this codebase has been.

	**The assertion is what is left over, not that nothing crashed.** Three
	separate unbounded-growth bugs lived here and every one of them passed a
	green suite: `__received` kept every chunk ever accepted, `__partial` kept
	the fragments of a message the peer never finished, and `__held` kept
	messages waiting on a stream sequence that never came. A receiver with all
	three faults still delivers messages perfectly and still answers afterwards.
	It only grows, at whatever rate the peer chooses, until the process dies.

	All three were found by sweeping the source by hand, which works once per
	pattern and then stops working. This is the part that keeps working.
**/
class SctpWireFuzzTest extends utest.Test {
	/** Malformed packets before the association is asked to prove it is well. **/
	private static inline var ROUNDS:Int = 200;

	/**
		Adversarial-but-legal chunks.

		Sized so the two bounded collections are actually pushed past their
		bounds: a third of these land on each shape, and at `FRAGMENT` bytes
		apiece that is comfortably more than `MAX_REASSEMBLY` and `MAX_HELD`.
		A gentler run would pass whether or not the bounds existed.
	**/
	private static inline var RETENTION_ROUNDS:Int = 600;

	private static inline var FRAGMENT:Int = 8192;

	private var __state:Int;

	private function unsupported():Bool {
		if (!SctpAssociation.isSupported) {
			Assert.isFalse(SctpAssociation.isSupported);
			return true;
		}

		return false;
	}

	public function setup():Void {
		// Seeded, so a red run reproduces.
		__state = 0x5C79A11E;
	}

	/**
		Malformed packets, then an ordinary message.

		Every round is entitled to any answer at all, silence included. What is
		not allowed is for the association to be unable to carry a message
		afterwards.
	**/
	public function testTheAssociationStillCarriesAMessageAfterMalformedPackets():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var valid:ByteArray = pair.capture();
		Require.notNull(valid, "the client sent nothing, so there is no real packet to deform");

		for (round in 0...ROUNDS) {
			try {
				pair.server.receive(__malformed(round, valid), pair.now);
			} catch (_:Dynamic) {
				// Refusing is one of the answers a bad packet is entitled to.
			}

			pair.now += 0.01;
		}

		Assert.equals(SctpAssociationState.ESTABLISHED, pair.server.state, "malformed packets took the association down");

		var got:String = null;
		pair.serverData.onMessage = function(_, payload:ByteArray, _):Void {
			payload.position = 0;
			got = payload.readUTFBytes(payload.length);
		};

		pair.clientData.send(0, Pair.text("still here"), SctpDataChunk.PPID_STRING, true, pair.now);
		pair.run(() -> got != null);

		Assert.equals("still here", got, "the association stopped carrying messages after malformed packets");
	}

	/**
		What the receiver is still holding once the traffic stops.

		The three shapes below are each perfectly legal on their own, which is
		why no validity check refuses them and why a bound is the only defence:
		a fragment flagged B that is never finished, an ordered message whose
		predecessor never arrives, and an ordinary message that is delivered
		and should then be forgotten.
	**/
	public function testAdversarialChunksDoNotAccumulate():Void {
		if (unsupported()) return;

		var pair = Pair.open();
		var delivered:Int = 0;
		pair.serverData.onMessage = function(_, _, _):Void {
			delivered++;
		};

		var captured:ByteArray = pair.capture();
		Require.notNull(captured, "the client sent nothing, so there is no header to build on");

		var template:SctpPacket = SctpPacket.decode(captured, false);
		Require.notNull(template, "the captured packet did not decode, so there is no header to reuse");

		var tsn:Int = (@:privateAccess pair.serverData.__cumulativeTsn) + 1;

		for (round in 0...RETENTION_ROUNDS) {
			var chunk:SctpDataChunk = switch (round % 3) {
				// Begun and never ended. The reassembly buffer keeps this for
				// the life of the association unless something bounds it.
				case 0:
					new SctpDataChunk(tsn, 1, 0, SctpDataChunk.PPID_BINARY, __payload(), SctpDataChunk.FLAG_BEGINNING);

				// Ordered, on a stream whose sequence 0 never arrives, so each
				// of these waits its turn behind a message that is not coming.
				case 1:
					new SctpDataChunk(tsn, 2, round + 1, SctpDataChunk.PPID_BINARY, __payload(),
						SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING);

				// A whole message on an unordered stream: delivered, and then
				// owed nothing.
				case _:
					new SctpDataChunk(tsn, 3, 0, SctpDataChunk.PPID_BINARY, __payload(),
						SctpDataChunk.FLAG_BEGINNING | SctpDataChunk.FLAG_ENDING | SctpDataChunk.FLAG_UNORDERED);
			}

			tsn = (tsn + 1) | 0;

			var packet = new SctpPacket(template.sourcePort, template.destinationPort, template.verificationTag, [chunk.toChunk()]);
			pair.server.receive(packet.encode(), pair.now);
			pair.now += 0.01;
		}

		// Without this the counts below mean nothing: a receiver that dropped
		// everything on the floor would also be holding nothing.
		Assert.isTrue(delivered > 0, "not one message was delivered, so the traffic never reached the receiver");

		var reassembling:Int = 0;
		var partial = @:privateAccess pair.serverData.__partial;
		for (key in partial.keys()) {
			for (fragment in partial.get(key)) {
				reassembling += fragment.payload.length;
			}
		}

		var waiting:Int = 0;
		var held = @:privateAccess pair.serverData.__held;
		for (key in held.keys()) {
			waiting += held.get(key).length;
		}

		var remembered:Int = 0;
		for (_ in (@:privateAccess pair.serverData.__received).keys()) {
			remembered++;
		}

		Assert.isTrue(reassembling <= SctpDataTransfer.MAX_REASSEMBLY,
			"a message that was never finished left " + reassembling + " bytes reassembling, against a bound of "
			+ SctpDataTransfer.MAX_REASSEMBLY);

		Assert.isTrue(waiting * FRAGMENT <= SctpDataTransfer.MAX_HELD,
			"a stream waiting on a sequence that never came held " + waiting + " messages, which is "
			+ (waiting * FRAGMENT) + " bytes against a bound of " + SctpDataTransfer.MAX_HELD);

		Assert.isTrue(remembered < RETENTION_ROUNDS / 2,
			"the receiver still remembers " + remembered + " of " + RETENTION_ROUNDS + " chunks it has finished with");
	}

	// --- the traffic ------------------------------------------------------

	private function __malformed(round:Int, valid:ByteArray):ByteArray {
		var source:Bytes = (valid : Bytes);

		return switch (round % 3) {
			// Not a packet at all.
			case 0: ByteArray.fromBytes(__randomBytes(__nextInt(1, 256)));

			// A real packet cut somewhere, which walks the decoder to the end
			// of every field it reads and one byte short of it.
			case 1: ByteArray.fromBytes(source.sub(0, __nextInt(1, source.length)));

			// A real packet with one byte changed, which keeps the shape and
			// moves a number: a length, a chunk type, a verification tag.
			case _:
				var mutant:Bytes = source.sub(0, source.length);
				mutant.set(__nextInt(0, mutant.length), __nextInt(0, 256));
				ByteArray.fromBytes(mutant);
		}
	}

	private function __payload():ByteArray {
		var out:ByteArray = new ByteArray();
		out.length = FRAGMENT;
		return out;
	}

	// --- deterministic input ---------------------------------------------

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

		var value:Int = __next();
		if (value < 0) {
			value = -(value + 1);
		}

		return low + (value % (high - low));
	}

	private function __randomBytes(length:Int):Bytes {
		var out:Bytes = Bytes.alloc(length);
		for (i in 0...length) {
			out.set(i, __nextInt(0, 256));
		}

		return out;
	}
}

/** Two associations wired to one another, established and carrying data. **/
private class Pair {
	public var client:SctpAssociation;
	public var server:SctpAssociation;
	public var clientData:SctpDataTransfer;
	public var serverData:SctpDataTransfer;
	public var now:Float = 0;

	private var toServer:Array<ByteArray> = [];
	private var toClient:Array<ByteArray> = [];

	public static function open():Pair {
		var pair = new Pair();
		pair.client = new SctpAssociation();
		pair.server = new SctpAssociation();

		pair.client.onSend = payload -> pair.toServer.push(payload);
		pair.server.onSend = payload -> pair.toClient.push(payload);

		pair.server.listen();
		pair.client.associate(0);

		for (_ in 0...50) {
			pair.deliver();

			if (pair.client.state == SctpAssociationState.ESTABLISHED && pair.server.state == SctpAssociationState.ESTABLISHED) {
				break;
			}
		}

		pair.clientData = new SctpDataTransfer(pair.client);
		pair.serverData = new SctpDataTransfer(pair.server);
		return pair;
	}

	private function new() {}

	public static function text(value:String):ByteArray {
		var out = new ByteArray();
		out.writeUTFBytes(value);
		out.position = 0;
		return out;
	}

	/**
		One packet the client really sent, taken off the wire before delivery.

		Malformed packets are built on this header. Reading the ports and the
		verification tag off a real packet, rather than reaching into the
		association for them, keeps this correct if either moves.
	**/
	public function capture():ByteArray {
		clientData.send(0, text("template"), SctpDataChunk.PPID_STRING, true, now);

		if (toServer.length == 0) {
			clientData.poll(now);
		}

		var captured:ByteArray = toServer.length > 0 ? toServer[0] : null;

		// Delivered as normal afterwards, so the association is not left
		// holding a fragment nobody acknowledged.
		for (_ in 0...10) {
			clientData.poll(now);
			serverData.poll(now);
			deliver();
		}

		return captured;
	}

	public function deliver():Void {
		var outbound = toServer;
		var inbound = toClient;
		toServer = [];
		toClient = [];

		for (payload in outbound) {
			server.receive(payload, now);
		}

		for (payload in inbound) {
			client.receive(payload, now);
		}

		now += 0.25;
	}

	public function run(done:Void->Bool):Bool {
		for (_ in 0...200) {
			if (clientData != null) {
				clientData.poll(now);
			}

			if (serverData != null) {
				serverData.poll(now);
			}

			deliver();

			if (done()) {
				return true;
			}
		}

		return done();
	}
}
