package crossbyte.net;

import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import utest.Assert;
import utest.Async;

/**
	A `NetConnection` tells its callbacks one story whatever its transport:
	`onError` for what went wrong, then `onClose` exactly once, with the
	reason the connection ended, and `Reason.Timeout` for a deadline.

	So code cleaning up in `onClose` runs on every transport: a TCP connect
	that fails ends with `onError` and `onClose`, as over a WebSocket. Closed
	by this side, a connection tells `onClose` once, however many times
	`close()` is called and whether or not its peer closed first; closing a
	WebSocket connection its peer has closed does not throw. And a connect
	that times out is `Reason.Timeout`, not `Reason.Error` with the time in
	its text.
**/
class NetConnectionLifecycleTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(20000)
	public function testAFailedTcpConnectEndsWithOnErrorThenOnClose(async:Async):Void {
		__vacantPort(function(port) {
			var told:Array<String> = [];
			var reasons:Array<Reason> = [];
			var connection = new NetConnection('tcp://127.0.0.1:$port', null, () -> told.push("ready"), reason -> {
				told.push("close");
				reasons.push(reason);
			}, reason -> {
				told.push("error");
				reasons.push(reason);
			});

			NetPump.until(() -> told.indexOf("close") >= 0, 10.0, function(_) {
				// Long enough for anything told late to arrive.
				NetPump.wait(0.3, function() {
					Assert.same(["error", "close"], told, "a refused connect did not end with onError and then onClose");
					Assert.isTrue(reasons.length == 2 && Type.enumEq(reasons[0], reasons[1]), "onClose was not told the error that ended it: " + reasons);
					try connection.close() catch (e:Dynamic) Assert.fail("closing a failed connection threw: " + e);
					Assert.equals(2, told.length, "closing a failed connection told it again: " + told);
					async.done();
				});
			});
		});
	}

	@:timeout(20000)
	public function testATcpConnectionIsToldOfItsEndOnce(async:Async):Void {
		var server = new ServerSocket();
		var accepted:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			// Closed by this side, twice.
			var closes:Array<Reason> = [];
			var ready:Bool = false;
			var mine = new NetConnection('tcp://127.0.0.1:${server.localPort}', null, () -> ready = true, reason -> closes.push(reason));
			// And by the peer, then by this side.
			var peerCloses:Array<Reason> = [];
			var peerReady:Bool = false;
			var theirs = new NetConnection('tcp://127.0.0.1:${server.localPort}', null, () -> peerReady = true, reason -> peerCloses.push(reason));

			NetPump.until(() -> ready && peerReady && accepted.length == 2, 5.0, function(_) {
				mine.close();
				mine.close();
				for (socket in accepted) {
					if (socket.remotePort == theirs.localPort) {
						socket.close();
					}
				}

				NetPump.until(() -> peerCloses.length > 0, 5.0, function(_) {
					try theirs.close() catch (e:Dynamic) Assert.fail("closing a connection its peer had closed threw: " + e);
					NetPump.wait(0.3, function() {
						Assert.equals(1, closes.length, "a connection closed twice was told so " + closes.length + " times");
						Assert.isTrue(closes.length > 0 && Type.enumEq(Reason.Closed, closes[0]), "it was told " + closes);
						Assert.equals(1, peerCloses.length, "a connection its peer closed, then closed here, was told so " + peerCloses.length + " times");
						for (socket in accepted) {
							try socket.close() catch (_:Dynamic) {}
						}
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}

	/**
		A connect not made within its socket's `timeout` is `Reason.Timeout`,
		to `onError` and then `onClose`. The peer accepts and never answers
		the TLS handshake, which the deadline counts with the connect.
	**/
	#if !eval
	@:timeout(20000)
	public function testAConnectThatTimesOutIsATimeout(async:Async):Void {
		var server = new ServerSocket();
		var silent:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) silent.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var socket = new Socket();
			socket.secure = true;
			socket.verifyCert = false;
			socket.timeout = 400;
			var errors:Array<Reason> = [];
			var closes:Array<Reason> = [];
			var connection = NetConnection.fromSocket(socket);
			connection.onError = reason -> errors.push(reason);
			connection.onClose = reason -> closes.push(reason);
			socket.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> closes.length > 0, 10.0, function(_) {
				Assert.isTrue(errors.length == 1 && Type.enumEq(Reason.Timeout, errors[0]), "onError was not told of the timeout: " + errors);
				Assert.isTrue(closes.length == 1 && Type.enumEq(Reason.Timeout, closes[0]), "onClose was not told of the timeout: " + closes);
				for (peer in silent) {
					try peer.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A reliable session's connect not made within its `timeout` is
		`Reason.Timeout` too. The peer is a datagram socket that takes every
		CONNECT and answers none. The session's timeout errors carry
		`TIMEOUT_ERROR_ID`, or this would end as `Reason.Error` with the time in
		its text.
	**/
	@:timeout(20000)
	public function testAReliableConnectThatTimesOutIsATimeout(async:Async):Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			async.done();
			return;
		}

		var silent = new DatagramSocket();
		silent.bind(0, "127.0.0.1");

		// Node binds asynchronously.
		NetPump.until(() -> silent.localPort != 0, 5.0, function(_) {
			var socket = new ReliableDatagramSocket();
			socket.timeout = 400;
			var errors:Array<Reason> = [];
			var closes:Array<Reason> = [];
			var connection = NetConnection.fromReliableDatagramSocket(socket);
			connection.onError = reason -> errors.push(reason);
			connection.onClose = reason -> closes.push(reason);
			socket.connect("127.0.0.1", silent.localPort);

			NetPump.until(() -> closes.length > 0, 10.0, function(_) {
				Assert.isTrue(errors.length == 1 && Type.enumEq(Reason.Timeout, errors[0]), "onError was not told of the timeout: " + errors);
				Assert.isTrue(closes.length == 1 && Type.enumEq(Reason.Timeout, closes[0]), "onClose was not told of the timeout: " + closes);
				try silent.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A WebSocket connect not open within its `timeout` is `Reason.Timeout`
		too. The server takes the TCP connection and never answers the
		upgrade. The session's deadline errors carry `TIMEOUT_ERROR_ID`, or this
		would end as `Reason.Error` with the time in its text.
	**/
	@:timeout(20000)
	public function testAWebSocketConnectThatTimesOutIsATimeout(async:Async):Void {
		var server = new ServerSocket();
		var silent:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) silent.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var socket = new WebSocket();
			socket.timeout = 400;
			var errors:Array<Reason> = [];
			var closes:Array<Reason> = [];
			var connection = NetConnection.fromWebSocket(socket);
			connection.onError = reason -> errors.push(reason);
			connection.onClose = reason -> closes.push(reason);
			socket.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> closes.length > 0, 10.0, function(_) {
				Assert.isTrue(errors.length == 1 && Type.enumEq(Reason.Timeout, errors[0]), "onError was not told of the timeout: " + errors);
				Assert.isTrue(closes.length == 1 && Type.enumEq(Reason.Timeout, closes[0]), "onClose was not told of the timeout: " + closes);
				for (peer in silent) {
					try peer.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	/**
		A connection closed for a reason (an RPC session's heartbeat that
		heard nothing closes its connection as `Reason.Timeout`) tells
		`onClose` that reason, and a `NetHost` tells `onDisconnect`.
	**/
	@:timeout(20000)
	public function testAConnectionClosedForATimeoutTellsItsHost(async:Async):Void {
		var server = new ServerSocket();
		var accepted:INetConnection = null;
		var disconnected:Array<Reason> = [];
		var host = NetHost.fromServerSocket(server, connection -> accepted = connection, (_, reason) -> disconnected.push(reason));
		server.bind(0, "127.0.0.1");
		host.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new NetConnection('tcp://127.0.0.1:${server.localPort}');

			NetPump.until(() -> accepted != null, 5.0, function(_) {
				(cast accepted : NetConnectionBase).__closeWith(Reason.Timeout);

				NetPump.wait(0.2, function() {
					Assert.equals(1, disconnected.length, "the host was not told once: " + disconnected);
					Assert.isTrue(disconnected.length > 0 && Type.enumEq(Reason.Timeout, disconnected[0]), "the host was told " + disconnected);
					try client.close() catch (_:Dynamic) {}
					try host.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end

	#if (cpp || java || jvm || nodejs)
	@:timeout(20000)
	public function testAFailedWebSocketConnectEndsAsATcpOneDoes(async:Async):Void {
		__vacantPort(function(port) {
			var told:Array<String> = [];
			var reasons:Array<Reason> = [];
			var connection = new NetConnection('ws://127.0.0.1:$port/', null, () -> told.push("ready"), reason -> {
				told.push("close");
				reasons.push(reason);
			}, reason -> {
				told.push("error");
				reasons.push(reason);
			});

			NetPump.until(() -> told.indexOf("close") >= 0, 10.0, function(_) {
				NetPump.wait(0.3, function() {
					Assert.same(["error", "close"], told, "a refused WebSocket connect did not end with onError and then onClose");
					Assert.isTrue(reasons.length == 2 && Type.enumEq(reasons[0], reasons[1]), "onClose was not told the error that ended it: " + reasons);
					async.done();
				});
			});
		});
	}

	@:timeout(20000)
	public function testClosingAWebSocketConnectionItsPeerClosedDoesNotThrow(async:Async):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var closes:Array<Reason> = [];
			var ready:Bool = false;
			var connection = new NetConnection('ws://127.0.0.1:${server.localPort}/', null, () -> ready = true, reason -> closes.push(reason));

			NetPump.until(() -> ready && sessions.length > 0, 5.0, function(_) {
				sessions[0].close();

				NetPump.until(() -> closes.length > 0, 5.0, function(_) {
					try {
						connection.close();
					} catch (e:Dynamic) {
						Assert.fail("closing a WebSocket connection its peer had closed threw: " + e);
					}
					NetPump.wait(0.2, function() {
						Assert.equals(1, closes.length, "the connection was told of its end " + closes.length + " times");
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}
	#end

	#if (cpp || java || jvm || eval || nodejs)
	/**
		Inside `onClose` a connection is no longer `connected`, on each
		transport and at both ends, whether it closed itself or its peer
		closed it. A connection closing itself told `onClose` before its
		socket had closed, so it still said it was connected.
	**/
	@:timeout(40000)
	public function testAConnectionIsNotConnectedInsideItsOnClose(async:Async):Void {
		final schemes:Array<String> = ["tcp"];
		#if (cpp || java || jvm || nodejs)
		schemes.push("ws");
		#end
		if (ReliableDatagramSocket.isSupported) {
			schemes.push("rudp");
		}
		final wrong:Array<String> = [];
		var next:Int->Void = null;
		next = function(at:Int):Void {
			if (at == schemes.length) {
				Assert.same([], wrong, "connections still said they were connected inside onClose: " + wrong.join("; "));
				async.done();
				return;
			}
			__closeEachWay(schemes[at], wrong, () -> next(at + 1));
		};
		next(0);
	}

	/**
		Over `scheme`, two connections to a host: the first closed by itself,
		then everything the host accepted closed by the host, so each end sees
		a close of its own and one of its peer's. Whatever reads `connected`
		inside `onClose` goes into `wrong`.
	**/
	private static function __closeEachWay(scheme:String, wrong:Array<String>, then:Void->Void):Void {
		final accepted:Array<INetConnection> = [];
		final closes:Array<String> = [];
		final host = new NetHost('$scheme://127.0.0.1:0', connection -> {
			accepted.push(connection);
			final at:Int = accepted.length;
			connection.onClose = reason -> {
				closes.push('accepted $at');
				if (connection.connected) {
					wrong.push('$scheme: accepted connection $at, in onClose after $reason');
				}
			};
		}, null, null, true);
		NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
			final uri:String = '$scheme://127.0.0.1:${host.localPort}';
			var ready:Int = 0;
			var mine:NetConnection = null;
			var theirs:NetConnection = null;
			mine = new NetConnection(uri, null, () -> ready++, reason -> {
				closes.push("mine");
				if (mine.connected) {
					wrong.push('$scheme: a connection closed by itself, in onClose after $reason');
				}
			});
			theirs = new NetConnection(uri, null, () -> ready++, reason -> {
				closes.push("theirs");
				if (theirs.connected) {
					wrong.push('$scheme: a connection its peer closed, in onClose after $reason');
				}
			});
			NetPump.until(() -> ready == 2 && accepted.length == 2, 10.0, function(up:Bool) {
				if (!up) {
					wrong.push('$scheme: the connections did not come up');
					try host.close() catch (_:Dynamic) {}
					then();
					return;
				}
				mine.close();
				// Its peer, at the host, hears it close.
				NetPump.until(() -> closes.length >= 2, 10.0, function(_) {
					for (connection in accepted) {
						try connection.close() catch (_:Dynamic) {}
					}
					NetPump.until(() -> closes.length >= 4, 10.0, function(all:Bool) {
						if (!all) {
							wrong.push('$scheme: only ' + closes + ' closed');
						}
						try theirs.close() catch (_:Dynamic) {}
						try host.close() catch (_:Dynamic) {}
						then();
					});
				});
			});
		});
	}

	/** A port nothing listens on, obtained rather than assumed: a listener's, once it is closed. **/
	private static function __vacantPort(then:Int->Void):Void {
		var vacant = new ServerSocket();
		vacant.bind(0, "127.0.0.1");
		vacant.listen(1);
		NetPump.until(() -> vacant.localPort != 0, 5.0, function(_) {
			var port:Int = vacant.localPort;
			try vacant.close() catch (_:Dynamic) {}
			NetPump.wait(0.1, () -> then(port));
		});
	}
	#end
}
