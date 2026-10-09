package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.TickEvent;
import utest.Assert;
import utest.Async;

/**
	`Socket` in a page, where it is a WebSocket underneath, against the echo
	endpoint `ci/browser/run.js` serves beside the suite: every message comes
	back as it was sent, and `close-me` asks the server to close.

	A sent buffer is cleared once it has gone, or one write would go out
	again on every tick for as long as the connection lasted.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.events.EventDispatcher)
@:access(crossbyte.net.Socket)
class BrowserSocketTest extends utest.Test {
	#if (js && !nodejs)
	private static inline var ECHO_PATH:String = "crossbyte-echo";

	@:timeout(15000)
	public function testOneWriteIsSentOnce(async:Async):Void {
		__session(function(socket, peer) {
			socket.addEventListener(Event.CONNECT, function(_) {
				socket.writeUTFBytes("one-message");
				socket.flush();
			});
		}, function(socket, peer, done) {
			NetPump.until(() -> peer.echoed.length >= "one-message".length, 5.0, function(_) {
				// Long enough for a good many more ticks, each of which would send a
				// buffer not cleared again.
				NetPump.wait(0.5, function() {
					Assert.equals("one-message", peer.echoed, "one write came back as something other than itself once");
					done();
				});
			});
		}, async);
	}

	@:timeout(15000)
	public function testAWriteMadeBeforeTheConnectionOpensIsSentOnceItDoes(async:Async):Void {
		__session(function(socket, peer) {}, function(socket, peer, done) {
			// Straight after connect(), while the page's WebSocket is still
			// connecting, when its own send() would throw.
			socket.writeUTFBytes("early");
			socket.flush();

			NetPump.until(() -> peer.echoed.length >= "early".length, 5.0, function(_) {
				NetPump.wait(0.5, function() {
					Assert.equals("early", peer.echoed, "a write made while connecting did not arrive exactly once");
					Assert.equals(0, peer.errors, "writing while connecting reported an error");
					done();
				});
			});
		}, async);
	}

	/**
		The server's close is reported once, and the socket stops: its own
		tick, which flushes it, comes off the runtime.

		It looks for the socket's own tick listener, not at a count of every
		TICK listener the runtime has, which another component's listener
		arriving or leaving would break (a Future failing with nothing
		listening adds one for a tick, to report it) whatever this socket did:
		one such listener of another's comes and goes during the case to show
		that it does not count.
	**/
	@:timeout(15000)
	public function testTheServerClosingIsReportedOnceAndTheSocketStops(async:Async):Void {
		var runtime:CrossByte = CrossByte.current();
		var passing:TickEvent->Void = null;
		passing = function(_:TickEvent):Void {
			runtime.removeEventListener(TickEvent.TICK, passing);
		};
		runtime.addEventListener(TickEvent.TICK, passing);

		var tickedWhileOpen:Bool = false;
		__session(function(socket, peer) {
			socket.addEventListener(Event.CONNECT, function(_) {
				tickedWhileOpen = __ticking(socket);
				socket.writeUTFBytes("close-me");
				socket.flush();
			});
		}, function(socket, peer, done) {
			NetPump.until(() -> peer.closes > 0, 5.0, function(_) {
				NetPump.wait(0.3, function() {
					Assert.equals(1, peer.closes, "the server's close was not reported exactly once");
					Assert.isFalse(socket.connected, "the socket still says it is connected after the server closed");
					Assert.isTrue(tickedWhileOpen, "the open socket was not on the runtime's tick, so its absence says nothing");
					Assert.isFalse(__ticking(socket), "the closed socket is still flushed from every tick");
					done();
				});
			});
		}, async);
	}

	/**
		A `NetConnection` over a page's socket carries data, its send stamping
		the time from the page's clock, not a field only a native connect sets,
		which would throw a TypeError in a page.
	**/
	@:timeout(15000)
	public function testANetConnectionCarriesDataOverAPageSocket(async:Async):Void {
		var port:Null<Int> = Std.parseInt(js.Browser.location.port);
		if (port == null || port <= 0) {
			Assert.warn("the page was not served by ci/browser/run.js, so there is no echo endpoint to reach");
			async.done();
			return;
		}

		var message:String = "netconnection-in-a-page";
		var heard:String = "";
		var failure:String = null;
		var socket = new Socket();
		var connection:NetConnection = NetConnection.fromSocket(socket);
		connection.onData = input -> heard += input.readUTFBytes(input.bytesAvailable);
		connection.onError = reason -> failure = Std.string(reason);
		connection.onReady = function() {
			var bytes = new crossbyte.io.ByteArray();
			bytes.writeUTFBytes(message);
			bytes.position = 0;
			try {
				connection.send(bytes);
			} catch (e:Dynamic) {
				failure = "send threw: " + Std.string(e);
			}
		};
		connection.readEnabled = true;
		socket.connect(js.Browser.location.hostname + "/" + ECHO_PATH, port);

		NetPump.until(() -> heard.length >= message.length || failure != null, 5.0, function(_) {
			Assert.isNull(failure, "the connection failed: " + failure);
			Assert.equals(message, heard, "what the connection sent did not come back");
			try connection.close() catch (_:Dynamic) {}
			async.done();
		});
	}

	/**
		A `NetConnection` over a page's socket is not `connected` inside its
		`onClose`, whether it closed itself or the server closed it, as
		natively: it read `true` there.
	**/
	@:timeout(15000)
	public function testANetConnectionIsNotConnectedInsideItsOnClose(async:Async):Void {
		var port:Null<Int> = Std.parseInt(js.Browser.location.port);
		if (port == null || port <= 0) {
			Assert.warn("the page was not served by ci/browser/run.js, so there is no echo endpoint to reach");
			async.done();
			return;
		}

		var wrong:Array<String> = [];
		var closes:Int = 0;
		var ready:Int = 0;
		var mine:NetConnection = null;
		var theirs:NetConnection = null;
		mine = new NetConnection('ws://${js.Browser.location.hostname}:$port/$ECHO_PATH', null, () -> ready++, reason -> {
			closes++;
			if (mine.connected) {
				wrong.push("closed by itself, after " + reason);
			}
		});
		theirs = new NetConnection('ws://${js.Browser.location.hostname}:$port/$ECHO_PATH', null, () -> ready++, reason -> {
			closes++;
			if (theirs.connected) {
				wrong.push("closed by the server, after " + reason);
			}
		});

		NetPump.until(() -> ready == 2, 5.0, function(_) {
			mine.close();
			var bytes = new crossbyte.io.ByteArray();
			bytes.writeUTFBytes("close-me");
			bytes.position = 0;
			theirs.send(bytes);
			NetPump.until(() -> closes == 2, 5.0, function(_) {
				Assert.equals(2, closes, "both connections did not close");
				Assert.same([], wrong, "a connection said it was connected inside onClose: " + wrong.join("; "));
				async.done();
			});
		});
	}

	/**
		A `socketData` event's `bytesLoaded` is what arrived for it, as it
		is natively, not everything still unread.
	**/
	@:timeout(15000)
	public function testBytesLoadedIsWhatArrived(async:Async):Void {
		var port:Null<Int> = Std.parseInt(js.Browser.location.port);
		if (port == null || port <= 0) {
			Assert.warn("the page was not served by ci/browser/run.js, so there is no echo endpoint to reach");
			async.done();
			return;
		}

		var socket = new Socket();
		var loaded:Array<Int> = [];
		// Nothing is read, so the first message is still unread when the
		// second arrives.
		socket.addEventListener(ProgressEvent.SOCKET_DATA, function(e:ProgressEvent) loaded.push(e.bytesLoaded));
		socket.addEventListener(Event.CONNECT, function(_) {
			socket.writeUTFBytes("abc");
			socket.flush();
		});
		socket.connect(js.Browser.location.hostname + "/" + ECHO_PATH, port);

		NetPump.until(() -> loaded.length >= 1, 5.0, function(_) {
			socket.writeUTFBytes("defg");
			socket.flush();
			NetPump.until(() -> socket.bytesAvailable >= 7, 5.0, function(_) {
				Assert.same([3, 4], loaded, "bytesLoaded was not what arrived for each event");
				try socket.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		One socket connected to the echo endpoint: `before` runs ahead of
		`connect()`, `after` once it has been called, and everything is
		closed when `after` says it is finished.
	**/
	private function __session(before:(Socket, EchoPeer)->Void, after:(Socket, EchoPeer, Void->Void)->Void, async:Async):Void {
		var port:Null<Int> = Std.parseInt(js.Browser.location.port);
		if (port == null || port <= 0) {
			Assert.warn("the page was not served by ci/browser/run.js, so there is no echo endpoint to reach");
			async.done();
			return;
		}

		var socket = new Socket();
		var peer = new EchoPeer();
		socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) peer.echoed += socket.readUTFBytes(socket.bytesAvailable));
		socket.addEventListener(Event.CLOSE, function(_) peer.closes++);
		socket.addEventListener(crossbyte.events.IOErrorEvent.IO_ERROR, function(_) peer.errors++);

		before(socket, peer);
		socket.connect(js.Browser.location.hostname + "/" + ECHO_PATH, port);

		after(socket, peer, function() {
			try socket.close() catch (_:Dynamic) {}
			async.done();
		});
	}

	/** Whether `socket`'s own tick listener, which flushes it, is on the runtime's tick. **/
	private static function __ticking(socket:Socket):Bool {
		var map = CrossByte.current().__eventMap;
		var listeners:Array<Dynamic> = map == null ? null : map.get(TickEvent.TICK);
		if (listeners == null) {
			return false;
		}
		for (entry in listeners) {
			if (Reflect.compareMethods(entry.listener, socket.this_onTick)) {
				return true;
			}
		}
		return false;
	}
	#end
}

#if (js && !nodejs)
private class EchoPeer {
	public var echoed:String = "";
	public var closes:Int = 0;
	public var errors:Int = 0;

	public function new() {}
}
#end
