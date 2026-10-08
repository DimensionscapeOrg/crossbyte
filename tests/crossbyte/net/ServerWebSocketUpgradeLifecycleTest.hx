package crossbyte.net;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	What a `ServerWebSocket` does with a session between accepting it and
	opening it (while its peer is still upgrading) when the server stops,
	drains or closes, and what it counts.

	The deadline on those sessions is reaped from the tick that
	`stopAccepting()`, `drain()` and `close()` take away, so each of them
	has to deal with the sessions itself: otherwise a peer caught
	mid-upgrade would be held with no deadline at all, and one that
	finished afterwards would open on a server that had stopped.
	`pendingHandshakeCount()` and `handshakeFailures`, inherited from
	`ServerSocket`, count these sessions too.

	Peers are `WirePeer`s, so each says exactly as much as a case needs, on
	every target, Node included.
**/
class ServerWebSocketUpgradeLifecycleTest extends utest.Test {
	@:timeout(15000)
	public function testStopAcceptingDropsSessionsStillUpgrading(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			server.stopAccepting();

			NetPump.until(() -> __ended(peer), 5.0, function(_) {
				Assert.isTrue(peer.ended, "a session still upgrading outlived stopAccepting()");
				Assert.equals(0, __pending(server), "the server still waited on a session it had let go of");
				Assert.equals(0, server.handshakeFailures, "a session let go of was counted as a failed handshake");
				done();
			});
		}, async);
	}

	@:timeout(15000)
	public function testCloseDropsSessionsStillUpgrading(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			server.close();

			NetPump.until(() -> __ended(peer), 5.0, function(_) {
				Assert.isTrue(peer.ended, "a session still upgrading outlived close()");
				Assert.equals(0, __pending(server), "the server still waited on a session it had let go of");
				done();
			});
		}, async);
	}

	/**
		A peer that asks to upgrade once the server is draining gets nothing:
		no session opens, and no `connect` is dispatched on a server shutting
		down.
	**/
	@:timeout(15000)
	public function testDrainRefusesALateUpgrade(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			var connects:Int = 0;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(_) connects++);

			server.drain(5.0);

			NetPump.until(() -> __ended(peer), 3.0, function(_) {
				Assert.isTrue(peer.ended, "the late peer's connection was left open");

				// Asked once the server has let go, or, where it has not, as late
				// as a peer might. Read only while the connection is up: eval
				// raises the reset that follows a send into a closed one as an
				// error nothing can catch.
				peer.upgrade("/");
				NetPump.until(() -> {
					if (!peer.ended) {
						peer.poll();
					}
					return false;
				}, 0.5, function(_) {
					Assert.isNull(peer.head(), "a server that was draining answered an upgrade: " + peer.head());
					Assert.equals(0, connects, "a session opened on a server that was draining");
					done();
				});
			});
		}, async);
	}

	/**
		A close code that may not be sent is refused before anything is
		stopped, rather than refused by each session's `closeWith` and
		swallowed, with no session hearing why it was dropped.
	**/
	public function testDrainWithACodeThatMayNotBeSentIsRefused():Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		Assert.raises(() -> server.drain(0, null, 1006), ArgumentError);
		Assert.isTrue(server.listening, "a refused drain stopped the server");
		Assert.isFalse(server.draining, "a refused drain left the server draining");

		var completed:Bool = false;
		server.drain(0, () -> completed = true, 4000);
		Assert.isTrue(completed, "a code from the application range was refused");
	}

	/**
		A session given up on at `handshakeTimeout` is counted in
		`handshakeFailures`, as a handshake given up on is by `ServerSocket`.
	**/
	@:timeout(15000)
	public function testASessionGivenUpOnIsCountedAsAFailedHandshake(async:Async):Void {
		__waitingPeer(function(server, peer, done) {
			NetPump.until(() -> __ended(peer), 5.0, function(_) {
				Assert.isTrue(peer.ended, "a session that never upgraded was not given up on");
				Assert.equals(1, server.handshakeFailures, "a session given up on was not counted");
				done();
			});
		}, async, 0.3);
	}

	/**
		An upgrade request the server cannot read is a failed handshake; one
		`upgrade` turned down is a decision, and is not counted.
	**/
	@:timeout(15000)
	public function testABadUpgradeIsCountedAndARefusalIsNot(async:Async):Void {
		var server = new ServerWebSocket();
		server.upgrade = request -> request.path != "/refused";
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var refused = new WirePeer(server.localPort);
			var garbled = new WirePeer(server.localPort);
			refused.upgrade("/refused");
			// No Upgrade header: answered 400.
			garbled.send(Bytes.ofString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"));

			NetPump.until(() -> __ended(refused) && __ended(garbled), 5.0, function(_) {
				Assert.isTrue(refused.ended && garbled.ended, "the server left a connection it had answered open");
				Assert.isTrue(StringTools.startsWith(refused.text(), "HTTP/1.1 403"), "the refusal was not answered 403: " + refused.text());
				Assert.isTrue(StringTools.startsWith(garbled.text(), "HTTP/1.1 400"), "the bad request was not answered 400: " + garbled.text());
				Assert.equals(1, server.handshakeFailures, "the bad upgrade should be counted and the refusal not");
				refused.close();
				garbled.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		`pendingHandshakeCount()` counts the sessions still upgrading, which is
		what `maxPendingHandshakes` bounds.
	**/
	@:timeout(15000)
	public function testPendingHandshakeCountIsTheSessionsStillUpgrading(async:Async):Void {
		var server = new ServerWebSocket();
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var first = new WirePeer(server.localPort);
			var second = new WirePeer(server.localPort);

			NetPump.until(() -> __pending(server) == 2, 5.0, function(_) {
				Assert.equals(2, server.pendingHandshakeCount(), "the sessions still upgrading were not counted");
				first.close();
				second.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		`listen()` wants a bound server, as its doc says, and throws for one
		that is not, rather than leaving it to the system: Windows refuses the
		listen with an error of the socket's own, and Linux and macOS bind the
		socket to a port of their choosing and listen there.
	**/
	public function testListenWantsABoundServer():Void {
		var server = new ServerWebSocket();
		Assert.raises(() -> server.listen(), IOError);
		Assert.isFalse(server.listening, "a server that was never bound listened");
		try server.close() catch (_:Dynamic) {}
	}

	/**
		A port already in use is reported, wherever it is found: natively
		`bind()` throws, and on Node, which claims the port only once
		`listen()` starts, as `ioError` and then `close` (not `close` alone),
		as a `DatagramSocket` reports it there. On eval too, where a bind to a
		port in use must not end the interpreter.
	**/
	@:timeout(15000)
	public function testAPortInUseIsReported(async:Async):Void {
		var holder = new ServerSocket();
		holder.bind(0, "127.0.0.1");
		holder.listen();

		NetPump.until(() -> holder.localPort != 0, 5.0, function(_) {
			var server = new ServerWebSocket();
			var events:Array<String> = [];
			var failure:String = null;
			server.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
				events.push("ioError");
				failure = e.text;
			});
			server.addEventListener(Event.CLOSE, function(_) events.push("close"));

			var thrown:Dynamic = null;
			try {
				server.bind(holder.localPort, "127.0.0.1");
				server.listen();
			} catch (e:Dynamic) {
				thrown = e;
			}

			NetPump.until(() -> thrown != null || events.length >= 2, 5.0, function(_) {
				if (thrown != null) {
					Assert.isTrue(Std.isOfType(thrown, IOError), "a port in use was refused with something other than an IOError: " + thrown);
					Assert.same([], events, "a refused bind was reported twice");
				} else {
					Assert.same(["ioError", "close"], events, "a port in use was not reported as ioError and then close");
					Assert.isTrue(failure != null && failure.indexOf(Std.string(holder.localPort)) >= 0, "the report did not name the port: " + failure);
					Assert.isFalse(server.listening, "a server that could not listen says it is listening");
				}
				try server.close() catch (_:Dynamic) {}
				try holder.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	#if !nodejs
	/**
		The system refusing twice to hand over a waiting connection, as it
		does when the process is out of descriptors, then relenting: counted,
		reported once, and the server carries on, as `ServerSocket` does with
		its own accepts, whether the refusal comes as hxcpp's bare string
		(which must not be swallowed without a trace) or the jvm's I/O error
		(which must not close the server).
	**/
	@:timeout(15000)
	public function testAnAcceptThatFailsIsReportedOnceAndTheServerCarriesOn(async:Async):Void {
		var server = new RefusingServerWebSocket(2);
		var errors:Array<String> = [];
		var closed:Bool = false;
		server.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) errors.push(e.text));
		server.addEventListener(Event.CLOSE, function(_) closed = true);
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);

			NetPump.until(() -> __pending(server) > 0 || closed, 5.0, function(_) {
				Assert.isFalse(closed, "a failed accept closed the server");
				Assert.isTrue(server.listening, "a failed accept stopped the server listening");
				Assert.equals(2, server.acceptFailures, "the failed accepts were not counted");
				Assert.equals(1, errors.length, "a run of failed accepts was not reported exactly once: " + errors);
				Assert.isTrue(errors.length > 0 && errors[0].indexOf("Too many open files") >= 0, "the report did not carry the reason: " + errors[0]);
				Assert.equals(1, __pending(server), "the waiting connection was never taken once the system relented");
				peer.close();
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	/**
		A plain server with one peer connected and saying nothing; `body`
		runs once the server is waiting on it, and closes everything with
		`done`.
	**/
	private function __waitingPeer(body:(ServerWebSocket, WirePeer, Void->Void)->Void, async:Async, handshakeTimeout:Float = 30.0):Void {
		var server = new ServerWebSocket();
		// Long by default, so the deadline is not what ends a session.
		server.handshakeTimeout = handshakeTimeout;
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);

			NetPump.until(() -> __pending(server) > 0, 5.0, function(arrived) {
				Assert.isTrue(arrived, "the peer was never taken on");
				body(server, peer, function() {
					peer.close();
					try server.close() catch (_:Dynamic) {}
					NetPump.wait(0.1, () -> async.done());
				});
			});
		});
	}

	/** Whether `peer` has been hung up on, reading what has arrived. **/
	private static function __ended(peer:WirePeer):Bool {
		peer.poll();
		return peer.ended;
	}

	private static function __pending(server:ServerWebSocket):Int {
		return @:privateAccess server.__pendingUpgrades.length;
	}
}

#if !nodejs
/**
	A server whose system refuses the first `refusals` connections it is
	asked for, the way one out of descriptors does (hxcpp raises that as a
	bare string, the jvm as an I/O error), then hands them over.
**/
private class RefusingServerWebSocket extends ServerWebSocket {
	private var __refusals:Int;

	public function new(refusals:Int) {
		super();
		__refusals = refusals;
	}

	override private function __takeConnection():sys.net.Socket {
		if (__refusals > 0) {
			__refusals--;
			#if cpp
			throw "Too many open files";
			#else
			throw haxe.io.Error.Custom("Too many open files");
			#end
		}
		return super.__takeConnection();
	}
}
#end
