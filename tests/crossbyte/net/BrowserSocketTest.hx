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

	Nothing ran a page's socket against anything before, and it could not have
	passed: the buffer was sent and never cleared, so one write went out again
	on every tick for as long as the connection lasted.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.events.EventDispatcher)
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
				// Long enough for a good many more ticks, each of which sent the
				// whole buffer again.
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
			// connecting -- when send() throws.
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

	@:timeout(15000)
	public function testTheServerClosingIsReportedOnceAndTheSocketStops(async:Async):Void {
		var before:Int = __tickListeners();

		__session(function(socket, peer) {
			socket.addEventListener(Event.CONNECT, function(_) {
				socket.writeUTFBytes("close-me");
				socket.flush();
			});
		}, function(socket, peer, done) {
			NetPump.until(() -> peer.closes > 0, 5.0, function(_) {
				NetPump.wait(0.3, function() {
					Assert.equals(1, peer.closes, "the server's close was not reported exactly once");
					Assert.isFalse(socket.connected, "the socket still says it is connected after the server closed");
					Assert.equals(before, __tickListeners(), "the closed socket is still flushed from every tick");
					done();
				});
			});
		}, async);
	}

	/**
		A `NetConnection` over a page's socket carries data. Its send stamped
		the time from a field only a native connect sets, and threw a
		TypeError in a page.
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
		A `socketData` event's `bytesLoaded` is what arrived for it, as it
		is natively; in a page it was everything still unread.
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

	private static function __tickListeners():Int {
		var listeners:Array<Dynamic> = CrossByte.current().__eventMap == null ? null : CrossByte.current().__eventMap.get(TickEvent.TICK);
		return listeners == null ? 0 : listeners.length;
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
