package crossbyte.net;

import utest.Assert;
#if (target.threaded && !js)
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
#end

/**
	What is written and the system will not take yet goes as soon as the
	system has room, rather than when the runtime next wakes for something
	else.

	These run on a `POLL` runtime at a tick a second, with nothing to read: all
	a socket waiting for room has to wake it is the poll, so a retry left for
	the next pass shows as a stall of up to a second. The suites that pump a
	runtime never sleep in its poll, and cannot show this.

	And they write as a proxy writes, a slice at a time, more when there is
	room, to a peer reading as fast as it can. One large write proves nothing:
	Windows takes all of a `send` while its buffer has any room at all. Nor
	does a peer with a small window, which on Windows loopback is a megabyte a
	second whatever the writer does. They count stalls rather than bytes a
	second, which says the same on the interpreter as natively.
**/
@:timeout(40000)
@:access(crossbyte.net.Socket)
@:access(crossbyte.core.CrossByte)
class SocketWriteRoomTest extends utest.Test {
	#if (target.threaded && !js)
	// Long enough for all of it at a stall a refusal, so a case that fails
	// says how many there were rather than timing out.
	private static inline var IN_TIME:Float = 25.0;
	// A gap between arrivals this long is the writer asleep: a quarter of a
	// frame, and hundreds of times what a slice takes.
	private static inline var STALL:Float = 0.25;
	private static inline var SLICE:Int = 64 * 1024;
	private static inline var KEPT_PENDING:Int = 256 * 1024;

	/**
		A peer reading as fast as it can is sent all of it without a stall. A
		write the system refused waited for the next frame, and a good many
		are refused on the way: 256 MiB took about 2 s at two ticks a second,
		and takes 25 ms.
	**/
	public function testWhatWaitsGoesAsTheSystemTakesIt():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));

		var got:Int = __read(pair, __size(), IN_TIME);
		__done(pair);

		Assert.equals(__size(), got, 'a reading peer was sent $got bytes');
		Assert.isTrue(pair.stalls <= 1, 'a peer reading as fast as it could waited on the writer ${pair.stalls} times');
	}

	/**
		A peer that stops reading wakes nothing: the poll does not report a
		socket with no room, so holding what it has not taken costs no passes,
		and it goes on as soon as the peer reads again. Counted as retries that
		moved nothing, and a few dozen are not the socket being asked after:
		Windows grows a socket's send buffer once a second or so, and each
		write that takes leaves a retry on the queue, all gone in one pass.
		Woken for each report of a socket with no room, this would count in
		the millions.
	**/
	public function testAPeerThatStopsReadingCostsNoPasses():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));
		var waiting:Bool = __untilWaiting(pair);
		var before:Int = pair.idleRetries;

		crossbyte.sys.System.sleep(1.5);
		var whileStopped:Int = pair.idleRetries - before;

		var got:Int = __read(pair, __size(), IN_TIME);
		__done(pair);

		Assert.isTrue(waiting, "the socket never had to wait, so this shows nothing");
		Assert.isTrue(whileStopped <= 1000, 'a socket with no room was retried for nothing $whileStopped times in 1.5 s at a tick a second');
		Assert.equals(__size(), got, 'a peer that read again was sent $got bytes');
		Assert.isTrue(pair.stalls <= 1, 'a peer that read again waited on the writer ${pair.stalls} times');
	}

	/**
		What waits can be taken by a flush that is not the poll's: the one that
		ends a read, or the application's own. Whoever waits on the drain to
		write more is told all the same. It waited on the writable queue, which
		told it whichever flush had taken the bytes, and a socket waiting in the
		poll is off that queue. The runtime is held in a callback here, with the
		client emptying the system's buffers, so that this flush is first.
	**/
	public function testAFlushFromElsewhereStillDrains():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));
		var waiting:Bool = __untilWaiting(pair);

		var held:sys.thread.Lock = new sys.thread.Lock();
		var holding:sys.thread.Lock = new sys.thread.Lock();
		pair.runtime.post(() -> {
			holding.release();
			held.wait(10.0);
			pair.accepted.flushFull = false;
			pair.accepted.flush();
		});
		holding.wait(10.0);
		var first:Int = __readWhatIsThere(pair);
		held.release();

		var got:Int = first + __read(pair, __size() - first, 8.0);
		__done(pair);

		Assert.isTrue(waiting, "the socket never had to wait, so this shows nothing");
		Assert.equals(__size(), got, 'a producer stopped at $got bytes, untold that a flush from elsewhere had emptied the socket');
	}

	/** A socket closed while it waits leaves nothing watched, so nothing of it is polled again. **/
	public function testASocketClosedWhileItWaitsLeavesNothingWatched():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));
		var waiting:Bool = __untilWaiting(pair);

		var nothingLeft:Bool = SpreadSupport.on(pair.runtime, () -> {
			pair.accepted.close();
			return __nothingWatched(pair);
		});
		crossbyte.sys.System.sleep(0.2);
		var stillNothing:Bool = SpreadSupport.on(pair.runtime, () -> __nothingWatched(pair));
		__done(pair);

		Assert.isTrue(waiting, "the socket never had to wait, so this shows nothing");
		Assert.isTrue(nothingLeft, "a closed socket was left watched for room");
		Assert.isTrue(stillNothing, "a closed socket came back to be watched for room");
	}

	/**
		A peer that leaves with bytes on their way to it ends the connection
		once. What the poll reports of a dead socket is that it can be written
		to, so a socket left watched would be reported, and fail again, on
		every pass there was: 25,566 errors in half a second is what that did on
		a TLS 1.2 connection.
	**/
	public function testAPeerThatLeavesIsHeardOnce():Void {
		var pair:Pair = __pair();
		var errors:Int = 0;
		var closes:Int = 0;
		SpreadSupport.on(pair.runtime, () -> {
			pair.accepted.addEventListener(IOErrorEvent.IO_ERROR, _ -> errors++);
			pair.accepted.addEventListener(Event.CLOSE, _ -> closes++);
			__feed(pair);
		});
		var waiting:Bool = __untilWaiting(pair);

		pair.client.close();
		var heard:Bool = SpreadSupport.waitFor(() -> closes > 0 || errors > 0, 5.0);
		crossbyte.sys.System.sleep(0.5);
		var nothingLeft:Bool = SpreadSupport.on(pair.runtime, () -> __nothingWatched(pair));
		__done(pair, true);

		Assert.isTrue(waiting, "the socket never had to wait, so this shows nothing");
		Assert.isTrue(heard, "a peer leaving was not heard");
		Assert.isTrue(errors <= 2, 'a peer leaving was reported $errors times');
		Assert.isTrue(closes <= 1, 'a peer leaving closed the connection $closes times');
		Assert.isTrue(nothingLeft, "a connection that ended was left watched for room");
	}

	/**
		Stopped reading is not stopped writing. A socket leaves the poll's reads
		while its reading is stopped, at its input limit or held by a request
		body's reader, and what it has written still goes as there is room.
	**/
	public function testReadsHeldLeaveWritesGoing():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> {
			pair.accepted.__holdInput(true);
			__feed(pair);
		});

		var got:Int = __read(pair, __size(), IN_TIME);
		__done(pair);

		Assert.equals(__size(), got, 'a socket with its reading held sent $got bytes');
		Assert.isTrue(pair.stalls <= 1, 'a socket with its reading held stalled ${pair.stalls} times');
	}

	/** Held once the wait has begun, which takes the socket out of the poll under it. **/
	public function testReadsHeldDuringTheWaitLeaveItWaiting():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));
		var waiting:Bool = __untilWaiting(pair);
		SpreadSupport.on(pair.runtime, () -> pair.accepted.__holdInput(true));

		var got:Int = __read(pair, __size(), IN_TIME);
		__done(pair);

		Assert.isTrue(waiting, "the socket never had to wait, so this shows nothing");
		Assert.equals(__size(), got, 'a socket whose reading was held as it waited sent $got bytes');
		Assert.isTrue(pair.stalls <= 1, 'a socket whose reading was held as it waited stalled ${pair.stalls} times');
	}

	/** A peer that has finished sending and is still reading is what a half-open socket is kept for. **/
	public function testAPeerThatHalfClosedIsStillSentWhatWaits():Void {
		var pair:Pair = __pair(socket -> socket.peerShutdownPolicy = HALF_OPEN);
		pair.client.shutdown(false, true);
		Assert.isTrue(SpreadSupport.waitFor(() -> SpreadSupport.on(pair.runtime, () -> pair.accepted.peerShutdown), 5.0), "the peer's FIN never arrived");
		SpreadSupport.on(pair.runtime, () -> __feed(pair));

		var got:Int = __read(pair, __size(), IN_TIME);
		__done(pair);

		Assert.equals(__size(), got, 'a half-closed peer was sent $got bytes');
		Assert.isTrue(pair.stalls <= 1, 'a half-closed peer waited on the writer ${pair.stalls} times');
	}

	/**
		A report of room that takes nothing is not believed twice: reported
		again at once, it would keep the runtime from ever sleeping, on a
		socket that cannot write until something else has happened, as a TLS
		session waiting to read cannot. What waits is asked after once a pass
		instead, and it goes back to waiting in the poll once something moves.
	**/
	public function testAReportThatMovesNothingCannotSpin():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));
		var waiting:Bool = __untilWaiting(pair);

		var wasWatched:Bool = SpreadSupport.on(pair.runtime, () -> pair.accepted.__waitingForRoom);
		var nothingWatched:Bool = SpreadSupport.on(pair.runtime, () -> {
			var registry = @:privateAccess pair.runtime.__socketRegistry;
			@:privateAccess registry.__reportingWritable = true;
			pair.accepted.registryOnWritable();
			@:privateAccess registry.__reportingWritable = false;
			return __nothingWatched(pair);
		});
		var notBelieved:Bool = SpreadSupport.on(pair.runtime, () -> pair.accepted.__roomNotReported);

		var got:Int = __read(pair, __size(), IN_TIME);
		var believedAgain:Bool = SpreadSupport.on(pair.runtime, () -> !pair.accepted.__roomNotReported);
		__done(pair);

		Assert.isTrue(waiting && wasWatched, "the socket never had to wait, so this shows nothing");
		Assert.isTrue(nothingWatched, "a report that moved nothing left the socket watched");
		Assert.isTrue(notBelieved, "a report that moved nothing was believed");
		Assert.equals(__size(), got, 'what waited stopped at $got bytes once a report had moved nothing');
		Assert.isTrue(believedAgain, "the socket never went back to waiting in the poll");
	}

	/** How much to send: refused a good many times, in what a slow target gets through in a few seconds. **/
	private static function __size():Int {
		return #if (cpp || java || jvm) 128 * 1024 * 1024 #else 32 * 1024 * 1024 #end;
	}

	private function __pair(?configure:Socket->Void):Pair {
		var runtime:CrossByte = SpreadSupport.runtime(1);
		var accepted:Null<Socket> = null;
		var server:ServerSocket = SpreadSupport.on(runtime, () -> {
			var listener:ServerSocket = new ServerSocket();
			listener.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
				if (configure != null) {
					configure(e.socket);
				}
				accepted = e.socket;
			});
			listener.bind(0, "127.0.0.1");
			listener.listen();
			return listener;
		});

		var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
		Assert.isTrue(SpreadSupport.waitFor(() -> accepted != null, 10.0), "the connection was never accepted");
		return new Pair(runtime, server, accepted, client);
	}

	/**
		Writes a slice at a time, for as long as little is waiting, and again
		as the socket drains, until all of it has gone: what a proxy does.
	**/
	private static function __feed(pair:Pair):Void {
		var piece:ByteArray = new ByteArray();
		for (i in 0...SLICE) {
			piece.writeByte(i & 0xFF);
		}
		var left:Int = __size();
		// A write leaves a retry on the queue, which finds no room: that one
		// follows from the write, and is not the socket being asked after.
		var wroteLast:Bool = false;
		function more():Void {
			var wrote:Bool = false;
			while (left > 0 && pair.accepted.connected && pair.accepted.bytesPending < KEPT_PENDING) {
				pair.accepted.writeBytes(piece, 0, SLICE);
				pair.accepted.flush();
				left -= SLICE;
				wrote = true;
			}
			if (!wrote && !wroteLast) {
				pair.idleRetries++;
			}
			wroteLast = wrote;
		}
		pair.accepted.__onWritableDrain = more;
		more();
	}

	/**
		Reads up to `total` bytes as fast as they come, for at most `seconds`,
		and says how many came; `stalls` counts the gaps of `STALL` or more
		between one arrival and the next.
	**/
	private static function __read(pair:Pair, total:Int, seconds:Float):Int {
		var buffer:Bytes = Bytes.alloc(256 * 1024);
		var got:Int = 0;
		var last:Float = 0;
		var deadline:Float = haxe.Timer.stamp() + seconds;
		while (got < total && haxe.Timer.stamp() < deadline) {
			if (sys.net.Socket.select([pair.client], null, null, 0.05).read.length == 0) {
				continue;
			}
			var n:Int = 0;
			try {
				n = pair.client.input.readBytes(buffer, 0, buffer.length);
			} catch (_:Dynamic) {
				break;
			}
			if (n <= 0) {
				break;
			}
			var now:Float = haxe.Timer.stamp();
			if (last > 0 && now - last >= STALL) {
				pair.stalls++;
			}
			last = now;
			got += n;
		}
		return got;
	}

	/** Reads what the system holds, until a moment passes with nothing more, and says how much that was. **/
	private static function __readWhatIsThere(pair:Pair):Int {
		var buffer:Bytes = Bytes.alloc(256 * 1024);
		var got:Int = 0;
		while (sys.net.Socket.select([pair.client], null, null, 0.2).read.length > 0) {
			var n:Int = 0;
			try {
				n = pair.client.input.readBytes(buffer, 0, buffer.length);
			} catch (_:Dynamic) {
				break;
			}
			if (n <= 0) {
				break;
			}
			got += n;
		}
		return got;
	}

	/** Until the system has stopped taking what is written, and says whether it has. **/
	private static function __untilWaiting(pair:Pair):Bool {
		var last:Int = -1;
		return SpreadSupport.waitFor(() -> {
			var pending:Int = SpreadSupport.on(pair.runtime, () -> pair.accepted.bytesPending);
			var settled:Bool = pending > 0 && pending == last;
			last = pending;
			return settled;
		}, 5.0);
	}

	private static function __nothingWatched(pair:Pair):Bool {
		return @:privateAccess pair.runtime.__socketRegistry.__writeSet.isEmpty;
	}

	private static function __done(pair:Pair, clientGone:Bool = false):Void {
		if (!clientGone) {
			try {
				pair.client.close();
			} catch (_:Dynamic) {}
		}
		SpreadSupport.on(pair.runtime, () -> {
			pair.accepted.__onWritableDrain = null;
			try {
				pair.server.close();
			} catch (_:Dynamic) {}
			if (pair.accepted.connected) {
				try {
					pair.accepted.close();
				} catch (_:Dynamic) {}
			}
			return true;
		});
		SpreadSupport.stop([pair.runtime]);
	}
	#end
}

#if (target.threaded && !js)
private class Pair {
	public final runtime:CrossByte;
	public final server:ServerSocket;
	public final accepted:Socket;
	public final client:sys.net.Socket;

	/** Calls of the socket's drain that found no room to write more: retries that moved nothing. */
	public var idleRetries:Int = 0;

	/** Gaps of `STALL` or more between arrivals at the client. */
	public var stalls:Int = 0;

	public function new(runtime:CrossByte, server:ServerSocket, accepted:Socket, client:sys.net.Socket) {
		this.runtime = runtime;
		this.server = server;
		this.accepted = accepted;
		this.client = client;
	}
}
#end
