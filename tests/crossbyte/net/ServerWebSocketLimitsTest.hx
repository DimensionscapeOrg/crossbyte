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

	// ---- maxPendingHandshakesPerAddress ----------------------------------

	#if !ws_before
	public function testTheDefaultsAreSixteenAnAddressAndTenThousandSessions():Void {
		var server = new ServerWebSocket();
		Assert.equals(16, server.maxPendingHandshakesPerAddress);
		Assert.equals(10000, server.maxConnections);
		Assert.equals(1024 * 1024, server.maxMessageSize);
		Assert.equals(0, server.refusedConnections);
	}
	#end

	/**
		One address opening connections and saying nothing takes half the
		places for upgrades and no more: past that, each of its connections
		is closed as it is accepted, and the other half is there for every
		other address. It took every place, and every real client waited
		behind it, 8-9 s a join, for as long as it went on.
	**/
	@:timeout(20000)
	public function testOneSilentAddressTakesHalfThePlacesAndNoMore(async:Async):Void {
		var server = new ServerWebSocket();
		server.maxPendingHandshakes = 8;
		#if !ws_before
		server.maxPendingHandshakesPerAddress = 2;
		#end
		server.handshakeTimeout = 30;
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [];
			var opened:Int = 0;
			// One at a time, each taken before the next, so the order the
			// limits apply in is the order they connected in.
			NetPump.until(() -> {
				for (peer in peers) {
					peer.poll();
				}
				if (opened < 10 && (peers.length == 0 || __pending(server) + __ended(peers) >= opened)) {
					peers.push(new WirePeer(server.localPort));
					opened++;
				}
				return opened >= 10 && __pending(server) + __ended(peers) >= 10;
			}, 10.0, function(_) {
				Assert.equals(4, __pending(server), "one address held other than half the places");
				Assert.equals(6, __ended(peers), "its connections past half the places were not closed");
				#if !ws_before
				Assert.equals(6, server.refusedConnections);
				Assert.equals(0, server.handshakeFailures, "a refusal was counted as a failed handshake");
				// Another address is taken while this one is held to its share,
				// and counted; this one is not.
				Assert.isTrue(@:privateAccess server.__claimAddress("192.0.2.7"), "another address was refused");
				Assert.isFalse(@:privateAccess server.__claimAddress("127.0.0.1"), "the crowding address was taken again");
				@:privateAccess server.__addressCounts.release("192.0.2.7");
				#end
				for (peer in peers) {
					peer.close();
				}
				server.close();
				async.done();
			});
		});
	}

	/**
		While the places are not crowded, one address is not limited: many
		clients can share one, a carrier's NAT, an office, a proxy.
	**/
	@:timeout(20000)
	public function testWhileThePlacesAreNotCrowdedOneAddressIsNotLimited(async:Async):Void {
		var server = new ServerWebSocket();
		#if !ws_before
		server.maxPendingHandshakesPerAddress = 2;
		#end
		server.handshakeTimeout = 30;
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [for (_ in 0...20) new WirePeer(server.localPort)];
			NetPump.until(() -> __pending(server) + __ended(peers) >= 20, 10.0, function(_) {
				Assert.equals(20, __pending(server), "connections were refused with 236 of 256 places free");
				Assert.equals(0, __ended(peers));
				for (peer in peers) {
					peer.close();
				}
				server.close();
				async.done();
			});
		});
	}

	#if !ws_before
	/**
		An address's count goes down as each of its connections stops
		arriving, upgraded, gone, or given up on at `handshakeTimeout`,
		and the address is forgotten at none.
	**/
	@:timeout(20000)
	public function testAnAddressIsCountedOnlyWhileItsConnectionsArrive(async:Async):Void {
		var server = new ServerWebSocket();
		server.handshakeTimeout = 1.5;
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [for (_ in 0...3) new WirePeer(server.localPort)];
			NetPump.until(() -> __pending(server) >= 3, 5.0, function(_) {
				Assert.equals(3, __counted(server));
				peers[0].upgrade();
				peers[1].close();
				NetPump.until(() -> {
					for (peer in peers) {
						peer.poll();
					}
					return __counted(server) <= 1;
				}, 5.0, function(_) {
					Assert.equals(1, __counted(server), "an upgraded or vanished connection was still counted");
					// The last says nothing until its deadline.
					NetPump.until(() -> __counted(server) == 0, 5.0, function(_) {
						Assert.equals(0, __counted(server), "a connection given up on was still counted");
						for (peer in peers) {
							peer.close();
						}
						server.close();
						async.done();
					});
				});
			});
		});
	}

	// ---- maxConnections --------------------------------------------------

	/**
		With `maxConnections` open, an upgrade is answered 503 and its
		connection closed, `upgrade` not asked, counted as refused and not
		as a failed handshake; once a session closes, the next is taken.
	**/
	@:timeout(20000)
	public function testPastMaxConnectionsAnUpgradeIsAnswered503(async:Async):Void {
		var asked:Int = 0;
		__openSession(async, function(server) {
			server.maxConnections = 2;
			server.upgrade = function(request) {
				asked++;
				return true;
			};
		}, function(server, first, peer, done) {
			var second = new WirePeer(server.localPort);
			second.upgrade();
			NetPump.until(() -> {
				second.poll();
				return second.head() != null;
			}, 5.0, function(_) {
				Assert.isTrue(second.head() != null && second.head().indexOf(" 101 ") > 0, "the second session was refused: " + second.head());
				var third = new WirePeer(server.localPort);
				third.upgrade();
				NetPump.until(() -> {
					third.poll();
					return third.head() != null && third.ended;
				}, 5.0, function(_) {
					Assert.isTrue(third.head() != null && third.head().indexOf(" 503 ") > 0, "the third session was not answered 503: " + third.head());
					Assert.isTrue(third.ended, "the refused connection was left open");
					Assert.equals(2, server.clientCount);
					Assert.equals(2, asked, "upgrade was asked about a session that could not open");
					Assert.equals(1, server.refusedConnections);
					Assert.equals(0, server.handshakeFailures, "a refusal was counted as a failed handshake");

					// One goes, and the next is taken.
					first.close();
					var fourth = new WirePeer(server.localPort);
					NetPump.until(() -> server.clientCount < 2, 5.0, function(_) {
						fourth.upgrade();
						NetPump.until(() -> {
							fourth.poll();
							return fourth.head() != null;
						}, 5.0, function(_) {
							Assert.isTrue(fourth.head() != null && fourth.head().indexOf(" 101 ") > 0, "a place freed was not taken: " + fourth.head());
							second.close();
							third.close();
							fourth.close();
							done();
						});
					});
				});
			});
		});
	}

	/** An upgrade `upgrade` refuses gives back the place it was counted in. **/
	@:timeout(20000)
	public function testARefusedUpgradeGivesItsPlaceBack(async:Async):Void {
		var server = new ServerWebSocket();
		server.maxConnections = 1;
		var refuse:Bool = true;
		server.upgrade = function(request) {
			if (refuse) {
				refuse = false;
				request.status = 403;
				return false;
			}
			return true;
		};
		server.addEventListener(crossbyte.events.ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var refused = new WirePeer(server.localPort);
			refused.upgrade();
			NetPump.until(() -> {
				refused.poll();
				return refused.head() != null;
			}, 5.0, function(_) {
				Assert.isTrue(refused.head() != null && refused.head().indexOf(" 403 ") > 0, "the first was not refused: " + refused.head());
				var taken = new WirePeer(server.localPort);
				taken.upgrade();
				NetPump.until(() -> {
					taken.poll();
					return taken.head() != null;
				}, 5.0, function(_) {
					Assert.isTrue(taken.head() != null && taken.head().indexOf(" 101 ") > 0, "the place a refusal held was not given back: " + taken.head());
					Assert.equals(0, server.refusedConnections);
					refused.close();
					taken.close();
					server.close();
					async.done();
				});
			});
		});
	}
	#end

	// ---- maxMessageSize: each server's, and each session's ----------------

	/**
		A message of 100 KB in one frame, as a browser sends one, is taken.
		Every frame was held to 64 KiB, so it was refused with 1009 however
		large a message might be.
	**/
	#if !eval
	@:timeout(20000)
	public function testAMessageOfOneHundredKilobytesInOneFrameIsTaken(async:Async):Void {
		var got:Int = -1;
		var code:Int = -1;
		__openSession(async, null, function(server, session, peer, done) {
			session.addEventListener(crossbyte.events.WebSocketMessageEvent.MESSAGE, (e:crossbyte.events.WebSocketMessageEvent) -> got = e.data.length);
			session.addEventListener(crossbyte.events.Event.CLOSE, function(e:crossbyte.events.Event) {
				var close = Std.downcast(e, crossbyte.events.WebSocketCloseEvent);
				code = close == null ? 0 : close.code;
			});
			peer.sendFrame(WirePeer.BINARY, Bytes.alloc(100 * 1024));
			NetPump.until(() -> got >= 0 || code >= 0, 10.0, function(_) {
				Assert.equals(100 * 1024, got, 'a 100 KB frame was not taken (closed with $code)');
				done();
			});
		});
	}
	#end

	#if !ws_before
	/**
		Each server holds its sessions to its own `maxMessageSize`: one set
		lower in the same process refuses what another takes. It was one
		limit for the whole process.
	**/
	@:timeout(20000)
	public function testEachServerHasItsOwnMessageLimit(async:Async):Void {
		var other = new ServerWebSocket();
		other.maxMessageSize = 1000;
		Assert.equals(1024 * 1024, new ServerWebSocket().maxMessageSize, "one server's limit changed another's");

		var got:Int = -1;
		var code:Int = -1;
		__openSession(async, server -> server.maxMessageSize = 1000, function(server, session, peer, done) {
			Assert.equals(1000, session.maxMessageSize, "the session did not take its server's limit");
			session.addEventListener(crossbyte.events.WebSocketMessageEvent.MESSAGE, (e:crossbyte.events.WebSocketMessageEvent) -> got = e.data.length);
			session.addEventListener(crossbyte.events.Event.CLOSE, function(e:crossbyte.events.Event) {
				var close = Std.downcast(e, crossbyte.events.WebSocketCloseEvent);
				code = close == null ? 0 : close.code;
			});
			peer.sendFrame(WirePeer.BINARY, Bytes.alloc(1000));
			NetPump.until(() -> got >= 0, 5.0, function(_) {
				Assert.equals(1000, got, "a message at the limit was not taken");
				// Two frames of 600: the second takes the message past the limit.
				peer.sendFrame(WirePeer.BINARY, Bytes.alloc(600), false, false);
				peer.sendFrame(0x0, Bytes.alloc(600));
				NetPump.until(() -> code >= 0, 5.0, function(_) {
					Assert.equals(1009, code, "a message past its server's limit was not refused as too big");
					done();
				});
			});
		});
	}

	/** `closeTimeout` must be a number of seconds above 0. **/
	public function testACloseTimeoutThatIsNoTimeIsRefused():Void {
		var socket = new WebSocket();
		Assert.raises(() -> socket.closeTimeout = 0, crossbyte.errors.ArgumentError);
		Assert.raises(() -> socket.closeTimeout = Math.NaN, crossbyte.errors.ArgumentError);
		socket.closeTimeout = 0.25;
		Assert.equals(0.25, socket.closeTimeout);
	}
	#end

	// ------------------------------------------------------------- helpers

	private static function __pending(server:ServerWebSocket):Int {
		return @:privateAccess server.__pendingUpgrades.length;
	}

	#if !ws_before
	private static function __counted(server:ServerWebSocket):Int {
		return @:privateAccess server.__addressCounts.count("127.0.0.1");
	}
	#end

	private static function __ended(peers:Array<WirePeer>):Int {
		var count:Int = 0;
		for (peer in peers) {
			peer.poll();
			if (peer.ended) {
				count++;
			}
		}
		return count;
	}

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
