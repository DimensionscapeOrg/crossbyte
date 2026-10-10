package crossbyte.rpc._internal;

import crossbyte.core.CrossByte;
import crossbyte.core._internal.PassFlush;
import crossbyte.events.TickEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArray.ByteArrayData;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.NetConnectionBase;
import crossbyte.rpc.RPCSession;
import haxe.io.Bytes;

/**
	A session's answers too long to send at once, sent in pieces
	(`RPCWire.FLAG_CHUNK`) between the frames it sends meanwhile, and the
	pieces of the peer's, put back together. Made with the first of either,
	so a session that never sends or receives one pays nothing for it.

	**Sending.** An answer past the session's `chunkLength` is kept, in the
	buffer it was framed in, and handed to the connection a piece at a time
	while what the connection holds unsent (`NetConnectionBase.__bytesQueued`)
	is under four pieces: a frame the session sends meanwhile waits behind at
	most those, not behind the whole answer. Up to `MAX_CHUNK_STREAMS`
	answers take turns, a piece each; the rest wait. Each piece after the
	first is sent from where it lies, its head written over the end of the
	piece before it, which has gone: the answer is copied no more than a
	whole frame is. While pieces wait, the session is flushed again at the
	end of each pass that sent some (the loop polls again before it sleeps),
	and at each tick while the connection is full.

	**Receiving.** The pieces of an answer are appended to a buffer of its
	own, which grows as they arrive, so a peer can make this side hold no
	more than four times what it has sent; each answer within
	`maxFrameLength`, and at most
	`MAX_CHUNK_STREAMS` at once. The whole is read as a frame that came
	whole.
**/
@:noCompletion
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.io.ByteArrayData)
class RPCChunks implements PassFlush {
	/**
		How many pieces' worth the connection may hold unsent before the next
		waits. Measured on loopback TCP against 16 KiB to 1 MiB pieces and
		two to sixteen of them, 64 KiB and four kept a 64 MB answer as fast
		as whole while a small call behind it waited least.
	**/
	static inline final HIGH_PIECES:Int = 4;

	final session:RPCSession<Dynamic, Dynamic>;

	// Sending: the answers taking turns, those waiting, whose turn it is,
	// and the bytes of every one not handed over yet.
	final sending:Array<OutgoingAnswer> = [];
	final waiting:Array<OutgoingAnswer> = [];
	var turn:Int = 0;
	var nextStream:Int = 0;
	var flushQueued:Bool = false;
	var ticking:Bool = false;
	var runtime:Null<CrossByte> = null;
	final onTick:TickEvent->Void;
	final onRoom:Void->Void;
	// Whether the connection will say when it has room again.
	var told:Bool = false;
	// What a first piece is written in, sent and then free again.
	var firstPiece:Null<ByteArray> = null;

	/** The bytes of answers kept here not yet handed to the connection: what `maxOutputPending` counts beside the connection's own. **/
	public var unsent(default, null):Int = 0;

	// Receiving.
	final arriving:Array<IncomingAnswer> = [];

	public function new(session:RPCSession<Dynamic, Dynamic>) {
		this.session = session;
		onTick = tick;
		onRoom = room;
	}

	/**
		Takes `frame`, a whole answer, finished, to send in pieces of
		`pieceLength`: it is this one's from now on, and is let go once its
		last piece has gone.
	**/
	public function send(frame:RPCFrame, pieceLength:Int):Void {
		final answer = new OutgoingAnswer(frame, (nextStream = (nextStream + 1) & 0x7FFFFFFF), pieceLength);
		unsent += frame.length - 4;
		if (sending.length < RPCWire.MAX_CHUNK_STREAMS) {
			sending.push(answer);
		} else {
			waiting.push(answer);
		}
		if (runtime == null) {
			runtime = CrossByte.__currentOrNull();
		}
		pump();
	}

	/**
		Hands the connection pieces, a turn each, while it holds less than
		four pieces' worth unsent; then arranges to be asked again while any
		are left.
	**/
	function pump():Void {
		final connection:NetConnectionBase = session.__connection;
		var sent:Bool = false;
		var high:Int = 0;
		while (sending.length > 0 && !session.__ended) {
			if (turn >= sending.length) {
				turn = 0;
			}
			final answer:OutgoingAnswer = sending[turn];
			// Under four pieces, and a piece under the transport's own limit,
			// past which it would end the connection; one piece whatever the
			// limit when nothing waits.
			high = answer.pieceLength * HIGH_PIECES;
			final limit:Int = connection.__queueLimit();
			if (limit > 0 && limit - answer.pieceLength < high) {
				high = limit - answer.pieceLength;
			}
			final queued:Int = connection.__bytesQueued();
			if (queued > 0 && queued >= high) {
				break;
			}
			try {
				sendPiece(connection, answer);
			} catch (error:Dynamic) {
				// The connection could not take it: it says so as it ends, and
				// the answers kept here go with it.
				drop();
				return;
			}
			sent = true;
			if (answer.done) {
				sending.splice(turn, 1);
				answer.release();
				if (waiting.length > 0) {
					sending.push(waiting.shift());
				}
			} else {
				turn++;
			}
		}
		if (session.__ended) {
			drop();
			return;
		}
		if (sending.length == 0) {
			stopTicking();
			return;
		}
		if (sent) {
			// More once this pass's sends have gone, before the loop sleeps.
			stopTicking();
			queueFlush();
		} else if (!told && !ticking && runtime != null) {
			// Full: the connection says when it has room, or it is asked
			// each tick.
			if (connection.__whenQueueUnder(high, onRoom)) {
				told = true;
			} else {
				ticking = true;
				runtime.addEventListener(TickEvent.TICK, onTick);
			}
		}
	}

	inline function queueFlush():Void {
		if (!flushQueued && runtime != null) {
			flushQueued = true;
			runtime.__queueNextPassFlush(this);
		}
	}

	/** The connection has room again: on at the end of the pass. **/
	function room():Void {
		told = false;
		queueFlush();
	}

	public function __flushPass():Void {
		flushQueued = false;
		pump();
	}

	function tick(_:TickEvent):Void {
		pump();
	}

	inline function stopTicking():Void {
		if (ticking) {
			ticking = false;
			runtime.removeEventListener(TickEvent.TICK, onTick);
		}
	}

	/** The next piece of `answer`. **/
	function sendPiece(connection:NetConnectionBase, answer:OutgoingAnswer):Void {
		final frame:RPCFrame = answer.frame;
		final end:Int = frame.length;
		if (answer.at == 0) {
			// The first: how long the answer is, then its flags and op, from a
			// frame of its own, since there is no room for a head before them.
			var first:Null<ByteArray> = firstPiece;
			if (first == null) {
				first = firstPiece = new ByteArray(RPCWire.CHUNK_HEAD + 10);
			}
			first.length = RPCWire.CHUNK_HEAD + 10;
			final bytes:ByteArrayData = first;
			bytes.set(4, RPCWire.FLAG_CHUNK);
			bytes.setInt32(5, answer.stream);
			var at:Int = RPCWire.CHUNK_HEAD;
			var total:Int = end - 4;
			while ((total & ~0x7F) != 0) {
				bytes.set(at++, (total & 0x7F) | 0x80);
				total >>>= 7;
			}
			bytes.set(at++, total);
			bytes.blit(at, frame, 4, 5);
			at += 5;
			bytes.setInt32(0, at - 4);
			first.length = at;
			first.position = 0;
			answer.at = 9;
			unsent -= 5;
			connection.send(first);
			return;
		}
		final at:Int = answer.at;
		var count:Int = end - at;
		if (count > answer.pieceLength) {
			count = answer.pieceLength;
		}
		final last:Bool = at + count == end;
		// Its head over the last bytes of the piece before, which have gone.
		final head:Int = at - RPCWire.CHUNK_HEAD;
		frame.setInt32(head, 5 + count);
		frame.set(head + 4, last ? RPCWire.FLAG_CHUNK | RPCWire.FLAG_CHUNK_END : RPCWire.FLAG_CHUNK);
		frame.setInt32(head + 5, answer.stream);
		answer.at = at + count;
		answer.done = last;
		unsent -= count;
		connection.__sendRange(frame, head, RPCWire.CHUNK_HEAD + count);
	}

	/** The connection has ended: nothing kept here goes anywhere now. **/
	public function drop():Void {
		for (answer in sending) {
			answer.release();
		}
		for (answer in waiting) {
			answer.release();
		}
		sending.resize(0);
		waiting.resize(0);
		unsent = 0;
		turn = 0;
		told = false;
		stopTicking();
		for (answer in arriving) {
			if (answer.direct == null) {
				release(answer);
			}
		}
		arriving.resize(0);
	}

	/**
		A piece of the peer's answer, `stream`, from `input` to `frameEnd`,
		`last` on its last: appended to what has arrived of it, and the whole
		read once it is in.

		@throws String When the peer has broken the rules: more answers in
		pieces at once than `MAX_CHUNK_STREAMS`, one past `maxLength`, or a
		first piece that does not begin an answer. Nothing after it can be
		trusted to line up.
	**/
	public function arrived(stream:Int, input:ByteArrayInput, frameEnd:Int, last:Bool, maxLength:Int):Void {
		var answer:Null<IncomingAnswer> = null;
		for (one in arriving) {
			if (one.stream == stream) {
				answer = one;
				break;
			}
		}
		if (answer == null) {
			if (arriving.length >= RPCWire.MAX_CHUNK_STREAMS) {
				throw "RPC peer sent more than " + RPCWire.MAX_CHUNK_STREAMS + " answers in pieces at once";
			}
			final total:Int = input.readVarUInt();
			if (total < RPCWire.MIN_PAYLOAD_LEN || (maxLength > 0 && total > maxLength)) {
				throw "RPC answer in pieces of " + total + " bytes passed the " + maxLength + "-byte frame limit";
			}
			if (frameEnd - input.position < 1) {
				throw "RPC answer in pieces began with nothing";
			}
			final flags:Int = (cast input : ByteArrayData).get(input.position);
			if ((flags & ~(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_ERROR)) != RPCWire.FLAG_RESPONSE) {
				throw "RPC frame in pieces is not an answer: flags 0x" + StringTools.hex(flags, 2);
			}
			answer = new IncomingAnswer(stream, total);
			arriving.push(answer);
		}
		final count:Int = frameEnd - input.position;
		if (count > answer.total - answer.held) {
			throw "RPC answer in pieces ran past the " + answer.total + " bytes it said it was";
		}
		if (count > 0) {
			final direct:Null<Bytes> = answer.direct;
			if (direct != null) {
				direct.blit(answer.directAt, (cast input : ByteArrayData), input.position, count);
				answer.directAt += count;
			} else {
				append(answer, input, count);
			}
			answer.held += count;
			if (direct == null && !answer.decided && (answer.held >= HEAD_MOST || answer.held == answer.total)) {
				decide(answer);
			}
		}
		input.position = frameEnd;
		if (!last) {
			return;
		}
		arriving.remove(answer);
		if (answer.held != answer.total) {
			release(answer);
			throw "RPC answer in pieces ended at " + answer.held + " of the " + answer.total + " bytes it said it was";
		}
		if (answer.total > largest) {
			largest = answer.total;
		}
		final whole:Null<Bytes> = answer.direct;
		if (whole != null) {
			// Read as its frame would be: the call it answers is answered.
			final commands = session.__commands;
			answer.direct = null;
			if (commands != null) {
				commands.__answerValue(answer.op, answer.requestId, whole);
			}
			return;
		}
		final buffer:ByteArray = answer.buffer;
		(buffer : ByteArrayData).setInt32(0, buffer.length - 4);
		buffer.position = 0;
		try {
			session.__readAssembled(buffer);
		} catch (error:Dynamic) {
			release(answer);
			throw error;
		}
		release(answer);
	}

	// The most of an answer's head (flags, op, request id, a Bytes' count)
	// read to tell whether it is one Bytes: 1 + 4 + 5 + 5.
	static inline final HEAD_MOST:Int = 15;

	// The largest answer of the peer's put together on this session: one up
	// to as large is given its whole room as it begins, as a socket's input
	// takes at once what it held in its last burst.
	var largest:Int = 0;

	/**
		Whether `answer`'s whole room may be taken once `arrived` bytes of it
		are in: at once up to the largest answer of the peer's put together
		before, and past it once a quarter of the answer is in, so a peer
		makes this side hold no more than four times what it has sent of an
		answer larger than any before.
	**/
	inline function mayHold(answer:IncomingAnswer, arrived:Int):Bool {
		return answer.total <= largest || arrived * 4 >= answer.total;
	}

	/** Appends what has arrived of `answer`'s frame to its buffer, grown as `mayHold` lets it. **/
	function append(answer:IncomingAnswer, input:ByteArrayInput, count:Int):Void {
		final buffer:ByteArray = answer.buffer;
		final needed:Int = 4 + answer.held + count;
		final data:ByteArrayData = buffer;
		if (needed > data.__length) {
			var capacity:Int = data.__length * 2;
			if (capacity < needed) {
				capacity = needed;
			}
			if (capacity > 4 + answer.total || mayHold(answer, answer.held + count)) {
				capacity = 4 + answer.total;
			}
			reserve(buffer, capacity);
		}
		buffer.position = buffer.length;
		buffer.writeBytes((cast input : ByteArrayData), input.position, count);
	}

	/** Room for `capacity` bytes in `buffer`: the runtime's kept storage where it has some, as a socket's large buffers take. **/
	function reserve(buffer:ByteArray, capacity:Int):Void {
		final data:ByteArrayData = buffer;
		#if ((cpp || jvm) && !macro)
		final runtime:Null<CrossByte> = CrossByte.__currentOrNull();
		if (runtime != null) {
			final pool = runtime.__storagePool();
			final storage:Null<haxe.io.BytesData> = pool.take(capacity);
			if (storage != null) {
				final old:haxe.io.BytesData = data.__adoptStorage(storage, 0);
				pool.giveGrown(old);
				return;
			}
		}
		#end
		data.__reserve(capacity);
	}

	/**
		`answer`'s buffer's storage back where it came from, once it is read
		or will not be, and the buffer left holding none, so it cannot be
		given back twice.
	**/
	function release(answer:IncomingAnswer):Void {
		#if ((cpp || jvm) && !macro)
		final data:ByteArrayData = answer.buffer;
		if (data.__length == 0) {
			return;
		}
		var none:Null<haxe.io.BytesData> = __none;
		if (none == null) {
			none = __none = Bytes.alloc(0).getData();
		}
		data.length = 0;
		data.position = 0;
		final storage:haxe.io.BytesData = data.__adoptStorage(none, 0);
		final runtime:Null<CrossByte> = CrossByte.__currentOrNull();
		if (runtime != null) {
			runtime.__storagePool().give(storage);
		}
		#end
	}

	#if ((cpp || jvm) && !macro)
	static var __none:Null<haxe.io.BytesData> = null;
	#end

	/**
		Once its head is in, whether `answer` is one `Bytes` and nothing else
		(its commands say so of its op): then the rest of it is put together
		in the `Bytes` itself, which its call is answered with, rather than
		in a frame read once whole, which copied every byte of it once more.
		Only once its whole room may be taken (see `mayHold`); until then it
		is put together as a frame, and asked again with each piece.
	**/
	function decide(answer:IncomingAnswer):Void {
		final data:ByteArrayData = answer.buffer;
		final end:Int = 4 + answer.held;
		if (data.get(4) != RPCWire.FLAG_RESPONSE) {
			answer.decided = true;
			return;
		}
		final commands = session.__commands;
		final op:Int = data.getInt32(5);
		if (commands == null || !commands.__rpc_answersBytes(op)) {
			answer.decided = true;
			return;
		}
		var at:Int = 9;
		var requestId:Int = 0;
		var shift:Int = 0;
		var b:Int = 0;
		do {
			if (at >= end || shift > 28) {
				answer.decided = true;
				return;
			}
			b = data.get(at++);
			requestId |= (b & 0x7F) << shift;
			shift += 7;
		} while ((b & 0x80) != 0);
		var count:Int = 0;
		shift = 0;
		do {
			if (at >= end || shift > 28) {
				answer.decided = true;
				return;
			}
			b = data.get(at++);
			count |= (b & 0x7F) << shift;
			shift += 7;
		} while ((b & 0x80) != 0);
		final head:Int = at - 4;
		if (count < 0 || head + count != answer.total) {
			answer.decided = true;
			return;
		}
		if (!mayHold(answer, answer.held)) {
			// Asked again with the next piece.
			return;
		}
		answer.decided = true;
		final direct = Bytes.alloc(count);
		final already:Int = end - at;
		if (already > 0) {
			direct.blit(0, data, at, already);
		}
		answer.direct = direct;
		answer.directAt = already;
		answer.op = op;
		answer.requestId = requestId;
		release(answer);
	}
}

/** An answer being sent in pieces: its frame, which it is, and how far it has gone. **/
@:noCompletion
private class OutgoingAnswer {
	public final frame:RPCFrame;
	public final stream:Int;
	public final pieceLength:Int;
	public var at:Int = 0;
	public var done:Bool = false;

	public function new(frame:RPCFrame, stream:Int, pieceLength:Int) {
		this.frame = frame;
		this.stream = stream;
		this.pieceLength = pieceLength;
	}

	/** Its frame let go, poisoned first under `-D crossbyte_check_events`. **/
	public function release():Void {
		#if crossbyte_check_events
		frame.poison();
		#end
		frame.busy = false;
		frame.letGo();
	}
}

/**
	An answer of the peer's arriving in pieces: its frame so far, after four
	bytes kept for its length; or, once it is known to be one `Bytes`, that
	`Bytes`, filled as the pieces come.
**/
@:noCompletion
private class IncomingAnswer {
	public final stream:Int;
	public final total:Int;
	public final buffer:ByteArray = new ByteArray();
	public var held:Int = 0;
	public var decided:Bool = false;
	public var direct:Null<Bytes> = null;
	public var directAt:Int = 0;
	public var op:Int = 0;
	public var requestId:Int = 0;

	public function new(stream:Int, total:Int) {
		this.stream = stream;
		this.total = total;
		buffer.length = 4;
	}
}
