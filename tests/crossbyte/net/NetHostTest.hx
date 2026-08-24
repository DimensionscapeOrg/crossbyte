package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

@:access(crossbyte.net.ServerWebSocket)
class NetHostTest extends utest.Test {
	public function testFromServerSocketAcceptsAndForwardsDisconnect():Void {
		#if !cpp
		Assert.isTrue(true);
		return;
		#end

		var server = new ServerSocket();
		var host:NetHost = null;
		var client = new Socket();
		var accepted:INetConnection = null;
		var disconnectReason:Reason = null;

		try {
			server.bind(0, "127.0.0.1");
			host = NetHost.fromServerSocket(server, connection -> accepted = connection, (connection, reason) -> {
				if (accepted == connection) {
					disconnectReason = reason;
				}
			});
			host.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> accepted != null, 2.0);

			Assert.notNull(accepted);
			Assert.equals(Protocol.TCP, accepted.protocol);
			Assert.equals(server.localPort, host.localPort);

			client.close();
			pumpUntil(() -> disconnectReason != null, 2.0);

			Assert.equals(Reason.Closed, disconnectReason);
		} catch (e:Dynamic) {
			closeSocketQuietly(client);
			closeHostQuietly(host);
			throw e;
		}

		closeSocketQuietly(client);
		closeHostQuietly(host);
	}

	public function testListenIsIdempotentForSingleAcceptedClient():Void {
		var server = new ServerSocket();
		var host:NetHost = null;
		var client = new Socket();
		var accepts = 0;

		try {
			server.bind(0, "127.0.0.1");
			host = NetHost.fromServerSocket(server, _ -> accepts++);
			host.listen();
			host.listen();

			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> accepts > 0, 2.0);

			Assert.equals(1, accepts);
		} catch (e:Dynamic) {
			closeSocketQuietly(client);
			closeHostQuietly(host);
			throw e;
		}

		closeSocketQuietly(client);
		closeHostQuietly(host);
	}

	public function testFromServerWebSocketWrapsAcceptedWebSocket():Void {
		var server = new ServerWebSocket();
		var accepted:INetConnection = null;
		var host = NetHost.fromServerWebSocket(server, connection -> accepted = connection);
		var socket = new WebSocket();

		server.bind(0, "127.0.0.1");
		host.listen();
		server.dispatchEvent(new ServerSocketConnectEvent(ServerSocketConnectEvent.CONNECT, socket));

		Assert.notNull(accepted);
		Assert.equals(Protocol.WEBSOCKET, accepted.protocol);
		closeHostQuietly(host);
	}

	public function testFromReliableDatagramServerSocketWrapsAcceptedSocket():Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var client = new ReliableDatagramSocket();
		var accepted:INetConnection = null;
		var disconnectReason:Reason = null;
		var host = NetHost.fromReliableDatagramServerSocket(server, connection -> accepted = connection, (connection, reason) -> {
			if (accepted == connection) {
				disconnectReason = reason;
			}
		});

		try {
			server.bind(0, "127.0.0.1");
			host.listen();
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> accepted != null && accepted.connected, 2.0);

			Assert.notNull(accepted);
			Assert.equals(Protocol.RUDP, accepted.protocol);
			Assert.equals(server.localPort, host.localPort);

			client.close();
			pumpUntil(() -> disconnectReason != null, 2.0);

			Assert.equals(Reason.Closed, disconnectReason);
		} catch (e:Dynamic) {
			closeReliableSocketQuietly(client);
			closeHostQuietly(host);
			throw e;
		}

		closeReliableSocketQuietly(client);
		closeHostQuietly(host);
	}

	/**
		The candidate a peer on the same network can actually use.

		`discoverPublicAddress` describes the outside of the NAT, which is the
		wrong address for a peer sitting behind the same one -- reaching it
		would need the NAT to hairpin. This is the other answer, and on loopback
		it is one that holds on every machine.
	**/
	@:timeout(4000)
	public function testARunningHostSaysWhereAPeerWouldReachIt(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var host = NetHost.fromReliableDatagramServerSocket(server, _ -> {}, (_, _) -> {});

		try {
			server.bind(0, "127.0.0.1");
			host.listen();

			var port = host.localPort;

			host.localAddressFor("127.0.0.1").then(function(address) {
				Assert.equals("127.0.0.1", address);
				// No port comes back with it, and none needs to: nothing
				// translates a local address, so the one a peer dials is the
				// one the host is already listening on.
				Assert.isTrue(port > 0, "the host was listening without a port");
				closeHostQuietly(host);
				async.done();
			}, function(error) {
				Assert.fail("a running host could not say where it is reachable: " + error);
				closeHostQuietly(host);
				async.done();
			});
		} catch (e:Dynamic) {
			closeHostQuietly(host);
			Assert.fail(Std.string(e));
			async.done();
		}
	}

	/**
		Refused before there is a port to pair it with.

		An address on its own is not a candidate. Handing one back from a host
		that is not listening would produce half of something a peer cannot
		dial, which is worse than saying no.
	**/
	@:timeout(4000)
	public function testAHostThatIsNotRunningHasNothingToPairAnAddressWith(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}

		var server = new ReliableDatagramServerSocket();
		var host = NetHost.fromReliableDatagramServerSocket(server, _ -> {}, (_, _) -> {});

		// Never bound, never listening.
		host.localAddressFor("127.0.0.1").then(function(address) {
			Assert.fail("a host that is not running answered with " + address);
			closeHostQuietly(host);
			async.done();
		}, function(error) {
			Assert.notNull(error);
			closeHostQuietly(host);
			async.done();
		});
	}

	/**
		What a stream host can answer, and what it cannot.

		`discoverPublicAddress` refuses here on purpose: accepting and dialling
		are separate sockets on a stream transport, so there is no one endpoint
		whose outside appearance means anything. That objection does not reach
		this question. Which interface reaches a peer is a property of the
		machine and its routing table, not of how many sockets the host holds,
		so a host that refuses the first still answers the second.
	**/
	@:timeout(4000)
	public function testAStreamHostAnswersWhatItCannotDiscover(async:Async):Void {
		#if !cpp
		Assert.isTrue(true);
		async.done();
		return;
		#end

		var server = new ServerSocket();
		var host = NetHost.fromServerSocket(server, _ -> {}, (_, _) -> {});

		try {
			server.bind(0, "127.0.0.1");
			host.listen();

			Assert.isFalse(host.canDial, "a stream host should not claim it can dial from its listening endpoint");

			var refused = false;
			try {
				host.discoverPublicAddress("127.0.0.1");
			} catch (_:crossbyte.errors.IllegalOperationError) {
				refused = true;
			}
			Assert.isTrue(refused, "a stream host answered a question about an endpoint it has not got");

			host.localAddressFor("127.0.0.1").then(function(address) {
				Assert.equals("127.0.0.1", address);
				closeHostQuietly(host);
				async.done();
			}, function(error) {
				Assert.fail("a stream host could not say which interface reaches a peer: " + error);
				closeHostQuietly(host);
				async.done();
			});
		} catch (e:Dynamic) {
			closeHostQuietly(host);
			Assert.fail(Std.string(e));
			async.done();
		}
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;
		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	private static function closeSocketQuietly(socket:Socket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeHostQuietly(host:NetHost):Void {
		try {
			if (host != null) {
				host.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeReliableSocketQuietly(socket:ReliableDatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}
