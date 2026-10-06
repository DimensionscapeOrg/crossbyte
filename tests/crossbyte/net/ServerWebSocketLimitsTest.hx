package crossbyte.net;

import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	What one peer can make a `ServerWebSocket` hold or do before, and while,
	it is a session, every limit a public listener leans on, each at its
	edge and past it.

	Peers are `WirePeer`s, so each says exactly what goes on the wire, on
	every target, Node included.
**/
class ServerWebSocketLimitsTest extends utest.Test {
	// The default maxHeaderSize, as a literal: these cases also build against
	// the sources before it existed (-D ws_before), to show them failing.
	private static inline var HEADER_LIMIT:Int = 16 * 1024;

	// ---- maxHeaderSize: the upgrade request ------------------------------

	#if !ws_before
	public function testTheDefaultHeaderLimitIsNodes():Void {
		Assert.equals(HEADER_LIMIT, new ServerWebSocket().maxHeaderSize);
	}
	#end

	/** A request of exactly `maxHeaderSize` bytes is answered, as any is. **/
	@:timeout(15000)
	public function testAnUpgradeRequestAtTheLimitIsAnswered(async:Async):Void {
		__upgradeOfSize(HEADER_LIMIT, function(server, peer, head) {
			Assert.notNull(head, "a request at the limit was not answered");
			Assert.isTrue(head != null && head.indexOf(" 101 ") > 0, "a request at the limit was not upgraded: " + head);
			Assert.equals(1, server.clientCount, "a request at the limit did not become a session");
		}, async);
	}

	/**
		A request one byte longer is refused with 431, as the HTTP server
		refuses a head too large, and counted as a failed handshake.
	**/
	@:timeout(15000)
	public function testAnUpgradeRequestPastTheLimitIsRefusedWith431(async:Async):Void {
		__upgradeOfSize(HEADER_LIMIT + 1, function(server, peer, head) {
			Assert.isTrue(head != null && head.indexOf(" 431 ") > 0, "a request past the limit was not refused with 431: " + head);
			Assert.equals(0, server.clientCount, "a request past the limit became a session");
			NetPump.until(() -> {
				peer.poll();
				return peer.ended;
			}, 5.0, function(_) {});
			Assert.isTrue(peer.ended, "the connection of a refused request was left open");
			Assert.equals(1, server.handshakeFailures, "a request refused for its size was not counted as a failed handshake");
		}, async);
	}

	/**
		A request whose head never ends is refused once `maxHeaderSize` of it
		has arrived, not when the peer stops or `handshakeTimeout` passes.

		Each arrival was appended to a string, copied whole every time, and
		the whole of it searched again for the end: one connection sending
		a header without end made a server hold 221 MB in 10 s, with single
		passes of a second. Here the deadline is a minute, so only the limit
		can end it; and what the session held of it is read off as it goes.
	**/
	@:timeout(30000)
	public function testAnUpgradeRequestWithoutEndIsRefusedAtTheLimit(async:Async):Void {
		var server = new ServerWebSocket();
		server.handshakeTimeout = 60;
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.send(Bytes.ofString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Endless: "));

			var piece:Bytes = Bytes.alloc(1024);
			piece.fill(0, piece.length, "a".code);
			var sent:Int = 0;
			var held:Int = 0;
			var limit:Int = 1024 * 1024;

			// One piece a pass, until the server lets go or a megabyte has
			// gone, sixty-four times the limit.
			NetPump.until(() -> {
				peer.poll();
				if (peer.ended || sent >= limit) {
					return true;
				}
				peer.send(piece);
				sent += piece.length;
				var session = __upgrading(server);
				if (session != null) {
					var input = @:privateAccess session.__input;
					if (input != null && input.length > held) {
						held = input.length;
					}
				}
				return false;
			}, 20.0, function(_) {
				// The answer may be lost to the reset a close with the peer
				// still sending makes; the close is what matters.
				NetPump.until(() -> {
					peer.poll();
					return peer.ended;
				}, 5.0, function(_) {
					var max:Int = HEADER_LIMIT;
					Assert.isTrue(peer.ended, 'a request without end was still being read after $sent bytes');
					Assert.isTrue(sent <= max + 256 * 1024, 'the request was refused only after $sent bytes, against a limit of $max');
					Assert.isTrue(held <= max + 128 * 1024, 'the session held $held bytes of the request, against a limit of $max');
					Assert.equals(0, server.clientCount);
					peer.close();
					server.close();
					async.done();
				});
			});
		});
	}

	#if !ws_before
	/** A `maxHeaderSize` of 0 reads a request of any size. **/
	@:timeout(15000)
	public function testAMaxHeaderSizeOfZeroReadsAnyRequest(async:Async):Void {
		__upgradeOfSize(64 * 1024, function(server, peer, head) {
			Assert.isTrue(head != null && head.indexOf(" 101 ") > 0, "a request with no limit was not upgraded: " + head);
		}, async, server -> server.maxHeaderSize = 0);
	}
	#end

	// ---- maxOutputBufferSize, and pings from a peer not reading ----------

	#if !ws_before
	public function testTheOutputLimitIsOnByDefault():Void {
		Assert.equals(8 * 1024 * 1024, new ServerWebSocket().maxOutputBufferSize);
	}
	#end

	#if !eval
	/**
		A peer that reads nothing is closed once 8 MiB wait for it, by
		default, with an `ioError` saying why and 1011; what waited is let
		go. There was no limit unless the application set one: everything
		sent to such a peer was held, without end.

		Not on eval, whose sockets block: a write to a peer not reading
		waits there rather than leaving bytes to hold.
	**/
	@:timeout(60000)
	public function testAPeerThatReadsNothingIsClosedAtTheDefaultOutputLimit(async:Async):Void {
		__openSession(async, null, function(server, session, peer, done) {
			peer.pause();
			var error:String = null;
			var code:Int = -1;
			var most:Int = 0;
			session.addEventListener(crossbyte.events.IOErrorEvent.IO_ERROR, (e:crossbyte.events.IOErrorEvent) -> error = e.text);
			session.addEventListener(crossbyte.events.Event.CLOSE, function(e:crossbyte.events.Event) {
				var close = Std.downcast(e, crossbyte.events.WebSocketCloseEvent);
				code = close == null ? 0 : close.code;
			});
			var message = new crossbyte.io.ByteArray();
			message.length = 256 * 1024;
			var sent:Int = 0;
			var ceiling:Int = 48 * 1024 * 1024;

			// A quarter megabyte a pass until the session is closed, or six
			// times the limit has been sent.
			NetPump.until(() -> {
				if (code >= 0 || sent >= ceiling) {
					return true;
				}
				try {
					session.sendBinary(message);
					sent += message.length;
				} catch (_:Dynamic) {
					return true;
				}
				var waiting:Int = session.outputBufferLength;
				if (waiting > most) {
					most = waiting;
				}
				return false;
			}, 40.0, function(_) {
				Assert.equals(1011, code, 'a peer reading nothing was not closed: $sent bytes sent, $most waiting');
				Assert.isTrue(error != null && error.indexOf("not reading") >= 0, "the session did not say why it closed: " + error);
				Assert.isTrue(most <= 8 * 1024 * 1024 + message.length, 'the session held $most bytes past an 8 MiB limit');
				done();
			});
		});
	}

	/**
		A peer that pings and reads nothing is owed one answer, the newest
		ping's, however many it sends: RFC 6455 5.5.3 lets a pong answer
		only the most recent ping. Each ping had a pong of its own, piling up
		behind the peer that read none of them, 32 MB in 10 s natively,
		with passes of 1.4 s, and each was offered to the full socket as it
		was made.
	**/
	@:timeout(60000)
	public function testAPeerPingingAndReadingNothingIsAnsweredOnceWithTheNewest(async:Async):Void {
		__openSession(async, server -> server.maxOutputBufferSize = 0, function(server, session, peer, done) {
			peer.pause();
			// First the peer falls behind: enough sent that some of it waits
			// here, the system's buffers full. Obtained, not assumed: how much
			// they take differs by system.
			var message = new crossbyte.io.ByteArray();
			message.length = 256 * 1024;
			var sent:Int = 0;
			NetPump.until(() -> {
				if (session.outputBufferLength > 0 || sent >= 256 * 1024 * 1024) {
					return true;
				}
				session.sendBinary(message);
				sent += message.length;
				return false;
			}, 30.0, function(_) {
				var behind:Int = session.outputBufferLength;
				Assert.isTrue(behind > 0, 'nothing ever waited for the peer after $sent bytes, so this shows nothing');

				// Twenty thousand pings, each carrying its number, a thousand
				// a pass; then a little longer for the last of them to be read.
				var pings:Int = 20000;
				var next:Int = 0;
				var longest:Float = 0;
				var last:Float = haxe.Timer.stamp();
				var settledAt:Float = -1;
				NetPump.until(() -> {
					var now:Float = haxe.Timer.stamp();
					if (now - last > longest) {
						longest = now - last;
					}
					last = now;
					if (next < pings) {
						var batch = new haxe.io.BytesBuffer();
						for (_ in 0...1000) {
							batch.add(__maskedPing(next++));
						}
						peer.send(batch.getBytes());
						return false;
					}
					if (settledAt < 0) {
						settledAt = now;
					}
					return now - settledAt > 1.0;
				}, 30.0, function(_) {
					var grew:Int = session.outputBufferLength - behind;
					// A pong of a 4-byte ping is 6 bytes; two at most wait.
					Assert.isTrue(grew <= 12, '$pings pings left $grew bytes of answers waiting for a peer reading nothing');
					Assert.isTrue(longest < 1.0, 'a pass took ${Math.round(longest * 1000)} ms while the pings were read');

					// The peer reads at last: its data, then one or two pongs,
					// the last answering the last ping.
					peer.resume();
					NetPump.until(() -> {
						peer.poll();
						return peer.receivedLength() >= sent || peer.ended;
					}, 30.0, function(_) {
						NetPump.wait(0.3, function() {
							peer.poll();
							var pongs = peer.framesOf(WirePeer.PONG);
							Assert.isTrue(pongs.length >= 1 && pongs.length <= 2, '${pongs.length} pongs answered $pings pings');
							if (pongs.length > 0) {
								var lastPong = pongs[pongs.length - 1].payload;
								Assert.equals(pings - 1, lastPong.length == 4 ? lastPong.getInt32(0) : -1, "the last pong did not answer the last ping");
							}
							done();
						});
					});
				});
			});
		});
	}
	#end

	// ------------------------------------------------------------- helpers

	/**
		A session upgraded by a `WirePeer`, on a server set up by `configure`:
		`then` is called with both once the server has dispatched `connect`,
		and calls the `Void->Void` it is given when done.
	**/
	private function __openSession(async:Async, configure:Null<ServerWebSocket->Void>, then:(ServerWebSocket, WebSocket, WirePeer, Void->Void) -> Void):Void {
		__async = async;
		var server = new ServerWebSocket();
		if (configure != null) {
			configure(server);
		}
		var session:WebSocket = null;
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, e -> session = cast e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade();
			NetPump.until(() -> {
				peer.poll();
				return session != null;
			}, 5.0, function(_) {
				Assert.notNull(session, "the session never opened");
				if (session == null) {
					peer.close();
					server.close();
					__done();
					return;
				}
				then(server, session, peer, function() {
					peer.close();
					try session.close() catch (_:Dynamic) {}
					server.close();
					__done();
				});
			});
		});
	}

	// The case under way's Async, for __openSession's cases.
	private var __async:Null<Async> = null;

	private function __done():Void {
		var async = __async;
		__async = null;
		if (async != null) {
			async.done();
		}
	}

	/** A client's ping carrying `n` as four bytes, masked. **/
	private static function __maskedPing(n:Int):Bytes {
		var frame = Bytes.alloc(10);
		frame.set(0, 0x89);
		frame.set(1, 0x80 | 4);
		var mask = [0x12, 0x34, 0x56, 0x78];
		for (i in 0...4) {
			frame.set(2 + i, mask[i]);
		}
		var payload = Bytes.alloc(4);
		payload.setInt32(0, n);
		for (i in 0...4) {
			frame.set(6 + i, payload.get(i) ^ mask[i]);
		}
		return frame;
	}

	/**
		An upgrade request `size` bytes long, head and all, to a server set up
		by `configure`; `check` is called with the response head once it has
		arrived, or null if none did.
	**/
	private function __upgradeOfSize(size:Int, check:(ServerWebSocket, WirePeer, Null<String>) -> Void, async:Async,
			?configure:ServerWebSocket->Void):Void {
		var server = new ServerWebSocket();
		if (configure != null) {
			configure(server);
		}
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			var head:String = [
				"GET / HTTP/1.1",
				"Host: 127.0.0.1",
				"Upgrade: websocket",
				"Connection: Upgrade",
				"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
				"Sec-WebSocket-Version: 13",
				"X-Pad: "
			].join("\r\n");
			// The rest of the size in the last header's value, then the blank
			// line that ends the head.
			var pad:Int = size - head.length - 4;
			var request = new StringBuf();
			request.add(head);
			for (_ in 0...pad) {
				request.add("p");
			}
			request.add("\r\n\r\n");
			var bytes = Bytes.ofString(request.toString());
			Assert.equals(size, bytes.length, "the request was not the size asked for");
			peer.send(bytes);

			NetPump.until(() -> {
				peer.poll();
				return peer.head() != null || peer.ended;
			}, 5.0, function(_) {
				// A little longer, for the server's own bookkeeping after it.
				NetPump.wait(0.1, function() {
					peer.poll();
					check(server, peer, peer.head());
					peer.close();
					server.close();
					async.done();
				});
			});
		});
	}

	/** The one session `server` is waiting on to upgrade, or null. **/
	private static function __upgrading(server:ServerWebSocket):Null<crossbyte._internal.websocket.WebSocket> {
		var pending:Array<Dynamic> = @:privateAccess server.__pendingUpgrades;
		if (pending.length == 0) {
			return null;
		}
		var session:WebSocket = pending[0].session;
		return session == null ? null : @:privateAccess session.__webSocket;
	}
}
