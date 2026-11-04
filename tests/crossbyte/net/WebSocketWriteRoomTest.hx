package crossbyte.net;

import utest.Assert;
#if (target.threaded && !js && !eval)
import crossbyte._internal.socket.IPollableSocket;
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
#end

/**
	What a WebSocket session sends and the system will not take yet goes as
	soon as the system has room, as a `Socket`'s does: see `SocketWriteRoomTest`,
	which says why these run on a `POLL` runtime at a tick a second, and why
	they send a slice at a time to a peer reading as fast as it can.

	A session has no drain of its own to send more from, so these stand in for
	the session in its socket's `custom`, which the registry calls, and send
	more when it has been told. Not on the interpreter, which cannot frame what
	these send in the time a runtime is given to run it.
**/
@:timeout(40000)
@:access(crossbyte.net.WebSocket)
@:access(crossbyte.net.Socket)
@:access(crossbyte._internal.websocket.WebSocket)
@:access(crossbyte.core.CrossByte)
class WebSocketWriteRoomTest extends utest.Test {
	#if (target.threaded && !js && !eval)
	private static inline var IN_TIME:Float = 25.0;
	private static inline var STALL:Float = 0.25;
	private static inline var SLICE:Int = 64 * 1024;
	private static inline var KEPT_PENDING:Int = 256 * 1024;
	// A frame of SLICE bytes from a server: two bytes, and eight of length.
	private static inline var FRAME:Int = SLICE + 10;

	/** A peer reading as fast as it can is sent all of it without a stall. **/
	public function testWhatWaitsGoesAsTheSystemTakesIt():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));

		var got:Int = __read(pair, __wire(), IN_TIME);
		__done(pair);

		Assert.equals(__wire(), got, 'a reading peer was sent $got bytes');
		Assert.isTrue(pair.stalls <= 1, 'a peer reading as fast as it could waited on the session ${pair.stalls} times');
	}

	/**
		A peer that stops reading wakes nothing, and what waits goes on as soon
		as it reads again. Windows grows a socket's send buffer once a second
		or so, and what that takes is reported, so a few are not the session
		being asked after. Woken for each report of a socket with no room, this
		would count in the millions.
	**/
	public function testAPeerThatStopsReadingCostsNoPasses():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));
		var waiting:Bool = __untilWaiting(pair);
		var before:Int = pair.told;

		crossbyte.sys.System.sleep(1.5);
		var whileStopped:Int = pair.told - before;

		var got:Int = __read(pair, __wire(), IN_TIME);
		__done(pair);

		Assert.isTrue(waiting, "the session never had to wait, so this shows nothing");
		Assert.isTrue(whileStopped <= 20, 'a socket with no room was told $whileStopped times in 1.5 s at a tick a second');
		Assert.equals(__wire(), got, 'a peer that read again was sent $got bytes');
		Assert.isTrue(pair.stalls <= 1, 'a peer that read again waited on the session ${pair.stalls} times');
	}

	/** A peer that leaves with frames waiting for it ends the session, and leaves nothing watched. **/
	public function testAPeerThatLeavesLeavesNothingWatched():Void {
		var pair:Pair = __pair();
		var closes:Int = 0;
		SpreadSupport.on(pair.runtime, () -> {
			pair.session.addEventListener(Event.CLOSE, _ -> closes++);
			__feed(pair);
		});
		var waiting:Bool = __untilWaiting(pair);

		pair.client.close();
		var ended:Bool = SpreadSupport.waitFor(() -> closes > 0, 10.0);
		crossbyte.sys.System.sleep(0.2);
		var nothingLeft:Bool = SpreadSupport.on(pair.runtime, () -> __nothingWatched(pair));
		__done(pair, true);

		Assert.isTrue(waiting, "the session never had to wait, so this shows nothing");
		Assert.isTrue(ended, "the session did not end when its peer left");
		Assert.equals(1, closes);
		Assert.isTrue(nothingLeft, "a session that ended was left watched for room");
	}

	/**
		A report of room that takes nothing is not believed twice: reported
		again at once, it would keep the runtime from ever sleeping. What waits
		is asked after once a pass instead, and goes back to waiting in the poll
		once something moves.
	**/
	public function testAReportThatMovesNothingCannotSpin():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair));
		var waiting:Bool = __untilWaiting(pair);

		var wasWatched:Bool = SpreadSupport.on(pair.runtime, () -> pair.inner.__waitingForRoom);
		var nothingWatched:Bool = SpreadSupport.on(pair.runtime, () -> {
			pair.inner.registryOnWritable();
			return __nothingWatched(pair);
		});
		var notBelieved:Bool = SpreadSupport.on(pair.runtime, () -> pair.inner.__roomNotReported);

		var got:Int = __read(pair, __wire(), IN_TIME);
		var believedAgain:Bool = SpreadSupport.on(pair.runtime, () -> !pair.inner.__roomNotReported);
		__done(pair);

		Assert.isTrue(waiting && wasWatched, "the session never had to wait, so this shows nothing");
		Assert.isTrue(nothingWatched, "a report that moved nothing left the socket watched");
		Assert.isTrue(notBelieved, "a report that moved nothing was believed");
		Assert.equals(__wire(), got, 'what waited stopped at $got bytes once a report had moved nothing');
		Assert.isTrue(believedAgain, "the session never went back to waiting in the poll");
	}

	/**
		What waits can be taken by the flush that ends a pass, or by a send from
		another thread. The report that follows finds nothing to do, and the
		socket does not stay watched, reported writable for good.
	**/
	public function testAFlushFromElsewhereLeavesNothingWatched():Void {
		var pair:Pair = __pair();
		SpreadSupport.on(pair.runtime, () -> __feed(pair, __small()));
		var waiting:Bool = __untilWaiting(pair);

		var held:sys.thread.Lock = new sys.thread.Lock();
		var holding:sys.thread.Lock = new sys.thread.Lock();
		pair.runtime.post(() -> {
			holding.release();
			held.wait(10.0);
			pair.inner.__flushPendingOutput();
		});
		holding.wait(10.0);
		var got:Int = __readWhatIsThere(pair);
		held.release();
		got += __read(pair, __wire(__small()) - got, 8.0);
		var settled:Bool = SpreadSupport.waitFor(() -> SpreadSupport.on(pair.runtime, () -> __nothingWatched(pair)), 5.0);
		__done(pair);

		Assert.isTrue(waiting, "the session never had to wait, so this shows nothing");
		Assert.equals(__wire(__small()), got, 'a peer that read it all was sent $got bytes');
		Assert.isTrue(settled, "a socket with nothing waiting stayed watched for room");
	}

	/** How much to send: refused a good many times, in what a slow target gets through in a few seconds. **/
	private static function __size():Int {
		return #if (cpp || java || jvm) 128 * 1024 * 1024 #else 32 * 1024 * 1024 #end;
	}

	/** A little past what the system holds with nobody reading, here or on Windows as its buffer grows. **/
	private static inline function __small():Int {
		return 16 * 1024 * 1024;
	}

	/** What `size` bytes are on the wire. **/
	private static function __wire(?size:Int):Int {
		return Std.int((size == null ? __size() : size) / SLICE) * FRAME;
	}

	private function __pair():Pair {
		var runtime:CrossByte = SpreadSupport.runtime(1);
		var session:Null<WebSocket> = null;
		var server:ServerWebSocket = SpreadSupport.on(runtime, () -> {
			var listener:ServerWebSocket = new ServerWebSocket();
			listener.addEventListener(ServerSocketConnectEvent.CONNECT, e -> session = cast e.socket);
			listener.bind(0, "127.0.0.1");
			listener.listen();
			return listener;
		});

		var client:sys.net.Socket = SpreadSupport.connect(server.localPort);
		client.output.writeString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
			+ "Sec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nSec-WebSocket-Version: 13\r\n\r\n");
		while (client.input.readLine() != "") {}
		Assert.isTrue(SpreadSupport.waitFor(() -> session != null, 10.0), "no session opened");
		return new Pair(runtime, server, session, client);
	}

	/** Sends a slice at a time, for as long as little is waiting, and again each time the session is told of room. **/
	private static function __feed(pair:Pair, ?size:Int):Void {
		var piece:ByteArray = new ByteArray();
		for (i in 0...SLICE) {
			piece.writeByte(i & 0xFF);
		}
		var left:Int = size == null ? __size() : size;
		function more():Void {
			while (left > 0 && pair.session.connected && pair.session.outputBufferLength < KEPT_PENDING) {
				pair.session.sendBinary(piece, 0, SLICE);
				left -= SLICE;
			}
		}
		pair.inner.__socket.custom = new Told(pair, more);
		more();
	}

	/** As `SocketWriteRoomTest`'s, which says what `stalls` counts. **/
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

	/** Until the system has stopped taking what is sent, and says whether it has. **/
	private static function __untilWaiting(pair:Pair):Bool {
		var last:Int = -1;
		return SpreadSupport.waitFor(() -> {
			var pending:Int = SpreadSupport.on(pair.runtime, () -> pair.session.outputBufferLength);
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
			try {
				pair.server.close();
			} catch (_:Dynamic) {}
			if (pair.session.connected) {
				try {
					pair.session.close();
				} catch (_:Dynamic) {}
			}
			return true;
		});
		SpreadSupport.stop([pair.runtime]);
	}
	#end
}

#if (target.threaded && !js && !eval)
private class Pair {
	public final runtime:CrossByte;
	public final server:ServerWebSocket;
	public final session:WebSocket;
	public final inner:crossbyte._internal.websocket.WebSocket;
	public final client:sys.net.Socket;

	/** Times the registry told the session it could write. */
	public var told:Int = 0;

	/** Gaps of `STALL` or more between arrivals at the client. */
	public var stalls:Int = 0;

	@:access(crossbyte.net.WebSocket)
	public function new(runtime:CrossByte, server:ServerWebSocket, session:WebSocket, client:sys.net.Socket) {
		this.runtime = runtime;
		this.server = server;
		this.session = session;
		this.inner = session.__webSocket;
		this.client = client;
	}
}

/** The session, to the registry, with more sent each time it is told it can write. **/
private class Told implements IPollableSocket {
	public var registryClosed(get, never):Bool;

	private final __pair:Pair;
	private final __more:Void->Void;

	public function new(pair:Pair, more:Void->Void) {
		__pair = pair;
		__more = more;
	}

	public function registryOnReadable():Void {
		__pair.inner.registryOnReadable();
	}

	public function registryOnWritable():Void {
		__pair.told++;
		__pair.inner.registryOnWritable();
		__more();
	}

	public function registryHasBufferedInput():Bool {
		return __pair.inner.registryHasBufferedInput();
	}

	private function get_registryClosed():Bool {
		return __pair.inner.registryClosed;
	}
}
#end
