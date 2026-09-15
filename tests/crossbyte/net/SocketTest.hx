package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import haxe.io.Error;
import sys.net.Socket as SysSocket;
import utest.Assert;
import crossbyte.test.Require;

@:access(crossbyte.net.Socket)
class SocketTest extends utest.Test {
	public function testInvalidSocketReadWriteGuards():Void {
		var socket = new Socket();

		Assert.isTrue(throwsIOError(() -> socket.readObject()));
		Assert.isTrue(throwsIOError(() -> socket.readVarUInt()));
		Assert.isTrue(throwsIOError(() -> socket.writeObject({value: 1})));
	}

	public function testTheConstructorAttemptsEveryPortConnectAccepts():Void {
		// 65535 is a valid TCP port. The constructor tested `port < 65535`
		// while connect() accepts `port <= 65535`, so the highest port was
		// the one number the two disagreed about: connect(h, 65535) dialled,
		// new Socket(h, 65535) silently did not.
		ConstructorProbeSocket.lastPort = null;
		new ConstructorProbeSocket("127.0.0.1", 65535);
		Assert.equals(65535, ConstructorProbeSocket.lastPort);

		ConstructorProbeSocket.lastPort = null;
		new ConstructorProbeSocket("127.0.0.1", 1);
		Assert.equals(1, ConstructorProbeSocket.lastPort);

		// Out of range, and the 0 that means "leave it disconnected", are
		// left alone rather than dialled.
		for (port in [0, 65536, -1]) {
			ConstructorProbeSocket.lastPort = null;
			new ConstructorProbeSocket("127.0.0.1", port);
			Assert.isNull(ConstructorProbeSocket.lastPort, "port " + port + " should not have been attempted");
		}
	}

	public function testConnectRefusesAPortOutsideTheRange():Void {
		var socket = new Socket();

		Assert.raises(() -> socket.connect("127.0.0.1", 65536));
		Assert.raises(() -> socket.connect("127.0.0.1", -1));
	}

	public function testCloseToleratesPartiallyInitializedSocket():Void {
		var socket = new Socket();
		socket.__socket = new SysSocket();
		socket.__cbInstance = null;

		socket.close();

		Assert.isNull(socket.__socket);
		Assert.isFalse(socket.connected);
		Assert.isTrue(socket.__closed);
	}

	public function testOpenEventClearsClosedState():Void {
		var socket = new Socket();
		var connectedEvents = 0;
		socket.__closed = true;
		socket.addEventListener(Event.CONNECT, _ -> connectedEvents++);

		socket.socket_onOpen(null);

		Assert.isTrue(socket.connected);
		Assert.isFalse(socket.__closed);
		Assert.equals(1, connectedEvents);
	}

	public function testConnectEventIsReusedAcrossDispatches():Void {
		var socket = new Socket();
		var first = null;
		var second = null;
		var count = 0;
		socket.addEventListener(Event.CONNECT, event -> {
			count++;
			if (count == 1) {
				first = event;
			} else if (count == 2) {
				second = event;
			}
		});

		socket.socket_onOpen(null);
		socket.socket_onOpen(null);

		Assert.notNull(first);
		Assert.equals(first, second);
	}

	public function testWriteWithoutRuntimeBuffersButDoesNotCrash():Void {
		var socket = new Socket();
		socket.__socket = new SysSocket();
		socket.__cbInstance = null;
		socket.__output = new ByteArray();
		socket.__output.endian = socket.__endian;

		socket.writeByte(42);

		Assert.equals(1, socket.bytesPending);
		Assert.isFalse(socket.__isDirty);
	}

	public function testBlockedErrorRecognitionIncludesCustomBlocked():Void {
		var socket = new Socket();

		Assert.isTrue(socket.__isBlockedError(Error.Blocked));
		Assert.isTrue(socket.__isBlockedError(Error.Custom(Error.Blocked)));
		Assert.isFalse(socket.__isBlockedError(Error.Custom("boom")));
	}

	public function testFailedConnectCleanupResetsState():Void {
		var socket = new Socket();
		socket.__socket = new SysSocket();
		socket.__cbInstance = crossbyte.core.CrossByte.current();
		socket.__connected = true;
		socket.__isConnecting = true;
		socket.__isDirty = true;
		socket.flushFull = true;
		socket.__closed = false;

		socket.__cleanupFailedConnect();

		Assert.isNull(socket.__socket);
		Assert.isNull(socket.__cbInstance);
		Assert.isFalse(socket.connected);
		Assert.isFalse(socket.__isConnecting);
		Assert.isFalse(socket.__isDirty);
		Assert.isFalse(socket.flushFull);
		Assert.isTrue(socket.__closed);
	}

	public function testInvalidHostDispatchesIOErrorWithoutSocket():Void {
		var socket = new Socket();
		var errors = 0;
		socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> errors++);

		socket.connect("bad host name", 80);

		Assert.equals(1, errors);
		Assert.isNull(socket.__socket);
		Assert.isFalse(socket.connected);
	}

	public function testPartialFlushRetainsUnwrittenBytes():Void {
		var socket = socketWithOutput("abcdef");

		socket.__retainPendingOutput(2, socket.__output.length);

		Assert.equals(4, socket.bytesPending);
		Assert.equals("cdef", readOutput(socket));
		Assert.isFalse(socket.__isDirty);
	}

	public function testZeroByteFlushRetainsAllBytes():Void {
		var socket = socketWithOutput("abcdef");

		socket.__retainPendingOutput(0, socket.__output.length);

		Assert.equals(6, socket.bytesPending);
		Assert.equals("abcdef", readOutput(socket));
		Assert.isFalse(socket.__isDirty);
	}

	public function testCompleteFlushClearsPendingBytes():Void {
		var socket = socketWithOutput("abcdef");

		socket.__retainPendingOutput(socket.__output.length, socket.__output.length);

		Assert.equals(0, socket.bytesPending);
		Assert.isFalse(socket.__isDirty);
	}

	public function testSocketDataEventIsReusedAcrossDispatches():Void {
		var socket = new Socket();
		var first:ProgressEvent = null;
		var second:ProgressEvent = null;
		var count = 0;
		socket.addEventListener(ProgressEvent.SOCKET_DATA, event -> {
			count++;
			if (count == 1) {
				first = event;
			} else if (count == 2) {
				second = event;
			}
		});

		socket.__dispatchPooledSocketData(4, 0);
		socket.__dispatchPooledSocketData(8, 0);

		Assert.notNull(first);
		Assert.equals(first, second);
		Assert.equals(8, second.bytesLoaded);
	}

	/**
		The connect event comes from the tick that confirms the socket is
		writable, never synchronously from inside connect().

		It used to fire synchronously whenever a non-blocking connect completed
		immediately -- which a loopback connect intermittently does on Windows --
		and a CONNECT listener that wrote then reached a socket the OS had
		reported connected but not finished the handshake on, whose write failed
		with Eof. That surfaced, through a since-corrected flush message, as an
		"invalid socket" failure on a connection that was in fact healthy: a rare
		red run that never reproduced under a debugger because the window is one
		instruction wide. Deferring the event to the writability check the tick
		already makes closes the window. Pinned as: no CONNECT at the instant
		connect() returns.
	**/
	/**
		A bind that fails says what failed.

		Every one of these catch blocks used to answer with "Operation attempted
		on invalid socket." -- a message describing a socket that was perfectly
		fine, when it was the address that would not take. The same fabrication
		in `Socket.flush` cost weeks on an unrelated intermittent, because the
		one line of evidence a red run produced named a cause that had not
		happened. The rule this pins: a caught error is reported, never replaced.

		192.0.2.1 is TEST-NET-1 -- a valid numeric address that is not an
		interface on any machine, so the operating system must refuse it.
	**/
	/**
		A connection that is refused is reported as a failure, promptly.

		The other half of the verdict `testAOneShotPeerConnectsDeliversAndClose
		sWithoutError` pins: a connection that never came up must arrive as an
		ioError and never as a CLOSE, because a caller retries one and not the
		other.

		The timing is the other half again. The completion tick used to ask
		select about writability alone, and a refused connect is reported on
		Windows in the exception set and never becomes writable -- so nothing
		noticed until the connect timeout, twenty seconds by default, for a
		refusal the operating system had already reported. Measured at 20001ms
		before this was fixed. The deadline here is far below that and far
		above what the refusal actually costs.
	**/
	public function testARefusedConnectionIsReportedAsAFailureNotAClose():Void {
		var client = new Socket();
		var events:Array<String> = [];

		client.addEventListener(Event.CONNECT, _ -> events.push("connect"));
		client.addEventListener(Event.CLOSE, _ -> events.push("close"));
		client.addEventListener(IOErrorEvent.IO_ERROR, _ -> events.push("ioerror"));

		try {
			// Port 1 on loopback: nothing listens there.
			client.connect("127.0.0.1", 1);
			pumpUntil(() -> events.length > 0, 8.0);

			Assert.isTrue(events.indexOf("ioerror") >= 0,
				"a refused connection was not reported as a failure within the deadline: " + events);
			Assert.isTrue(events.indexOf("close") < 0,
				"a connection that never came up was reported as a hangup, which a caller cannot tell from a real one");
			Assert.isTrue(events.indexOf("connect") < 0,
				"CONNECT was dispatched for a connection that was refused");

			closeQuietly(client);
		} catch (e:Dynamic) {
			closeQuietly(client);
			throw e;
		}
	}

	/**
		A retry that fails reports the error and does not escape.

		`__tryFlush` is the second half of a blocked write, run from the
		registry's writable queue. Anything it throws unwinds through the
		runtime's drain and costs every other connection in that pass rather
		than this one, so a write that fails has to leave as an ioError on this
		socket and nothing more.

		The drain callback must not run either. It means "the buffer emptied",
		and it did not.
	**/
	public function testAFailedWritableRetryReportsAndDoesNotEscape():Void {
		var socket = socketWithOutput("payload");

		// A real descriptor that has been closed: the write reaches the socket
		// layer and fails there, which is the shape a peer reset produces.
		var dead = new SysSocket();
		dead.close();
		socket.__socket = dead;

		var errors:Array<String> = [];
		var drained = false;
		socket.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> errors.push(e.text));
		socket.__onWritableDrain = () -> drained = true;

		// Must not throw out of here.
		socket.__tryFlush();

		Assert.equals(1, errors.length, "a retry that failed did not report an ioError");
		Assert.isTrue(errors[0].length > 0, "the ioError carried no reason");
		Assert.isFalse(drained, "the writable-drain callback ran after the flush had failed");
	}

	/**
		A retry on a socket that is already gone does nothing at all.

		Between a write blocking and the queue draining, the socket may have
		been closed -- by the peer, by the application, or by the overflow
		policy. There is nothing to retry and nothing to report; what matters
		is that it does not throw into the drain.
	**/
	public function testARetryOnAClosedSocketIsSilent():Void {
		var socket = socketWithOutput("payload");
		socket.flushFull = true;

		var errors = 0;
		var drained = false;
		socket.addEventListener(IOErrorEvent.IO_ERROR, _ -> errors++);
		socket.__onWritableDrain = () -> drained = true;

		socket.__tryFlush();

		Assert.equals(0, errors, "a retry on a socket that was already gone reported an error");
		Assert.isFalse(drained, "the drain callback ran for a socket with nothing to drain");
		Assert.isFalse(socket.flushFull, "flushFull was left set, so the socket would never be queued again");
	}

	public function testAFailedBindSaysWhatFailed():Void {
		var server = new ServerSocket();
		var message:String = null;

		try {
			server.bind(0, "192.0.2.1");
		} catch (e:Dynamic) {
			message = Std.string(e);
		}

		closeServerQuietly(server);

		Require.notNull(message, "binding an address this machine does not have was not reported at all");
		Assert.isTrue(message.indexOf("192.0.2.1") >= 0,
			"the failure does not say which address would not bind: " + message);
		Assert.isTrue(message.indexOf("invalid socket") < 0,
			"a bind failure was reported as an invalid socket, which it was not: " + message);
	}

	public function testConnectIsNeverDispatchedSynchronously():Void {
		var server = new ServerSocket();
		var client = new Socket();
		var connectedSynchronously = false;
		var connected = false;

		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> connected = true);
		try {
			client.connect("127.0.0.1", server.localPort);
			// No tick has run yet. A synchronous dispatch would already show here.
			connectedSynchronously = connected;
			pumpUntil(() -> connected, 3.0);

			Assert.isFalse(connectedSynchronously,
				"connect dispatched CONNECT synchronously, before any tick confirmed the socket was writable");
			Assert.isTrue(connected, "CONNECT never arrived from the tick");

			closeQuietly(client);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeServerQuietly(server);
			throw e;
		}
	}

	/**
		A one-shot peer -- accept, write, close -- delivers CONNECT, then the
		data, then CLOSE, and never an ioError.

		Its data and FIN follow the connection coming up so closely that all
		three can land in one client tick. That tick must still announce CONNECT,
		because the connection did come up, and end in CLOSE, because the peer
		hung up cleanly after a complete exchange -- not ioError, which means the
		connect failed. The tick guard used to drop CONNECT whenever a close was
		decided in the same tick, and the dropped CONNECT flipped the close
		verdict to a failure the connection never suffered.
	**/
	public function testAOneShotPeerConnectsDeliversAndClosesWithoutError():Void {
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var events:Array<String> = [];
		var received = new ByteArray();

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			// A full read chunk, then close at once. The burst and the FIN reach
			// the client together, so they land in the same tick the connect
			// completes -- the arrangement the fix is about. A short payload can
			// arrive a tick later, when CONNECT and the close no longer coincide
			// and the old guard was never exercised.
			var payload = new ByteArray();
			for (i in 0...Socket.READ_CHUNK) {
				payload.writeByte(i & 0xFF);
			}
			serverPeer.writeBytes(payload);
			serverPeer.flush();
			serverPeer.close();
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> events.push("connect"));
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			client.readBytes(received, received.length, client.bytesAvailable);
			events.push("data");
		});
		client.addEventListener(Event.CLOSE, _ -> events.push("close"));
		client.addEventListener(IOErrorEvent.IO_ERROR, _ -> events.push("ioerror"));

		try {
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> events.indexOf("close") >= 0 || events.indexOf("ioerror") >= 0, 3.0);

			Assert.isTrue(events.indexOf("ioerror") < 0, "a clean one-shot exchange was reported as a connection failure");
			Assert.isTrue(events.indexOf("connect") >= 0, "CONNECT was never dispatched for a connection that came up");
			Assert.isTrue(events.indexOf("close") >= 0, "CLOSE was never dispatched");
			Assert.isTrue(events.indexOf("connect") < events.indexOf("close"), "CONNECT must precede CLOSE");
			Assert.equals(Socket.READ_CHUNK, received.length);

			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testClientServerEchoOverLocalhost():Void {
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var echoed:String = null;
		var connected = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var data = new ByteArray();
				serverPeer.readBytes(data, 0, serverPeer.bytesAvailable);
				serverPeer.writeBytes(data);
				serverPeer.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			client.writeUTFBytes("ping");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			echoed = client.readUTFBytes(client.bytesAvailable);
		});
		try {
			client.connect("127.0.0.1", server.localPort);

			pumpUntil(() -> echoed != null, 2.0);

			Assert.isTrue(connected);
			Assert.notNull(serverPeer);
			Assert.equals("ping", echoed);
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testHalfOpenPeerReceivesAResponseWrittenAfterItsFin():Void {
		// The point of the whole policy. The client says everything it has to
		// say, shuts its write side, and waits. Under CLOSE the server treats
		// that FIN as the end of the conversation and the answer is never
		// written; under HALF_OPEN it is written, and arrives.
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var peerClosed = false;
		var answer:String = null;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.peerShutdownPolicy = HALF_OPEN;
			serverPeer.addEventListener(Event.PEER_CLOSE, _ -> {
				peerClosed = true;
				// Answering from here is the idiom the policy exists for: the
				// request is complete precisely because the peer half-closed.
				serverPeer.writeUTFBytes("answered-after-fin");
				serverPeer.flush();
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("request");
			client.flush();
			client.shutdown(false, true);
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			answer = client.readUTFBytes(client.bytesAvailable);
		});

		try {
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> answer != null, 3.0);

			Assert.isTrue(peerClosed);
			Assert.equals("answered-after-fin", answer);
			Assert.isTrue(serverPeer.peerShutdown);
			// Still open: HALF_OPEN ends the read direction, not the socket.
			Assert.isTrue(serverPeer.connected);

			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testDefaultPolicyStillClosesOnPeerFin():Void {
		// The default has to stay exactly what it was, or every consumer that
		// never heard of this proposal changes behaviour. A peer FIN closes,
		// dispatches CLOSE and not PEER_CLOSE -- and peerShutdown is still set,
		// so a CLOSE consumer can tell a graceful end from an error one.
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var closed = false;
		var peerClosed = false;
		var sawShutdownFlag = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.addEventListener(Event.PEER_CLOSE, _ -> peerClosed = true);
			serverPeer.addEventListener(Event.CLOSE, _ -> {
				closed = true;
				sawShutdownFlag = serverPeer.peerShutdown;
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("request");
			client.flush();
			client.shutdown(false, true);
		});

		try {
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> closed, 3.0);

			Assert.isTrue(closed);
			Assert.isFalse(peerClosed);
			Assert.isTrue(sawShutdownFlag);

			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testHalfOpenStopsReadingRatherThanRepeatingTheFin():Void {
		// A shut read direction reports Eof on every subsequent poll, so
		// without a gate the policy branch re-enters each tick and PEER_CLOSE
		// arrives over and over. Once is a fact; repeatedly is a busy loop.
		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var peerCloseCount = 0;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.peerShutdownPolicy = HALF_OPEN;
			serverPeer.addEventListener(Event.PEER_CLOSE, _ -> peerCloseCount++);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			client.writeUTFBytes("request");
			client.flush();
			client.shutdown(false, true);
		});

		try {
			client.connect("127.0.0.1", server.localPort);
			pumpUntil(() -> peerCloseCount > 0, 3.0);

			// Keep pumping well past the FIN: a repeat would land in here.
			var settle:Float = Sys.time() + 0.5;
			while (Sys.time() < settle) {
				CrossByte.current().pump(1 / 60, 0);
			}

			Assert.equals(1, peerCloseCount);

			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}
	}

	public function testIpv6ClientServerEchoOnLoopback():Void {
		var ipv6Supported = requireIpv6Loopback();
		if (!ipv6Supported) {
			Assert.isFalse(ipv6Supported);
			return;
		}

		var server = new ServerSocket();
		var client = new Socket();
		var serverPeer:Socket = null;
		var echoed:String = null;
		var connected = false;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, event -> {
			serverPeer = event.socket;
			serverPeer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var data = new ByteArray();
				serverPeer.readBytes(data, 0, serverPeer.bytesAvailable);
				serverPeer.writeBytes(data);
				serverPeer.flush();
			});
		});
		server.bind(0, "::1");
		server.listen();

		client.addEventListener(Event.CONNECT, _ -> {
			connected = true;
			client.writeUTFBytes("pong");
			client.flush();
		});
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			echoed = client.readUTFBytes(client.bytesAvailable);
		});
		try {
			client.connect("::1", server.localPort);

			pumpUntil(() -> echoed != null, 2.0);

			Assert.isTrue(connected);
			Assert.notNull(serverPeer);
			Assert.equals("pong", echoed);
			Assert.equals("::1", server.localAddress);
			// Guarded: a failed `Assert.notNull` does not stop the test -- utest
			// records it and carries on -- and reading a field off the null that
			// follows is a SIGSEGV on hxcpp release, not a catchable error.
			if (serverPeer != null) {
				Assert.equals("::1", serverPeer.localAddress);
			}
			Assert.equals(0, serverPeer.__socket.peer().host.ip);
			Assert.equals("::1", client.remoteAddress);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(serverPeer);
			closeServerQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(serverPeer);
		closeServerQuietly(server);
	}

	public function testServerSocketIdlePumpDoesNotClose():Void {
		var server = new ServerSocket();
		var closeEvents = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, _ -> {});
		server.addEventListener(Event.CLOSE, _ -> closeEvents++);

		try {
			server.bind(0, "127.0.0.1");
			server.listen();

			CrossByte.current().pump(1 / 60, 0);

			Assert.isTrue(server.listening);
			Assert.equals(0, closeEvents);
		} catch (e:Dynamic) {
			closeServerQuietly(server);
			throw e;
		}

		closeServerQuietly(server);
	}

	private static function throwsIOError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IOError) {
			return true;
		} catch (_:Dynamic) {
			return false;
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

	private static function closeQuietly(socket:Socket):Void {
		try {
			if (socket != null && socket.__socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function closeServerQuietly(server:ServerSocket):Void {
		try {
			if (server != null && server.listening) {
				server.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function requireIpv6Loopback():Bool {
		var server = new ServerSocket();
		try {
			server.bind(0, "::1");
			server.close();
			return true;
		} catch (_:Dynamic) {
			try {
				server.close();
			} catch (_:Dynamic) {}
			return false;
		}
	}

	private static function socketWithOutput(value:String):Socket {
		var socket = new Socket();
		socket.__output = new ByteArray();
		socket.__output.endian = socket.__endian;
		socket.__output.writeUTFBytes(value);
		socket.__isDirty = true;
		return socket;
	}

	private static function readOutput(socket:Socket):String {
		socket.__output.position = 0;
		return socket.__output.readUTFBytes(socket.__output.length);
	}
}

/**
	A Socket whose `connect` records the call instead of making it, so the
	constructor's port guard can be checked without opening anything.

	`lastPort` is static on purpose: Haxe runs member initialisers after the
	super() call, so an instance field would be reset to null by the very
	construction being observed.
**/
private class ConstructorProbeSocket extends Socket {
	public static var lastPort:Null<Int>;

	public function new(host:String, port:Int) {
		super(host, port);
	}

	override public function connect(host:String, port:Int):Void {
		lastPort = port;
	}
}
