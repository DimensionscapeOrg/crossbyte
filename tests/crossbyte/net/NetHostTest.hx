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
			// Guarded: a failed `Assert.notNull` does not stop the test, utest
			// records it and carries on, and reading a field off the null that
			// follows is a SIGSEGV on hxcpp release, not a catchable error.
			if (accepted != null) {
				Assert.equals(Protocol.TCP, accepted.protocol);
			}
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
		// Guarded: a failed `Assert.notNull` does not stop the test, utest
		// records it and carries on, and reading a field off the null that
		// follows is a SIGSEGV on hxcpp release, not a catchable error.
		if (accepted != null) {
			Assert.equals(Protocol.WEBSOCKET, accepted.protocol);
		}
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
			// Guarded: a failed `Assert.notNull` does not stop the test, utest
			// records it and carries on, and reading a field off the null that
			// follows is a SIGSEGV on hxcpp release, not a catchable error.
			if (accepted != null) {
				Assert.equals(Protocol.RUDP, accepted.protocol);
			}
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
		wrong address for a peer sitting behind the same one, reaching it
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

			// Refused through the Future it answers with, as every failure of
			// a Future-returning member is; it used to be thrown, so a caller
			// handling failure on the Future missed this one.
			var discovery = host.discoverPublicAddress("127.0.0.1");
			Assert.isTrue(discovery.completed && !discovery.succeeded, "a stream host answered a question about an endpoint it has not got");
			Assert.isTrue(Std.isOfType(discovery.cause, crossbyte.errors.IllegalOperationError), "the refusal's cause is " + discovery.cause);

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

	/**
		A host of the application's own reaches its relay through `NetHost`.

		`NetHost` wraps any `INetHost`, but it found a relay only by
		downcasting to the reliable datagram host it makes itself, so a host
		written elsewhere was refused whatever it could do, and code holding
		an `INetHost` could not ask at all, the relay being on the abstract
		alone.
	**/
	public function testAHostOfItsOwnReachesItsRelay():Void {
		var own = new RelayingHost();
		var host:NetHost = own;

		host.allocateRelay("198.51.100.1", 3478, "user", "secret");
		host.permitRelayedPeer("203.0.113.9");
		host.dialRelayed("203.0.113.9", 4000, 250);

		Assert.equals("allocateRelay 198.51.100.1:3478 user|permitRelayedPeer 203.0.113.9|dialRelayed 203.0.113.9:4000 250",
			own.calls.join("|"));

		// And through the interface, for code that holds one.
		var asInterface:INetHost = own;
		asInterface.permitRelayedPeer("203.0.113.10");
		Assert.equals("permitRelayedPeer 203.0.113.10", own.calls[own.calls.length - 1]);
	}

	/** A stream host has no relay: each of the three refuses, as `dial` does. **/
	public function testAStreamHostRefusesEveryRelayCall():Void {
		var hosts:Array<NetHost> = [NetHost.fromServerSocket(new ServerSocket()), NetHost.fromServerWebSocket(new ServerWebSocket())];

		// Named, not numbered: joined to a string, the protocol was its Int,
		// and this read "A 0 host has no relay".
		var message:String = null;
		try {
			hosts[0].permitRelayedPeer("127.0.0.1");
		} catch (e:crossbyte.errors.IllegalOperationError) {
			message = e.message;
		}
		Assert.isTrue(message != null && StringTools.startsWith(message, "A TCP host has no relay"), "the refusal reads: " + message);

		for (host in hosts) {
			// A Future's failure, not a throw; see testAStreamHostAnswersWhatItCannotDiscover.
			var relay = host.allocateRelay("127.0.0.1", 3478, "user", "secret");
			Assert.isTrue(relay.completed && !relay.succeeded, "a stream host allocated a relay");
			Assert.isTrue(Std.isOfType(relay.cause, crossbyte.errors.IllegalOperationError), "the refusal's cause is " + relay.cause);
			Assert.raises(() -> host.dialRelayed("127.0.0.1", 3478), crossbyte.errors.IllegalOperationError);
			Assert.raises(() -> host.permitRelayedPeer("127.0.0.1"), crossbyte.errors.IllegalOperationError);
			closeHostQuietly(host);
		}
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
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

/** A host of an application's own, which records what it is asked. **/
private class RelayingHost implements INetHost {
	public var calls:Array<String> = [];

	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var isRunning(get, never):Bool;
	public var protocol(default, null):Protocol = RUDP;
	public var maxConnections(get, set):Int;
	public var refusedConnections(get, never):Int;
	public var onAccept(get, set):INetConnection->Void;
	public var onDisconnect(get, set):(INetConnection, Reason) -> Void;
	public var onError(get, set):Reason->Void;
	public var canDial(get, never):Bool;

	public function new() {}

	public function bind(address:String, port:Int):Void {}

	public function dial(address:String, port:Int, timeoutMs:Int = 0):INetConnection {
		return null;
	}

	public function discoverPublicAddress(server:String, port:Int = 3478, timeoutMs:Int = 3000):crossbyte.Future<ReflexiveAddress> {
		return null;
	}

	public function localAddressFor(destination:String):crossbyte.Future<String> {
		return null;
	}

	public function allocateRelay(server:String, port:Int = 3478, username:String, password:String, useChannels:Bool = false,
			?transport:TurnTransport):crossbyte.Future<ReflexiveAddress> {
		calls.push("allocateRelay " + server + ":" + port + " " + username);
		return null;
	}

	public function dialRelayed(address:String, port:Int, timeoutMs:Int = 0):INetConnection {
		calls.push("dialRelayed " + address + ":" + port + " " + timeoutMs);
		return null;
	}

	public function permitRelayedPeer(address:String):Void {
		calls.push("permitRelayedPeer " + address);
	}

	public function listen():Void {}

	public function close():Void {}

	private var __maxConnections:Int = 0;

	private function get_maxConnections():Int {
		return __maxConnections;
	}

	private function set_maxConnections(value:Int):Int {
		return __maxConnections = value;
	}

	private function get_refusedConnections():Int {
		return 0;
	}

	private function get_localAddress():String {
		return "127.0.0.1";
	}

	private function get_localPort():Int {
		return 0;
	}

	private function get_isRunning():Bool {
		return false;
	}

	private function get_canDial():Bool {
		return true;
	}

	private function get_onAccept():INetConnection->Void {
		return null;
	}

	private function set_onAccept(value:INetConnection->Void):INetConnection->Void {
		return value;
	}

	private function get_onDisconnect():(INetConnection, Reason) -> Void {
		return null;
	}

	private function set_onDisconnect(value:(INetConnection, Reason) -> Void):(INetConnection, Reason) -> Void {
		return value;
	}

	private function get_onError():Reason->Void {
		return null;
	}

	private function set_onError(value:Reason->Void):Reason->Void {
		return value;
	}
}
