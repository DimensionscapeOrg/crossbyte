package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	What a WebSocket session holds while it is open: what it keeps of its
	upgrade request, what its buffers keep between messages and once it has
	gone quiet, and what a server hangs on each session it lists.

	Each measured at 1,000 idle sessions natively, before these: 6.6 KB a
	session on the server, of which 2.2 KB was its request's parsed headers;
	and after one 16 KB message each way, 97 KB a session, held for as long
	as it lasted.
**/
@:access(crossbyte.net.WebSocket)
@:access(crossbyte._internal.websocket.WebSocket)
class WebSocketMemoryTest extends utest.Test {
	/**
		A request read after its session has opened, once the session has
		let go of the parsed headers and kept the head they came from, has
		every header, cookie and the origin the client sent, as it had in
		`upgrade`.
	**/
	@:timeout(15000)
	public function testARequestReadAfterTheSessionOpenedHasEveryHeader(async:Async):Void {
		__openSession(async, null, ["Origin: https://example.com", "Cookie: a=1; token=xyz", "X-Twice: one", "X-Twice: two"],
			function(server, session, peer, done) {
				var request = session.request;
				Require.notNull(request);
				Assert.isNull(@:privateAccess request.__headers, "the parsed headers were kept once the session had opened");
				Assert.equals("https://example.com", request.origin);
				Assert.equals("xyz", request.cookie("token"));
				Assert.equals("one, two", request.header("X-Twice"));
				Assert.equals("websocket", request.header("upgrade"));
				var names:Array<String> = [for (name in request.headerNames()) name];
				for (expected in ["host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version", "origin", "cookie", "x-twice"]) {
					Assert.isTrue(names.indexOf(expected) >= 0, 'header $expected was lost once the session opened');
				}
				Assert.equals("/room?id=7", request.uri);
				Assert.equals("id=7", request.query);
				done();
			});
	}

	/**
		A session that has gone quiet, nothing heard and nothing sent for a
		beat of its heartbeat, lets go of the storage its buffers held for
		the messages before: what it read into, what it framed in, what it
		sent from, and the message it handed out. It kept each at the largest
		it had needed for as long as it lasted: a 10 KB message each way left
		about 60 KB held.
	**/
	@:timeout(20000)
	public function testAQuietSessionLetsGoOfWhatItHeldForMessages(async:Async):Void {
		__openSession(async, server -> server.pingInterval = 0.2, null, function(server, session, peer, done) {
			var echoed:Bool = false;
			session.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent) {
				session.sendBinary(e.data);
				echoed = true;
			});
			peer.sendFrame(WirePeer.BINARY, Bytes.alloc(10 * 1024));
			NetPump.until(() -> {
				peer.poll();
				return echoed && peer.framesOf(WirePeer.BINARY).length > 0;
			}, 5.0, function(_) {
				var framing = session.__webSocket;
				Assert.isTrue(__held(framing) >= 10 * 1024, 'the message held ${__held(framing)} bytes, so this shows nothing');
				// Three beats: the first saw the message, the next is quiet.
				NetPump.until(() -> {
					peer.poll();
					return __held(framing) < 1024;
				}, 2.0, function(_) {
					Assert.isTrue(__held(framing) < 1024, 'a quiet session still held ${__held(framing)} bytes for its messages');
					Assert.equals(1, server.clientCount, "the session went with its storage");
					done();
				});
			});
		});
	}

	#if !(eval || nodejs)
	/**
		Output that waited for a slow peer is let go of as soon as it has
		drained, past what one pass batches (64 KB): the buffer kept what the
		backlog grew it to, here more than a megabyte, for as long as the
		session lasted.

		Not on eval, whose sockets block: a write to a peer not reading waits
		there rather than leaving bytes to hold. Nor on Node, where what waits
		is in Node's own queue and this buffer is emptied every pass.
	**/
	@:timeout(60000)
	public function testOutputThatWaitedIsLetGoOfOnceItDrains(async:Async):Void {
		__openSession(async, server -> server.maxOutputBufferSize = 0, null, function(server, session, peer, done) {
			peer.pause();
			var message = new ByteArray();
			message.length = 256 * 1024;
			var sent:Int = 0;
			var most:Int = 0;
			// Until more than a megabyte waits here. Obtained, not assumed: a
			// system's buffers take a different amount each, and Windows'
			// loopback grows to take tens of megabytes.
			NetPump.until(() -> {
				if (most > 1024 * 1024 || sent >= 256 * 1024 * 1024) {
					return true;
				}
				session.sendBinary(message);
				sent += message.length;
				var storage:Int = __storage(session.__webSocket.__pendingOutput);
				if (storage > most) {
					most = storage;
				}
				return false;
			}, 30.0, function(_) {
				peer.resume();
				NetPump.until(() -> {
					peer.poll();
					return session.outputBufferLength == 0;
				}, 25.0, function(_) {
					Assert.isTrue(most > 1024 * 1024, 'output never waited past a megabyte ($most), so this shows nothing');
					Assert.equals(0, session.outputBufferLength, "what waited never drained");
					var kept:Int = __storage(session.__webSocket.__pendingOutput);
					Assert.isTrue(kept <= 64 * 1024, 'the output buffer kept $kept bytes of storage once it had drained');
					done();
				});
			});
		});
	}
	#end

	/**
		A server hangs no listener of its own on its sessions: it is told of
		a close by the session itself, and still takes the session off its
		list. Its close listener on every session was a map, a list, an
		entry and a closure, 370 bytes natively, for as long as it lasted.
	**/
	@:timeout(15000)
	public function testTheServerHangsNoListenerOnItsSessions(async:Async):Void {
		__openSession(async, null, null, function(server, session, peer, done) {
			Assert.isFalse(session.hasEventListener(Event.CLOSE), "the server listens for its session's close");
			Assert.isNull(@:privateAccess session.__eventMap, "the session holds listeners nobody added");
			var closed:Bool = false;
			session.addEventListener(Event.CLOSE, function(_) {
				closed = true;
				// Off the server's list before anything hears of the close.
				Assert.equals(0, server.clientCount, "the session was still listed as its close was heard");
			});
			peer.close();
			NetPump.until(() -> closed, 5.0, function(_) {
				Assert.isTrue(closed);
				Assert.equals(0, server.clientCount);
				done();
			});
		});
	}

	// ------------------------------------------------------------- helpers

	/** The storage behind `buffer`, in bytes; 0 for none. **/
	private static function __storage(buffer:Null<ByteArray>):Int {
		return buffer == null ? 0 : @:privateAccess (buffer : crossbyte.io.ByteArray.ByteArrayData).__length;
	}

	/** What a session's buffers hold for messages, in bytes of storage. **/
	private static function __held(framing:crossbyte._internal.websocket.WebSocket):Int {
		return __storage(framing.__input) + __storage(framing.__output) + __storage(framing.__pendingOutput) + __storage(framing.__messageKept)
			+ __storage(framing.__maskedPayload) + __storage(framing.__outgoingMessageBuffer);
	}

	/**
		A session upgraded by a `WirePeer` sending `headers`, on a server set
		up by `configure`: `then` is called with both once the server has
		dispatched `connect`, and calls the `Void->Void` it is given when done.
	**/
	private function __openSession(async:Async, configure:Null<ServerWebSocket->Void>, headers:Null<Array<String>>,
			then:(ServerWebSocket, WebSocket, WirePeer, Void->Void) -> Void):Void {
		var server = new ServerWebSocket();
		if (configure != null) {
			configure(server);
		}
		var session:WebSocket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> session = cast e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/room?id=7", headers);
			NetPump.until(() -> {
				peer.poll();
				return session != null;
			}, 5.0, function(_) {
				if (session == null) {
					Assert.fail("the session never opened");
					peer.close();
					server.close();
					async.done();
					return;
				}
				then(server, session, peer, function() {
					peer.close();
					try session.close() catch (_:Dynamic) {}
					server.close();
					async.done();
				});
			});
		});
	}
}
