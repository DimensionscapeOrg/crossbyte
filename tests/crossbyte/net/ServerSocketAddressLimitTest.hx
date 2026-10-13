package crossbyte.net;

#if !(js && !nodejs)
import crossbyte.events.ServerSocketConnectEvent;
#end
import utest.Assert;
import utest.Async;

/**
	`maxConnectionsPerAddress`: how many connections one address may hold
	open, on a raw `ServerSocket`, a TLS one, a `ServerWebSocket` and an
	`HTTPServer`. Past it a connection is closed as it is accepted, before
	any TLS work, and counted in `refusedConnections`; its place comes back
	as it closes. Addresses are counted as `RateLimiter.addressKey` keys
	them, an IPv6 client by its /64.
**/
@:access(crossbyte.net.ServerSocket)
class ServerSocketAddressLimitTest extends utest.Test {
	#if !(js && !nodejs)
	public function testThereIsNoLimitUnlessOneIsSet():Void {
		Assert.equals(0, new ServerSocket().maxConnectionsPerAddress);
		Assert.equals(0, new ServerWebSocket().maxConnectionsPerAddress);
	}

	/** Keyed as `RateLimiter.addressKey` keys: two addresses in one /64 are one, a mapped IPv4 address is the IPv4 one. **/
	public function testAnIpv6ClientIsCountedByItsSlash64():Void {
		var server = new ServerSocket();
		server.maxConnectionsPerAddress = 1;
		Assert.isFalse(server.__overAddressLimit("2001:db8:1:2::1"));
		var first = server.__takeHeldAddress();
		Assert.notNull(first, "a connection under a limit carried no hold");
		Assert.isTrue(server.__overAddressLimit("2001:db8:1:2:aaaa::7"), "another address in the same /64 was not counted with the first");
		Assert.isFalse(server.__overAddressLimit("2001:db8:1:3::1"), "an address in another /64 was counted with the first");
		var other = server.__takeHeldAddress();
		Assert.isFalse(server.__overAddressLimit("192.0.2.9"));
		var v4 = server.__takeHeldAddress();
		Assert.isTrue(server.__overAddressLimit("::ffff:192.0.2.9"), "a mapped IPv4 address was not counted as the address it maps");
		first.release();
		first.release();
		Assert.equals(0, server.__connectionCounts.count(RateLimiter.addressKey("2001:db8:1:2::1")), "a hold let go of twice took two");
		Assert.isFalse(server.__overAddressLimit("2001:db8:1:2::1"), "a place given back was not taken again");
		server.__takeHeldAddress().release();
		other.release();
		v4.release();
		// With no limit nothing is counted, and nothing is carried.
		server.maxConnectionsPerAddress = 0;
		Assert.isFalse(server.__overAddressLimit("192.0.2.9"));
		Assert.isNull(server.__takeHeldAddress());
	}

	/**
		With two open from 127.0.0.1, the third is closed as it is accepted,
		never announced, and counted; once one closes, the next is taken.
	**/
	@:timeout(20000)
	public function testARawServerClosesAConnectionPastItsAddressesLimit(async:Async):Void {
		var server = new ServerSocket();
		server.maxConnectionsPerAddress = 2;
		var announced:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> announced.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peers:Array<WirePeer> = [];
			NetPump.until(() -> {
				if (peers.length < 3 && announced.length + server.refusedConnections >= peers.length) {
					peers.push(new WirePeer(server.localPort));
				}
				return peers.length >= 3 && announced.length + server.refusedConnections >= 3;
			}, 10.0, function(_) {
				NetPump.until(() -> __ended(peers) >= 1, 5.0, function(_) {
					Assert.equals(2, announced.length, "a server announced past its address's limit");
					Assert.equals(1, server.refusedConnections, "the connection past the limit was not counted");
					Assert.isTrue(peers[2].ended, "the connection past the limit was not closed");
					Assert.isFalse(peers[0].ended || peers[1].ended, "a connection within the limit was closed");
					Assert.equals(2, server.__connectionCounts.count("127.0.0.1"));
					// The server closes one, and its place is taken by the next.
					announced[0].close();
					Assert.equals(1, server.__connectionCounts.count("127.0.0.1"), "a connection the server closed kept its place");
					peers.push(new WirePeer(server.localPort));
					NetPump.until(() -> announced.length >= 3, 5.0, function(_) {
						Assert.equals(3, announced.length, "the place a closed connection gave back was not taken");
						// The peer hangs up: the server reads its end, and lets go.
						peers[1].close();
						NetPump.until(() -> server.__connectionCounts.count("127.0.0.1") <= 1, 5.0, function(_) {
							Assert.equals(1, server.__connectionCounts.count("127.0.0.1"), "a connection its peer closed kept its place");
							Assert.equals(1, server.refusedConnections);
							__finish(server, announced, peers, async);
						});
					});
				});
			});
		});
	}

	#if (cpp || java || jvm || nodejs)
	/**
		A TLS server holds a connection's place from accept, through its
		handshake: one address with its one place taken by a client that has
		said nothing is refused before any TLS work, and the place comes back
		as that handshake is given up on.
	**/
	@:timeout(20000)
	public function testATlsServerCountsAConnectionFromAcceptAndRefusesBeforeItsHandshake(async:Async):Void {
		var fixture = TLSTestFixture.trusted();
		if (fixture == null) {
			Assert.warn("no certificate toolchain on this machine; the TLS case did not run");
			async.done();
			return;
		}
		var server = new ServerSocket(true);
		server.setCertificate(fixture.certificate, fixture.key);
		server.maxConnectionsPerAddress = 1;
		server.handshakeTimeout = 1.5;
		var announced:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> announced.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// Says nothing: its handshake holds the address's one place.
			var silent = new WirePeer(server.localPort);
			NetPump.until(() -> server.__connectionCounts.count("127.0.0.1") >= 1, 5.0, function(_) {
				var second = new WirePeer(server.localPort);
				NetPump.until(() -> server.refusedConnections >= 1 && __ended([second]) >= 1, 5.0, function(_) {
					Assert.equals(1, server.refusedConnections, "a connection past its address's limit was not refused");
					Assert.isTrue(second.ended, "the connection past the limit was not closed");
					Assert.equals(0, server.handshakeFailures, "the refusal was counted as a failed handshake");
					// The silent one's handshake is given up on, and its place with it.
					NetPump.until(() -> server.__connectionCounts.count("127.0.0.1") == 0, 10.0, function(_) {
						Assert.equals(0, server.__connectionCounts.count("127.0.0.1"), "a handshake given up on kept its place");
						// A real client is now taken, and holds the place while open.
						var client = new Socket();
						client.secure = true;
						client.certAuthority = fixture.certificate;
						client.connect("127.0.0.1", server.localPort);
						NetPump.until(() -> announced.length >= 1, 10.0, function(_) {
							Assert.equals(1, announced.length, "a client with its address's place free was not announced");
							Assert.equals(1, server.__connectionCounts.count("127.0.0.1"), "an open TLS connection held no place");
							client.close();
							NetPump.until(() -> server.__connectionCounts.count("127.0.0.1") == 0, 5.0, function(_) {
								Assert.equals(0, server.__connectionCounts.count("127.0.0.1"), "a closed TLS connection kept its place");
								silent.close();
								second.close();
								__finish(server, announced, [], async);
							});
						});
					});
				});
			});
		});
	}
	#end

	/**
		A `ServerWebSocket` counts a session from accept to close, upgrading
		or open; past its address's limit a connection is closed as it is
		accepted, before its upgrade is read.
	**/
	@:timeout(20000)
	public function testAWebSocketServerCountsItsSessions(async:Async):Void {
		var server = new ServerWebSocket();
		server.maxConnectionsPerAddress = 1;
		var opened:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> opened.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var first = new WirePeer(server.localPort);
			first.upgrade();
			NetPump.until(() -> opened.length >= 1, 5.0, function(_) {
				Assert.equals(1, server.__connectionCounts.count("127.0.0.1"), "an open session held no place");
				var second = new WirePeer(server.localPort);
				second.upgrade();
				NetPump.until(() -> __ended([second]) >= 1, 5.0, function(_) {
					Assert.isTrue(second.ended, "a session past its address's limit was not closed");
					Assert.equals(1, server.refusedConnections);
					Assert.equals(1, opened.length, "a session past its address's limit opened");
					// The session ends, and the next is taken.
					opened[0].close();
					NetPump.until(() -> server.__connectionCounts.count("127.0.0.1") == 0, 5.0, function(_) {
						Assert.equals(0, server.__connectionCounts.count("127.0.0.1"), "a closed session kept its place");
						var third = new WirePeer(server.localPort);
						third.upgrade();
						NetPump.until(() -> opened.length >= 2, 5.0, function(_) {
							Assert.equals(2, opened.length, "the place a closed session gave back was not taken");
							for (session in opened) {
								try session.close() catch (_:Dynamic) {}
							}
							first.close();
							second.close();
							third.close();
							try server.close() catch (_:Dynamic) {}
							async.done();
						});
					});
				});
			});
		});
	}

	/** An `HTTPServer` holds it too, counting its connections. **/
	@:timeout(20000)
	public function testAnHttpServerHoldsAnAddressToItsLimit(async:Async):Void {
		var config = new crossbyte.http.HTTPServerConfig("127.0.0.1", 0);
		var server = new crossbyte.http.HTTPServer(config);
		server.maxConnectionsPerAddress = 1;
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var first = new WirePeer(server.localPort);
			first.send(haxe.io.Bytes.ofString("GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n"));
			NetPump.until(() -> {
				first.poll();
				return first.received.length > 0;
			}, 5.0, function(_) {
				var second = new WirePeer(server.localPort);
				NetPump.until(() -> server.refusedConnections >= 1 && __ended([second]) >= 1, 5.0, function(_) {
					Assert.equals(1, server.refusedConnections, "an HTTP server took a connection past its address's limit");
					Assert.isTrue(second.ended);
					first.close();
					NetPump.until(() -> server.__connectionCounts.count("127.0.0.1") == 0, 5.0, function(_) {
						Assert.equals(0, server.__connectionCounts.count("127.0.0.1"), "a closed HTTP connection kept its place");
						second.close();
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}

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
