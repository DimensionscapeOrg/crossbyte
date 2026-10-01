package crossbyte.net;

import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net._internal.reliable.ReliableDatagramProtocol;
import utest.Assert;
import utest.Async;

/**
	How a reliable datagram session begins again, stays up, and ends, when one
	side restarts, goes quiet or goes away.

	Before these, a peer that crashed and came back on the same address and
	port could not get back in -- its old session took every CONNECT it sent
	and was kept alive by them -- a session with nothing to say was closed as
	dead within 150 seconds, and neither a server closing nor a server that
	had restarted told its clients anything.
**/
@:access(crossbyte.net.ReliableDatagramSocket)
@:access(crossbyte.net.ReliableDatagramServerSocket)
class ReliableDatagramLifecycleTest extends utest.Test {
	@:timeout(40000)
	public function testARestartedPeerOnTheSameAddressAndPortIsLetBackIn(async:Async):Void {
		if (!__supported(async)) {
			return;
		}

		var server = __server();
		var accepted:Array<ReliableDatagramSocket> = [];
		var heard:Array<String> = [];
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent) {
			var session = e.socket;
			accepted.push(session);
			session.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent) heard.push(d.data.readUTFBytes(d.data.length)));
		});

		var first = new ReliableDatagramSocket();
		first.bind(0, "127.0.0.1");

		NetPump.until(() -> server.localPort > 0 && first.localPort > 0, 5.0, function(_) {
			var port:Int = first.localPort;
			first.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> first.connected && accepted.length == 1, 5.0, function(_) {
				var stale = accepted[0];
				var staleClosed:Bool = false;
				stale.addEventListener(Event.CLOSE, function(_) staleClosed = true);

				// The process dies: no FIN, nothing said.
				first.__dispose(false);

				var second = new ReliableDatagramSocket();
				second.timeout = 15000;
				second.bind(port, "127.0.0.1");
				var connected:Bool = false;
				var failure:String = null;
				second.addEventListener(Event.CONNECT, function(_) connected = true);
				second.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) failure = e.text);

				NetPump.until(() -> second.localPort > 0, 5.0, function(_) {
					var started:Float = haxe.Timer.stamp();
					second.connect("127.0.0.1", server.localPort);

					// The server hears the end of the handshake a leg after the
					// client does, so both are waited for.
					NetPump.until(() -> (connected && accepted.length >= 2) || failure != null, 14.0, function(_) {
						var took:Float = haxe.Timer.stamp() - started;
						Assert.isTrue(connected, 'the restarted peer could not get back in: ' + failure);
						// Its first CONNECT asks the old peer, its next, three
						// seconds on, finds no answer and takes the session over.
						Assert.isTrue(took < 8.0, 'getting back in took $took s');
						Assert.equals(2, accepted.length, "the server never accepted the restarted peer as a new session");
						Assert.isTrue(staleClosed, "the session left over from before the restart was never closed");

						// And it is a working session, not one started from the
						// old one's sequence.
						if (connected) {
							var message = new ByteArray();
							message.writeUTFBytes("after the restart");
							second.send(message);
						}

						NetPump.until(() -> heard.length > 0, 5.0, function(_) {
							Assert.same(["after the restart"], heard, "the new session did not carry a message");
							__close(second);
							__closeServer(server);
							async.done();
						});
					});
				});
			});
		});
	}

	@:timeout(20000)
	public function testAConnectInTheNameOfALivePeerCannotTakeItsSession(async:Async):Void {
		if (!__supported(async)) {
			return;
		}

		// UDP lets a sender claim any address. A CONNECT with a new id from a
		// connected client's address is answered by asking that client, and a
		// client still there keeps its session however many arrive.
		__connectedPair(function(server, client, accepted) {
			var forged:ByteArray = ReliableDatagramProtocol.encode(CONNECT, 0x5EEDED, null);
			function forge():Void {
				forged.position = 0;
				server.__onData(new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "127.0.0.1", client.localPort, "127.0.0.1",
					server.localPort, forged));
			}

			var closed:Bool = false;
			accepted.addEventListener(Event.CLOSE, function(_) closed = true);

			forge();
			// Past any window a challenge is given, then again: the second
			// CONNECT is the one that would replace a session nobody answered
			// for.
			NetPump.wait(3.0, function() {
				forge();
				NetPump.wait(0.5, function() {
					Assert.isFalse(closed, "a forged CONNECT closed a session whose peer was there to answer");
					Assert.isTrue(accepted.connected, "the session a live peer holds was not kept");
					Assert.isTrue(client.connected, "the live peer lost its session");
					__close(client);
					__closeServer(server);
					async.done();
				});
			});
		}, async);
	}

	@:timeout(20000)
	public function testAQuietSessionIsKeptUp(async:Async):Void {
		if (!__supported(async)) {
			return;
		}

		__connectedPair(function(server, client, accepted) {
			var closes:Int = 0;
			client.addEventListener(Event.CLOSE, function(_) closes++);
			accepted.addEventListener(Event.CLOSE, function(_) closes++);

			// Three idle timeouts of nothing to say.
			NetPump.wait(3.0, function() {
				Assert.equals(0, closes, "a session with nothing to say was closed as dead");
				Assert.isTrue(client.connected && accepted.connected, "a quiet session did not stay up");
				__close(client);
				__closeServer(server);
				async.done();
			});
		}, async, 0.2, 1.0);
	}

	@:timeout(20000)
	public function testAPeerThatGoesSilentIsGivenUpAfterTheIdleTimeout(async:Async):Void {
		if (!__supported(async)) {
			return;
		}

		__connectedPair(function(server, client, accepted) {
			var closed:Bool = false;
			var reason:String = null;
			var gone:Float = 0.0;
			accepted.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) reason = e.text);
			accepted.addEventListener(Event.CLOSE, function(_) closed = true);

			// It stops answering and says nothing about it.
			client.__dispose(false);
			gone = haxe.Timer.stamp();

			NetPump.until(() -> closed, 6.0, function(_) {
				var took:Float = haxe.Timer.stamp() - gone;
				Assert.isTrue(closed, "a session whose peer went silent was never given up");
				Assert.isTrue(took >= 0.9 && took < 3.0, 'gave the peer up after $took s against an idle timeout of 1 s');
				Assert.isTrue(reason != null && reason.indexOf("idle") >= 0, "the close did not say the session was idle: " + reason);
				__closeServer(server);
				async.done();
			});
		}, async, 0.25, 1.0);
	}

	@:timeout(20000)
	public function testClosingAServerTellsItsClients(async:Async):Void {
		if (!__supported(async)) {
			return;
		}

		__connectedPair(function(server, client, accepted) {
			var told:Bool = false;
			client.addEventListener(Event.CLOSE, function(_) told = true);

			server.close();

			NetPump.until(() -> told, 3.0, function(_) {
				Assert.isTrue(told, "a client of a server that closed was never told");
				Assert.isFalse(client.connected);
				__close(client);
				async.done();
			});
		}, async);
	}

	@:timeout(20000)
	public function testAClientOfARestartedServerIsToldItsSessionIsGone(async:Async):Void {
		if (!__supported(async)) {
			return;
		}

		__connectedPair(function(server, client, accepted) {
			var port:Int = server.localPort;

			// The server's process dies: its socket goes, and nothing is sent.
			server.__socket.removeEventListener(DatagramSocketDataEvent.DATA, server.__onData);
			server.__socket.close();

			var restarted = new ReliableDatagramServerSocket();
			restarted.bind(port, "127.0.0.1");
			restarted.listen();

			var told:Bool = false;
			client.addEventListener(Event.CLOSE, function(_) told = true);

			NetPump.until(() -> restarted.localPort > 0, 5.0, function(_) {
				var message = new ByteArray();
				message.writeUTFBytes("still there?");
				client.send(message);

				// Well inside the client's own idle timeout, so only an answer
				// from the restarted server can end the session this soon.
				NetPump.until(() -> told, 3.0, function(_) {
					Assert.isTrue(told, "the restarted server never told the client its session was gone");
					__close(client);
					__closeServer(restarted);
					async.done();
				});
			});
		}, async);
	}

	/**
		A client that writes a burst and closes at once, over a path losing
		one datagram in seven: the server's session hears all of it, in
		order, and then its close, and the client's close follows.

		`close()` dropped what the congestion window had not let out yet and
		what had been lost and was waiting to be sent again, and the server
		took the FIN the moment it came, past any gap.
	**/
	@:timeout(40000)
	public function testABurstClosedAtOnceArrivesWholeOverALossyPath(async:Async):Void {
		if (!__supported(async)) {
			return;
		}

		var server = __server();
		var heard:Array<String> = [];
		var heardAtClose:Int = -1;
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent) {
			var session = e.socket;
			session.addEventListener(DatagramSocketDataEvent.DATA, function(d:DatagramSocketDataEvent) heard.push(d.data.readUTFBytes(d.data.length)));
			session.addEventListener(Event.CLOSE, function(_) heardAtClose = heard.length);
		});

		var client = new LossySocket(7);
		var clientClosed:Bool = false;
		var errors:Array<String> = [];
		client.addEventListener(Event.CLOSE, function(_) clientClosed = true);
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) errors.push(e.text));

		NetPump.until(() -> server.localPort > 0, 5.0, function(_) {
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> client.connected, 5.0, function(ready:Bool) {
				if (!ready) {
					Assert.fail("the client never connected");
					__close(client);
					__closeServer(server);
					async.done();
					return;
				}

				var sent:Array<String> = [for (i in 0...300) "message " + i];
				for (message in sent) {
					var bytes = new ByteArray();
					bytes.writeUTFBytes(message);
					client.send(bytes);
				}
				client.close();

				NetPump.until(() -> heardAtClose >= 0 && clientClosed, 30.0, function(_) {
					Assert.isTrue(client.dropped > 0, "nothing was lost, so nothing was tested");
					Assert.equals(sent.length, heard.length, 'the server heard ${heard.length} of ${sent.length}');
					Assert.same(sent, heard, "what the server heard was not what was sent, in order");
					Assert.equals(sent.length, heardAtClose, "the server's close came before the last of what was sent");
					Assert.isTrue(clientClosed, "the client's close never finished");
					Assert.same([], errors, "the close reported a failure");
					__closeServer(server);
					async.done();
				});
			});
		});
	}

	/**
		A server and one client connected to it, both with the keepalive
		settings given, and the server's session for the client.
	**/
	private function __connectedPair(body:(ReliableDatagramServerSocket, ReliableDatagramSocket, ReliableDatagramSocket)->Void, async:Async,
			keepAlive:Float = ReliableDatagramSocket.DEFAULT_KEEP_ALIVE_INTERVAL, idle:Float = ReliableDatagramSocket.DEFAULT_IDLE_TIMEOUT):Void {
		var server = __server();
		server.keepAliveInterval = keepAlive;
		server.idleTimeout = idle;

		var accepted:ReliableDatagramSocket = null;
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, function(e:ReliableDatagramSocketConnectEvent) accepted = e.socket);

		var client = new ReliableDatagramSocket();
		client.keepAliveInterval = keepAlive;
		client.idleTimeout = idle;

		NetPump.until(() -> server.localPort > 0, 5.0, function(_) {
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> client.connected && accepted != null && accepted.connected, 5.0, function(ready:Bool) {
				if (!ready) {
					Assert.fail("the pair never connected");
					__close(client);
					__closeServer(server);
					async.done();
					return;
				}

				body(server, client, accepted);
			});
		});
	}

	private static function __server():ReliableDatagramServerSocket {
		var server = new ReliableDatagramServerSocket();
		server.bind(0, "127.0.0.1");
		server.listen();
		return server;
	}

	private static function __supported(async:Async):Bool {
		if (ReliableDatagramSocket.isSupported) {
			return true;
		}

		Assert.isFalse(ReliableDatagramSocket.isSupported);
		async.done();
		return false;
	}

	private static function __close(socket:ReliableDatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function __closeServer(server:ReliableDatagramServerSocket):Void {
		try {
			if (server != null) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}
}

/** A client whose every `every`th datagram, once connected, never leaves. **/
@:access(crossbyte.net.ReliableDatagramSocket)
private class LossySocket extends ReliableDatagramSocket {
	public var dropped:Int = 0;

	private var __every:Int;
	private var __count:Int = 0;

	public function new(every:Int) {
		super();
		__every = every;
	}

	override private function __sendDatagram(offset:Int, length:Int):Bool {
		if (__connected && ++__count % __every == 0) {
			dropped++;
			return true;
		}
		return super.__sendDatagram(offset, length);
	}
}
