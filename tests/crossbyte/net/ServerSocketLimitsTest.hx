package crossbyte.net;

#if !(js && !nodejs)
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
#end
import utest.Assert;
import utest.Async;

/**
	What a raw `ServerSocket`, and a `NetHost` built on one, holds at most:
	`maxConnections` connections open, and of a TLS server's handshakes,
	`maxPendingHandshakesPerAddress` from one address once half the places
	are taken. Without these a game server built on a raw listener would
	accept without bound, and one address opening TLS connections and
	saying nothing could hold every place for handshakes, with every real
	client waiting behind it.
**/
@:access(crossbyte.net.ServerSocket)
class ServerSocketLimitsTest extends utest.Test {
	#if !(js && !nodejs)
	public function testTheDefaultsAreTenThousandAndSixteenAnAddress():Void {
		var server = new ServerSocket();
		Assert.equals(10000, ServerSocket.DEFAULT_MAX_CONNECTIONS);
		Assert.equals(16, ServerSocket.DEFAULT_MAX_PENDING_HANDSHAKES_PER_ADDRESS);
		Assert.equals(10000, server.maxConnections);
		Assert.equals(16, server.maxPendingHandshakesPerAddress);
		Assert.equals(0, server.refusedConnections);
		// The WebSocket server shares them.
		Assert.equals(ServerSocket.DEFAULT_MAX_CONNECTIONS, ServerWebSocket.DEFAULT_MAX_CONNECTIONS);
		Assert.equals(10000, new ServerWebSocket().maxConnections);
	}

	/**
		With `maxConnections` open, a connection is closed as it is accepted,
		never announced, and counted; its peer sees its connection accepted
		and closed. Once one closes, the next is taken.
	**/
	@:timeout(20000)
	public function testPastItsLimitARawServerClosesAConnectionAsItIsAccepted(async:Async):Void {
		var server = new ServerSocket();
		server.maxConnections = 2;
		var announced:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> announced.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [];
			// One at a time, so which is refused is the one past the limit.
			NetPump.until(() -> {
				if (peers.length < 3 && announced.length + server.refusedConnections >= peers.length) {
					peers.push(new WirePeer(server.localPort));
				}
				return peers.length >= 3 && announced.length + server.refusedConnections >= 3;
			}, 10.0, function(_) {
				NetPump.until(() -> __ended(peers) >= 1, 5.0, function(_) {
					Assert.equals(2, announced.length, "a raw server announced past its limit");
					Assert.equals(1, server.refusedConnections, "the connection past the limit was not counted");
					Assert.isTrue(peers[2].ended, "the connection past the limit was not closed");
					Assert.isFalse(peers[0].ended || peers[1].ended, "a connection within the limit was closed");
					// A place given back is taken by the next.
					announced[0].close();
					peers.push(new WirePeer(server.localPort));
					NetPump.until(() -> announced.length >= 3, 5.0, function(_) {
						Assert.equals(3, announced.length, "the place a closed connection gave back was not taken");
						Assert.equals(1, server.refusedConnections);
						__finish(server, announced, peers, async);
					});
				});
			});
		});
	}

	/**
		A connection's place is given back however it ends: its peer
		closing, its server closing it, or the peer resetting it.
	**/
	@:timeout(20000)
	public function testAPlaceIsGivenBackWhicheverEndCloses(async:Async):Void {
		var server = new ServerSocket();
		server.maxConnections = 1;
		var announced:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> announced.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [new WirePeer(server.localPort)];
			NetPump.until(() -> announced.length >= 1, 5.0, function(_) {
				// The peer hangs up: the server reads its end, and lets go.
				peers[0].close();
				NetPump.until(() -> server.__openCount == 0, 5.0, function(_) {
					Assert.equals(0, server.__openCount, "a connection its peer closed kept its place");
					peers.push(new WirePeer(server.localPort));
					NetPump.until(() -> announced.length >= 2, 5.0, function(_) {
						Assert.equals(2, announced.length, "the next connection was not taken");
						// The server closes it.
						announced[1].close();
						Assert.equals(0, server.__openCount, "a connection the server closed kept its place");
						peers.push(new WirePeer(server.localPort));
						NetPump.until(() -> announced.length >= 3, 5.0, function(_) {
							Assert.equals(3, announced.length);
							Assert.equals(0, server.refusedConnections, "a connection was refused with a place free");
							__finish(server, announced, peers, async);
						});
					});
				});
			});
		});
	}

	/** `0` keeps no count. **/
	@:timeout(20000)
	public function testNoLimitTakesEveryConnection(async:Async):Void {
		var server = new ServerSocket();
		server.maxConnections = 0;
		var announced:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> announced.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [for (_ in 0...5) new WirePeer(server.localPort)];
			NetPump.until(() -> announced.length >= 5, 5.0, function(_) {
				Assert.equals(5, announced.length);
				Assert.equals(0, server.refusedConnections);
				__finish(server, announced, peers, async);
			});
		});
	}

	/**
		A host's `maxConnections` is its server's: it serves no more, and
		says how many it refused, rather than taking it as the backlog it asks
		for, which limits nothing it serves.
	**/
	@:timeout(20000)
	public function testANetHostServesNoMoreThanItsMaxConnections(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Int = 0;
		var host:NetHost = NetHost.fromServerSocket(server, _ -> accepted++);
		Assert.equals(10000, host.maxConnections);
		host.maxConnections = 1;
		Assert.equals(1, server.maxConnections, "a host's limit is not its server's");
		host.bind("127.0.0.1", 0);
		host.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [new WirePeer(server.localPort)];
			NetPump.until(() -> accepted >= 1, 5.0, function(_) {
				peers.push(new WirePeer(server.localPort));
				NetPump.until(() -> host.refusedConnections >= 1, 5.0, function(_) {
					Assert.equals(1, accepted, "a host served past its maxConnections");
					Assert.equals(1, host.refusedConnections);
					for (peer in peers) {
						peer.close();
					}
					try host.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	/**
		A reliable datagram host counts its sessions itself: one accepted at
		its `maxConnections` is closed before `onAccept`, and counted.
	**/
	@:timeout(20000)
	public function testAReliableDatagramHostClosesASessionPastItsLimit(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}
		var server = new ReliableDatagramServerSocket();
		var accepted:Int = 0;
		var host:NetHost = NetHost.fromReliableDatagramServerSocket(server, _ -> accepted++);
		Assert.equals(10000, host.maxConnections);
		host.maxConnections = 1;
		server.bind(0, "127.0.0.1");
		host.listen();
		var first = new ReliableDatagramSocket();
		var second = new ReliableDatagramSocket();
		var secondClosed:Bool = false;
		second.addEventListener(Event.CLOSE, _ -> secondClosed = true);
		// Node binds a turn later.
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			first.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> accepted >= 1, 5.0, function(_) {
				second.connect("127.0.0.1", server.localPort);
				NetPump.until(() -> host.refusedConnections >= 1 && secondClosed, 5.0, function(_) {
					Assert.equals(1, accepted, "a reliable datagram host served past its maxConnections");
					Assert.equals(1, host.refusedConnections);
					Assert.isTrue(secondClosed, "the session past the limit was not closed");
					try first.close() catch (_:Dynamic) {}
					try second.close() catch (_:Dynamic) {}
					try host.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	/**
		An `HTTPServer`'s `maxConnections` is the one its configuration gave,
		and what it refuses is counted with the rest.
	**/
	@:timeout(20000)
	public function testAnHttpServerHoldsToTheLimitItsConfigurationGave(async:Async):Void {
		var config = new crossbyte.http.HTTPServerConfig("127.0.0.1", 0);
		config.maxConnections = 1;
		var server = new crossbyte.http.HTTPServer(config);
		Assert.equals(1, server.maxConnections, "the configuration's limit is not the server's");
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var first = new WirePeer(server.localPort);
			first.send(haxe.io.Bytes.ofString("GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n"));
			NetPump.until(() -> {
				first.poll();
				return first.received.length > 0;
			}, 5.0, function(_) {
				var second = new WirePeer(server.localPort);
				second.send(haxe.io.Bytes.ofString("GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n"));
				NetPump.until(() -> server.refusedConnections >= 1, 5.0, function(_) {
					Assert.equals(1, server.refusedConnections, "an HTTP server's refusal at its limit was not counted");
					first.close();
					second.close();
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	#if (cpp || java || jvm)
	/**
		One address opening TLS connections and saying nothing takes half the
		handshake places and no more: past that, each of its connections is
		closed as it is accepted, before any TLS work, and the rest are there
		for every other address. Its count goes as its handshakes end.
	**/
	@:timeout(20000)
	public function testATlsServerHoldsOneAddressToItsShareOfTheHandshakes(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TLS case did not run");
			async.done();
			return;
		}
		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.maxPendingHandshakes = 8;
		server.maxPendingHandshakesPerAddress = 2;
		server.handshakeTimeout = 30;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
		server.bind(0, "127.0.0.1");
		server.listen();
		var peers:Array<WirePeer> = [];
		var opened:Int = 0;
		NetPump.until(() -> {
			if (opened < 10 && (peers.length == 0 || server.pendingHandshakeCount() + __ended(peers) >= opened)) {
				peers.push(new WirePeer(server.localPort));
				opened++;
			}
			return opened >= 10 && server.pendingHandshakeCount() + __ended(peers) >= 10;
		}, 10.0, function(_) {
			Assert.equals(4, server.pendingHandshakeCount(), "one address held other than half the places");
			Assert.equals(6, __ended(peers), "its connections past half the places were not closed");
			Assert.equals(6, server.refusedConnections);
			Assert.equals(0, server.handshakeFailures, "a refusal was counted as a failed handshake");
			Assert.equals(4, server.__addressCounts.count("127.0.0.1"));
			// Another address is taken while this one is held to its share.
			Assert.isTrue(server.__claimPendingAddress("192.0.2.7"), "another address was refused");
			Assert.isFalse(server.__claimPendingAddress("127.0.0.1"), "the crowding address was taken again");
			server.__addressCounts.release("192.0.2.7");
			// Stopping drops the handshakes, and with them the address.
			server.stopAccepting();
			Assert.equals(0, server.__addressCounts.count("127.0.0.1"), "an address stayed counted once its handshakes were dropped");
			for (peer in peers) {
				peer.close();
			}
			server.close();
			async.done();
		});
	}

	/**
		A TLS server's connections are counted once their handshake is done;
		with `maxConnections` open, one more is closed as it is accepted,
		before a handshake is spent on it.
	**/
	@:timeout(20000)
	public function testATlsServerAtItsLimitSpendsNoHandshake(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TLS case did not run");
			async.done();
			return;
		}
		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.maxConnections = 1;
		var announced:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> announced.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		var first = new Socket();
		first.secure = true;
		first.certAuthority = fixture.certificate;
		first.connect("127.0.0.1", server.localPort);
		NetPump.until(() -> announced.length >= 1, 10.0, function(_) {
			Assert.equals(1, announced.length, "the first secure client was not announced");
			var second = new Socket();
			second.secure = true;
			second.certAuthority = fixture.certificate;
			var failed:Bool = false;
			second.addEventListener(IOErrorEvent.IO_ERROR, _ -> failed = true);
			second.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> failed, 10.0, function(_) {
				Assert.isTrue(failed, "a secure client past the limit was not refused");
				Assert.equals(1, server.refusedConnections);
				Assert.equals(0, server.handshakeFailures, "the refusal was counted as a failed handshake");
				Assert.equals(1, announced.length);
				try first.close() catch (_:Dynamic) {}
				try second.close() catch (_:Dynamic) {}
				__finish(server, announced, [], async);
			});
		});
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

	private static function __finish(server:ServerSocket, announced:Array<Socket>, peers:Array<WirePeer>, async:Async):Void {
		for (socket in announced) {
			try {
				if (socket.connected) {
					socket.close();
				}
			} catch (_:Dynamic) {}
		}
		for (peer in peers) {
			peer.close();
		}
		try server.close() catch (_:Dynamic) {}
		async.done();
	}
	#end
}
