package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import crossbyte.net.Reason;
import crossbyte.rpc.RPCFailure;
import crossbyte.rpc._internal.RPCWire;
import haxe.io.Bytes;
import utest.Assert;

/**
	An answer longer than its session's `chunkLength` goes in pieces
	(`RPCWire.FLAG_CHUNK`) between the frames sent while it goes, to a peer
	that reads them, so a small answer behind it is not held up for the
	whole of it; and it arrives whole. The limits hold with pieces: a piece
	counts toward the reader's `maxFrameLength` and the sender's
	`maxOutputPending`, at most four answers go at once, and a peer that
	breaks the rules ends the connection.

	Over `PacedConnection`, which holds what is sent until the test moves it
	and says how much it holds, as a socket does.
**/
@:access(crossbyte.rpc.RPCSession)
class RPCChunkTest extends utest.Test {
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testALargeAnswerGoesInPiecesWithASmallOneBetween():Void {
		final pair = new ChunkPair();
		final done:Array<String> = [];
		final big = pair.commands.big(300000);
		big.then(_ -> done.push("big"));
		pair.commands.small(7).then(_ -> done.push("small"));
		pair.settle();
		Assert.same(["small", "big"], done, "the small answer waited for the large one");
		Assert.isTrue(ChunkHandler.holds(big.result, 300000), "the large answer did not arrive whole");
		final kinds = pair.framesTo(pair.link.client);
		final pieces = kinds.filter(kind -> kind == "piece" || kind == "last");
		// 300,000 bytes and a few, in 64 KiB pieces after the first.
		Assert.equals(1 + 5, pieces.length, "pieces: " + kinds.join(" "));
		final first = kinds.indexOf("piece");
		final last = kinds.indexOf("last");
		final small = kinds.lastIndexOf("answer");
		Assert.isTrue(first >= 0 && small > first && small < last, "the small answer did not go between the pieces: " + kinds.join(" "));
		pair.stillAnswers();
	}

	public function testAnAnswerUnderTheLengthGoesWhole():Void {
		final pair = new ChunkPair();
		final answer = pair.commands.big(RPCSession.DEFAULT_CHUNK_LENGTH - 64);
		pair.settle();
		Assert.isTrue(ChunkHandler.holds(answer.result, RPCSession.DEFAULT_CHUNK_LENGTH - 64));
		Assert.equals(-1, pair.framesTo(pair.link.client).indexOf("piece"), "an answer under chunkLength went in pieces");
	}

	public function testAPeerThatDoesNotReadPiecesGetsAnswersWhole():Void {
		final pair = new ChunkPair();
		// As a peer whose hello declared deadlines and cancels and no more.
		pair.server.peerCapabilities = RPCWire.CAPABILITY_CALL_CONTROL;
		final answer = pair.commands.big(300000);
		pair.settle();
		Assert.isTrue(ChunkHandler.holds(answer.result, 300000));
		Assert.equals(-1, pair.framesTo(pair.link.client).indexOf("piece"), "pieces went to a peer that did not say it reads them");
	}

	public function testAChunkLengthOfZeroSendsAnswersWhole():Void {
		final pair = new ChunkPair();
		pair.server.chunkLength = 0;
		final answer = pair.commands.big(300000);
		pair.settle();
		Assert.isTrue(ChunkHandler.holds(answer.result, 300000));
		Assert.equals(-1, pair.framesTo(pair.link.client).indexOf("piece"));
	}

	public function testUpToFourAnswersGoAtOnceAndTheRestWait():Void {
		final pair = new ChunkPair();
		final answers = [for (i in 0...6) pair.commands.big(200000 + i)];
		pair.settle();
		for (i in 0...6) {
			Assert.isTrue(ChunkHandler.holds(answers[i].result, 200000 + i), 'answer $i did not arrive whole');
		}
		// The streams under way at once, as the frames went.
		var most:Int = 0;
		final going = new Map<Int, Bool>();
		for (frame in pair.link.server.moved) {
			final flags:Int = (cast frame : Bytes).get(4);
			if ((flags & ~RPCWire.FLAG_CHUNK_END) != RPCWire.FLAG_CHUNK) {
				continue;
			}
			final stream:Int = (cast frame : Bytes).getInt32(5);
			going.set(stream, true);
			var count:Int = 0;
			for (_ in going) {
				count++;
			}
			if (count > most) {
				most = count;
			}
			if (flags != RPCWire.FLAG_CHUNK) {
				going.remove(stream);
			}
		}
		Assert.equals(RPCWire.MAX_CHUNK_STREAMS, most, "answers under way at once");
	}

	public function testARuntimeAnswerGoesInPiecesToo():Void {
		final pair = new ChunkPair();
		final bytes = ChunkHandler.made(250000);
		pair.server.register(40, args -> bytes);
		final answer:RPCResponse<Bytes> = pair.client.request(40, []);
		pair.settle();
		Assert.isTrue(ChunkHandler.holds(answer.result, 250000), "the runtime answer did not arrive whole");
		Assert.isTrue(pair.framesTo(pair.link.client).indexOf("piece") >= 0, "the runtime answer did not go in pieces");
	}

	public function testAnAnswerInPiecesToAReceiverArrivesWhole():Void {
		final pair = new ChunkPair();
		final told = new ChunkReceiver();
		pair.commands.bigThen(150000, told);
		pair.settle();
		Assert.equals(1, told.values.length);
		Assert.isTrue(told.values.length == 1 && ChunkHandler.holds(told.values[0], 150000));
	}

	public function testAnAnswerInPiecesCountsTowardTheReadersFrameLimit():Void {
		final pair = new ChunkPair();
		pair.client.maxFrameLength = 200000;
		final answer = pair.commands.big(300000);
		pair.settle();
		switch (answer.failure) {
			case Disconnected(Error(why)):
				Assert.stringContains("frame limit", why);
			case other:
				Assert.fail("an answer past the reader's frame limit failed as " + other);
		}
		Assert.isFalse(pair.link.client.open, "the connection stayed up");
	}

	public function testOneAnswerAsLargeAsTheFrameLimitDoesNotTripMaxOutputPending():Void {
		final pair = new ChunkPair();
		pair.server.maxOutputPending = 100000;
		final answer = pair.commands.big(300000);
		pair.settle();
		Assert.isTrue(ChunkHandler.holds(answer.result, 300000), "a lone answer in pieces tripped maxOutputPending: " + answer.error);
	}

	public function testPiecesWaitingCountTowardMaxOutputPending():Void {
		final pair = new ChunkPair();
		pair.server.maxOutputPending = 100000;
		final big = pair.commands.big(300000);
		final small = pair.commands.small(1);
		// The calls reach the server; nothing comes back: the client is not
		// reading. The small answer finds the large one's pieces waiting.
		pair.link.client.deliver();
		Assert.isFalse(pair.link.server.open, "a peer not reading was not closed with pieces waiting for it");
		Assert.isTrue(pair.server.__chunks == null || pair.server.__chunks.unsent == 0, "pieces were kept for a connection that has ended");
	}

	public function testPiecesWaitingCountOnAConnectionThatBoundsItsOwn():Void {
		// As over reliable UDP, whose own limit sees only what it holds: two
		// large answers, the second finding the first's pieces waiting.
		final pair = new ChunkPair();
		pair.link.server.__holdsOutput = false;
		pair.server.maxOutputPending = 100000;
		pair.commands.big(300000);
		pair.commands.big(300000);
		pair.link.client.deliver();
		Assert.isFalse(pair.link.server.open, "pieces piled up past maxOutputPending");
	}

	public function testTheConnectionEndingMidAnswerFailsItsCall():Void {
		final pair = new ChunkPair();
		final big = pair.commands.big(400000);
		pair.link.client.deliver();
		pair.link.server.deliver();
		Assert.isFalse(big.completed, "the answer arrived at once");
		pair.link.client.peerLeft();
		pair.link.server.peerLeft();
		pair.settle();
		Assert.isTrue(Type.enumEq(Disconnected(Reason.Closed), big.failure), "a call whose answer was cut off failed as " + big.failure);
		Assert.isTrue(pair.server.__chunks.unsent == 0, "the server kept pieces for a connection that has ended");
	}

	public function testMoreAnswersInPiecesAtOnceThanFourEndTheConnection():Void {
		final pair = new ChunkPair();
		final waiting = pair.commands.small(1);
		for (stream in 1...6) {
			pair.link.server.send(ChunkPair.piece(stream, false, [RPCWire.FLAG_RESPONSE, 1, 2, 3, 4], 100));
		}
		pair.link.server.deliver();
		Assert.isFalse(pair.link.client.open, "a fifth answer in pieces at once was taken");
		switch (waiting.failure) {
			case Disconnected(Error(why)):
				Assert.stringContains("pieces at once", why);
			case other:
				Assert.fail("the call waiting failed as " + other);
		}
	}

	public function testAFirstPieceThatIsNotAnAnswerEndsTheConnection():Void {
		final pair = new ChunkPair();
		pair.link.server.send(ChunkPair.piece(1, false, [RPCWire.FLAG_REQUEST, 1, 2, 3, 4], 100));
		pair.link.server.deliver();
		Assert.isFalse(pair.link.client.open, "a request in pieces was taken");
	}

	public function testPiecesPastTheLengthTheirAnswerGaveEndTheConnection():Void {
		final pair = new ChunkPair();
		pair.link.server.send(ChunkPair.piece(1, false, [RPCWire.FLAG_RESPONSE, 1, 2, 3, 4], 8));
		pair.link.server.send(ChunkPair.piece(1, false, [9, 9, 9, 9]));
		pair.link.server.deliver();
		Assert.isFalse(pair.link.client.open, "an answer longer than it said was taken");
	}

	public function testAnAnswerEndingShortOfItsLengthEndsTheConnection():Void {
		final pair = new ChunkPair();
		pair.link.server.send(ChunkPair.piece(1, false, [RPCWire.FLAG_RESPONSE, 1, 2, 3, 4], 20));
		pair.link.server.send(ChunkPair.piece(1, true, [9, 9]));
		pair.link.server.deliver();
		Assert.isFalse(pair.link.client.open, "an answer shorter than it said was read");
	}

	public function testAnAnswerSayingItIsPastTheFrameLimitEndsTheConnectionAtOnce():Void {
		final pair = new ChunkPair();
		pair.link.server.send(ChunkPair.piece(1, false, [RPCWire.FLAG_RESPONSE, 1, 2, 3, 4], 0x7FFFFFF0));
		pair.link.server.deliver();
		Assert.isFalse(pair.link.client.open, "an answer of two gigabytes was begun");
	}
}

/** A client and a server over a `PacedConnection` pair, their hellos exchanged. **/
@:access(crossbyte.rpc.RPCSession)
private class ChunkPair {
	public final link = PacedConnection.pair();
	public final commands = new ChunkCommands();
	public final client:RPCSession<ChunkCommands>;
	public final server:RPCSession<Dynamic>;

	public function new() {
		client = new RPCSession<ChunkCommands>(link.client, commands);
		server = new RPCSession(link.server, null, new ChunkHandler());
		settle();
		// Only what is sent from here on is read by the tests.
		link.client.moved.resize(0);
		link.server.moved.resize(0);
	}

	/** Moves everything both ways, and lets the runtime run, until nothing more is sent. **/
	public function settle():Void {
		final runtime = CrossByte.current();
		var quiet:Int = 0;
		var rounds:Int = 0;
		while (quiet < 3 && rounds++ < 10000) {
			final moved:Int = link.client.deliver() + link.server.deliver();
			runtime.pump(0, 0);
			quiet = moved == 0 ? quiet + 1 : 0;
		}
	}

	/** What each frame that reached `to` was: "piece", "last", "answer", "call" or "other". **/
	public function framesTo(to:PacedConnection):Array<String> {
		final from:PacedConnection = to.peer;
		return [
			for (frame in from.moved) {
				final flags:Int = (cast frame : Bytes).get(4);
				if (flags == RPCWire.FLAG_CHUNK) "piece" else if (flags == RPCWire.FLAG_CHUNK | RPCWire.FLAG_CHUNK_END) "last" else
					if ((flags & RPCWire.FLAG_RESPONSE) != 0) "answer" else if ((flags & RPCWire.FLAG_REQUEST) != 0) "call" else "other";
			}
		];
	}

	public function stillAnswers(?pos:haxe.PosInfos):Void {
		final answer = commands.small(5);
		settle();
		Assert.equals(5, answer.result, "the session did not answer after it", pos);
	}

	/**
		A piece of `stream` carrying `bytes`, as a peer frames one: a first
		piece when `total` is given, saying the answer is that long.
	**/
	public static function piece(stream:Int, last:Bool, bytes:Array<Int>, total:Int = -1):ByteArray {
		final head:Array<Int> = [];
		var v:Int = total;
		if (total >= 0) {
			while ((v & ~0x7F) != 0) {
				head.push((v & 0x7F) | 0x80);
				v >>>= 7;
			}
			head.push(v);
		}
		final body = head.concat(bytes);
		final frame = new ByteArray();
		frame.length = RPCWire.CHUNK_HEAD + body.length;
		final raw:Bytes = cast frame;
		raw.setInt32(0, 5 + body.length);
		raw.set(4, last ? RPCWire.FLAG_CHUNK | RPCWire.FLAG_CHUNK_END : RPCWire.FLAG_CHUNK);
		raw.setInt32(5, stream);
		for (i in 0...body.length) {
			raw.set(RPCWire.CHUNK_HEAD + i, body[i]);
		}
		frame.position = 0;
		return frame;
	}
}

private class ChunkCommands extends RPCCommands {
	public function new() {}

	@:rpc public function big(size:Int):RPCResponse<Bytes> {}

	@:rpc public function small(value:Int):RPCResponse<Int> {}
}

private class ChunkHandler extends RPCHandler {
	public function new() {}

	@:rpc public function big(size:Int):Bytes {
		return made(size);
	}

	@:rpc public function small(value:Int):Int {
		return value;
	}

	/** `size` bytes, each from where it lies, so a piece out of place shows. **/
	public static function made(size:Int):Bytes {
		final bytes = Bytes.alloc(size);
		for (i in 0...size) {
			bytes.set(i, (i * 7 + (i >> 8)) & 0xFF);
		}
		return bytes;
	}

	public static function holds(bytes:Null<Bytes>, size:Int):Bool {
		if (bytes == null || bytes.length != size) {
			return false;
		}
		for (i in 0...size) {
			if (bytes.get(i) != (i * 7 + (i >> 8)) & 0xFF) {
				return false;
			}
		}
		return true;
	}
}

private class ChunkReceiver implements RPCValueReceiver<Bytes> {
	public final values:Array<Bytes> = [];

	public function new() {}

	public function onValue(call:Int, value:Bytes):Void {
		values.push(value);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {}
}
