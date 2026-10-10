package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.io.ByteArray;
import utest.Assert;

@:access(crossbyte.net.DatagramSocket)
class DatagramSocketTest extends utest.Test {
	/**
		The flag says what the target's own UDP socket can do.

		The flag and the socket must agree: neko has a working
		`sys.net.UdpSocket`, so the flag is `true` there, and every target whose
		constructor would throw says `false`.
	**/
	public function testSupportMatchesWhatTheTargetsSocketCanDo():Void {
		#if (sys && !js)
		var works:Bool = try {
			var socket = new sys.net.UdpSocket();
			socket.bind(new sys.net.Host("127.0.0.1"), 0);
			socket.close();
			true;
		} catch (_:Dynamic) {
			false;
		}
		Assert.equals(works, DatagramSocket.isSupported, "a UDP socket " + (works ? "binds" : "cannot bind") + " here");
		#else
		Assert.pass();
		#end
	}

	/**
		There is no read timeout to set. A datagram socket never blocks
		(every read waits on the registry's poll, and Node's socket has no
		timeout at all), so a `timeout` set on the socket underneath would
		have nothing to time, on any target.
	**/
	public function testThereIsNoReadTimeoutToSet():Void {
		var fields:Array<String> = Type.getInstanceFields(DatagramSocket);
		Assert.isTrue(fields.indexOf("bind") >= 0, "the class's fields cannot be read here: " + fields.length);
		for (name in ["timeout", "get_timeout", "set_timeout"]) {
			Assert.equals(-1, fields.indexOf(name), name + " is still there");
		}
	}

	/**
		A port one datagram socket holds is not given to another. With
		SO_REUSEADDR set on every socket it binds, as hxcpp did, Linux lets two
		datagram sockets share a port: a bind to port 0 would hand out ports
		already in use (a game client sharing one with another client, never
		connecting), and any local process could bind a server's port as well.
		hxcpp's socket_bind no longer sets it (the fork's production); Windows
		never set it. Neko's and HashLink's binds still set it, and their
		natives cannot be asked not to, so on Linux DatagramSocket checks its
		port after binding there. Node's bind is asynchronous, and refuses
		through an event.
	**/
	public function testAPortHeldIsNotGivenToAnother():Void {
		#if (sys && !nodejs)
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		var holder = new DatagramSocket();
		var second = new DatagramSocket();
		try {
			holder.bind(0, "127.0.0.1");
			var port:Int = holder.localPort;
			var refused = false;
			try {
				second.bind(port, "127.0.0.1");
			} catch (_:Dynamic) {
				refused = true;
			}
			Assert.isTrue(refused, "a second socket was bound to port " + port + ", which another already held");

			// Refused, the socket is still one to bind elsewhere and use.
			second.bind(0, "127.0.0.1");
			Assert.isTrue(second.localPort > 0 && second.localPort != port, "a socket refused a port held could not be bound to another: " + second.localPort);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try second.close() catch (_:Dynamic) {}
		try holder.close() catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	/**
		One `Address` sent to, changed, and sent to again goes where it now
		points, never where it pointed: its port, its IPv4 host, and its IPv6
		bytes, set anew or changed in place. On the jvm the socket keeps the
		`InetSocketAddress` it made for an Address with it, for the next send,
		so it must be checked against the Address, not kept by identity, or
		the second send of each pair below would go to the first one's peer.
	**/
	public function testAnAddressChangedBetweenSendsGoesWhereItNowPoints():Void {
		#if (sys && !nodejs)
		if (!requireDatagramSupport()) return;

		var got:Map<String, Array<String>> = new Map();
		var sockets:Array<DatagramSocket> = [];
		function receiver(name:String, host:String):Null<DatagramSocket> {
			var socket = new DatagramSocket();
			try {
				socket.bind(0, host);
			} catch (_:Dynamic) {
				closeQuietly(socket);
				return null;
			}
			got.set(name, []);
			socket.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
				e.data.position = 0;
				got.get(name).push(e.data.readUTFBytes(e.data.length));
			});
			socket.receive();
			sockets.push(socket);
			return socket;
		}
		function sendTo(sender:DatagramSocket, target:sys.net.Address, text:String):Void {
			var bytes = haxe.io.Bytes.ofString(text);
			// The path a reliable session's datagrams take, with an Address
			// it keeps.
			sender.__sendNow(bytes, 0, bytes.length, target, null);
		}

		try {
			var a = receiver("a", "127.0.0.1");
			var b = receiver("b", "127.0.0.1");
			// Another loopback address, where the system has one (not macOS).
			var c = receiver("c", "127.0.0.2");
			var sender = new DatagramSocket();
			sockets.push(sender);
			sender.bind(0, "0.0.0.0");

			var target = new sys.net.Address();
			target.setHost(new sys.net.Host("127.0.0.1"));
			target.port = a.localPort;
			sendTo(sender, target, "1");
			target.port = b.localPort;
			sendTo(sender, target, "2");
			target.port = a.localPort;
			sendTo(sender, target, "3");
			// The host changed, the port kept: never to a.
			target.host = new sys.net.Host("127.0.0.2").ip;
			sendTo(sender, target, "4");
			if (c != null) {
				target.port = c.localPort;
				sendTo(sender, target, "5");
			}
			target.setHost(new sys.net.Host("127.0.0.1"));
			target.port = a.localPort;
			sendTo(sender, target, "6");
			pumpUntil(() -> got["a"].length >= 3 && got["b"].length >= 1 && (c == null || got["c"].length >= 1), 2.0);
			pumpUntil(() -> false, 0.1);

			Assert.same(["1", "3", "6"], got["a"], "what the first peer received");
			Assert.same(["2"], got["b"], "what the second peer received");
			if (c != null) {
				Assert.same(["5"], got["c"], "what the peer on another address received");
			}

			if (requireIpv6Loopback()) {
				var d = receiver("d", "::1");
				var e = receiver("e", "::1");
				var sender6 = new DatagramSocket();
				sockets.push(sender6);
				sender6.bind(0, "::1");
				var target6 = new sys.net.Address();
				target6.setHost(new sys.net.Host("::1"));
				target6.port = d.localPort;
				sendTo(sender6, target6, "x");
				target6.port = e.localPort;
				sendTo(sender6, target6, "y");
				target6.port = d.localPort;
				// The IPv6 bytes changed in place, to ::2, which nothing holds.
				var raw:haxe.io.BytesData = @:privateAccess target6.ipv6;
				if (raw != null) {
					var bytes = haxe.io.Bytes.ofData(raw);
					bytes.set(15, 2);
					try sendTo(sender6, target6, "z") catch (_:Dynamic) {}
					bytes.set(15, 1);
				}
				sendTo(sender6, target6, "w");
				pumpUntil(() -> got["d"].length >= 2 && got["e"].length >= 1, 2.0);
				pumpUntil(() -> false, 0.1);
				Assert.same(["x", "w"], got["d"], "what the first IPv6 peer received");
				Assert.same(["y"], got["e"], "what the second IPv6 peer received");
			}
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		for (socket in sockets) {
			closeQuietly(socket);
		}
		#else
		Assert.pass();
		#end
	}

	/**
		`send` is an inline forwarder (so its optional arguments are not boxed
		on the jvm), and still works every other way it could be reached: taken
		as a value, through `Reflect`, and through `Dynamic`, with its arguments
		given or left out.
	**/
	public function testSendReachedAsAValueOrDynamicallyStillSends():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var connected = new DatagramSocket();
		var seen:Array<String> = [];
		try {
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
				e.data.position = 0;
				seen.push(e.data.readUTFBytes(e.data.length));
			});
			receiver.receive();
			sender.bind(0, "127.0.0.1");
			connected.bind(0, "127.0.0.1");
			connected.connect("127.0.0.1", receiver.localPort);
			var port:Int = receiver.localPort;

			var asValue = sender.send;
			asValue(bytesOf("value"), 0, 0, "127.0.0.1", port);
			Reflect.callMethod(sender, Reflect.field(sender, "send"), [bytesOf("reflect"), 0, 0, "127.0.0.1", port]);
			sendThroughDynamic(sender, bytesOf("dynamic"), port);
			sendThroughDynamicConnected(connected, bytesOf("defaults"));
			pumpUntil(() -> seen.length >= 4, 2.0);

			seen.sort(Reflect.compare);
			Assert.same(["defaults", "dynamic", "reflect", "value"], seen);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		closeQuietly(connected);
		closeQuietly(sender);
		closeQuietly(receiver);
	}

	/**
		Every socket bound to port 0 is given a port of its own, however many
		are bound. With SO_REUSEADDR set on datagram sockets, Linux hands out
		ports already held (18 in 1,000 binds in C), and the socket that shared
		one would receive none of its own datagrams.
	**/
	public function testEachSocketBoundToPortZeroHasAPortOfItsOwn():Void {
		#if (sys && !nodejs)
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		var sockets:Array<DatagramSocket> = [];
		var seen:Map<Int, Bool> = new Map();
		var shared:Array<Int> = [];
		try {
			for (_ in 0...500) {
				var socket = new DatagramSocket();
				sockets.push(socket);
				socket.bind(0, "127.0.0.1");
				var port:Int = socket.localPort;
				if (seen.exists(port)) {
					shared.push(port);
				}
				seen.set(port, true);
			}
			Assert.same([], shared, "ports handed out to two sockets at once");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		for (socket in sockets) {
			closeQuietly(socket);
		}
		#else
		Assert.pass();
		#end
	}

	/**
		A socket's own address is asked of the system once, and kept while
		nothing can change it. A getsockname() call on every read of
		`localAddress` or `localPort`, both read by a reliable session for
		every message it hands over, would be two system calls a message, an
		eighth of a game server's time at a thousand clients.
	**/
	public function testItsOwnAddressIsAskedOnce():Void {
		#if (sys && !nodejs)
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		var socket = new DatagramSocket();
		var counting = new CountingUdpSocket();
		try {
			counting.setBlocking(false);
			try socket.__socket.close() catch (_:Dynamic) {}
			counting.custom = socket;
			socket.__socket = counting;

			socket.bind(0, "127.0.0.1");
			var port:Int = socket.localPort;
			var asked:Int = counting.asked;
			for (_ in 0...100) {
				Assert.equals(port, socket.localPort);
				Assert.equals("127.0.0.1", socket.localAddress);
			}
			Assert.isTrue(port > 0, "the bound socket reported port " + port);
			Assert.isTrue(counting.asked - asked <= 1, "200 reads asked the system " + (counting.asked - asked) + " times");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try socket.close() catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	/**
		A number written into a new ByteArray reads back as itself from the
		datagram that carried it: datagram payloads are little-endian, as a
		ByteArray an application makes is, and every other CrossByte socket's,
		so a message built with `new ByteArray()` does not arrive with its
		integers byte-swapped.
	**/
	public function testANumberSentIsTheNumberRead():Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		var listener = new DatagramSocket();
		var sender = new DatagramSocket();
		var number:Null<Int> = null;
		var fraction:Null<Float> = null;

		try {
			listener.bind(0, "127.0.0.1");
			listener.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
				e.data.position = 0;
				number = e.data.readInt();
				fraction = e.data.readDouble();
			});
			listener.receive();
			sender.bind(0, "127.0.0.1");

			var message = new ByteArray();
			message.writeInt(0x01020304);
			message.writeDouble(-1.25);
			sender.send(message, 0, message.length, "127.0.0.1", listener.localPort);

			pumpUntil(() -> number != null, 2.0);
			Assert.equals(0x01020304, number, "the int came back as " + StringTools.hex(number == null ? 0 : number, 8));
			Assert.equals(-1.25, fraction);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try listener.close() catch (_:Dynamic) {}
		try sender.close() catch (_:Dynamic) {}
	}

	public function testAFailedSendDoesNotDeafenTheSocket():Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		// Sending to an address the socket cannot reach (here an IPv6
		// destination from a socket bound to IPv4) fails at the `sendto`, and
		// is supposed to. What must not follow is the socket going deaf.
		//
		// A send failure must not stop the socket receiving: one unroutable
		// destination would stop every other peer being heard from,
		// permanently, and with nothing to say why. ICE finds a path by trying
		// every candidate a peer offered and expecting most of them to fail, so
		// that would be one failed check away on every connection.
		var listener = new DatagramSocket();
		var sender = new DatagramSocket();
		var received:String = null;

		try {
			listener.bind(0, "127.0.0.1");
			listener.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
				e.data.position = 0;
				received = e.data.readUTFBytes(e.data.length);
			});
			listener.receive();

			sender.bind(0, "127.0.0.1");

			var doomed = new ByteArray();
			doomed.writeUTFBytes("nowhere");

			var refused = false;

			try {
				listener.send(doomed, 0, doomed.length, "2001:db8::1", 9);
			} catch (_:Dynamic) {
				refused = true;
			}

			Assert.isTrue(refused, "sending to an unreachable family should fail, or this proves nothing");

			// The whole point: still listening, having been told about one
			// destination it could not reach.
			Assert.isTrue(listener.receiving, "one failed send stopped the socket receiving");

			var hello = new ByteArray();
			hello.writeUTFBytes("still here");
			sender.send(hello, 0, hello.length, "127.0.0.1", listener.localPort);

			pumpUntil(() -> received != null, 2.0);

			Assert.equals("still here", received, "the socket stopped hearing other peers after one send failed");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try listener.close() catch (_:Dynamic) {}
		try sender.close() catch (_:Dynamic) {}
	}

	public function testADeadPeerDoesNotDeafenTheSocket():Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		// Sending to a port nothing listens on makes the peer's stack answer
		// ICMP port unreachable, and Windows reports that back to the sender as
		// an error on a later read, which must not stop the socket receiving:
		// one datagram to a departed peer would silence the socket for every
		// other peer too.
		//
		// A connectionless socket has no connection to lose: the datagram the
		// error complains about is already gone, and nothing about the socket
		// has changed.
		var listener = new DatagramSocket();
		var sender = new DatagramSocket();
		var received:String = null;

		listener.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			e.data.position = 0;
			received = e.data.readUTFBytes(e.data.length);
		});

		try {
			listener.bind(0, "127.0.0.1");
			listener.receive();

			sender.bind(0, "127.0.0.1");
			sender.receive();

			// Port 1 on loopback: reliably nothing, reliably an ICMP answer.
			var knock = new ByteArray();
			knock.writeUTFBytes("nobody home");
			sender.send(knock, 0, knock.length, "127.0.0.1", 1);

			// Let the ICMP find its way back before the real traffic starts.
			pumpUntil(() -> false, 0.3);

			// The sender must still be able to receive. Have the listener
			// answer it, so this exercises the sender's read path rather than
			// only its write path.
			var answered = false;

			sender.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
				answered = true;
			});

			var hello = new ByteArray();
			hello.writeUTFBytes("still here");
			sender.send(hello, 0, hello.length, "127.0.0.1", listener.localPort);

			pumpUntil(() -> received != null, 2.0);
			Assert.equals("still here", received, "the sender could not deliver after touching a closed port");

			var back = new ByteArray();
			back.writeUTFBytes("so am i");
			listener.send(back, 0, back.length, "127.0.0.1", sender.localPort);

			pumpUntil(() -> answered, 2.0);
			Assert.isTrue(answered, "the sender stopped receiving after one datagram to a closed port");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try listener.close() catch (_:Dynamic) {}
		try sender.close() catch (_:Dynamic) {}
	}

	/**
		Where buffers cannot be sized, the socket says so rather than taking
		the size and dropping it.

		HashLink and Neko have UDP and no native for either socket option.
		Setting a size there throws, rather than doing nothing silently and
		reading 0, which would leave a caller sizing its buffers for a burst
		unable to tell that it had not; `bufferSizeSupported` is how a caller
		asks first.
	**/
	public function testBufferSizesThatCannotBeSetSaySo():Void {
		if (!requireDatagramSupport()) return;
		if (DatagramSocket.bufferSizeSupported) {
			Assert.pass();
			return;
		}

		var socket = new DatagramSocket();
		try {
			socket.bind(0, "127.0.0.1");
			Assert.equals(0, socket.receiveBufferSize, "an unknown size read as a size");
			Assert.equals(0, socket.sendBufferSize, "an unknown size read as a size");
			Assert.raises(() -> socket.receiveBufferSize = 96 * 1024, IllegalOperationError);
			Assert.raises(() -> socket.sendBufferSize = 96 * 1024, IllegalOperationError);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		socket.close();
	}

	public function testBufferSizesCanBeReadAndAskedFor():Void {
		if (!requireDatagramSupport()) return;
		if (!DatagramSocket.bufferSizeSupported) {
			// testBufferSizesThatCannotBeSetSaySo is this target's case.
			Assert.isFalse(DatagramSocket.bufferSizeSupported);
			return;
		}

		var socket = new DatagramSocket();
		try {
			socket.bind(0, "127.0.0.1");

			// Whatever the system's defaults are, they are something.
			Assert.isTrue(socket.receiveBufferSize > 0, "no receive buffer size was read");
			Assert.isTrue(socket.sendBufferSize > 0, "no send buffer size was read");

			// A size every system grants: above what some start with, below
			// any cap. Linux reports twice what it keeps; the rest report what
			// was asked, or round it up.
			var asked = 96 * 1024;
			socket.receiveBufferSize = asked;
			socket.sendBufferSize = asked;
			Assert.isTrue(socket.receiveBufferSize >= asked, 'asked for a receive buffer of $asked, read back ${socket.receiveBufferSize}');
			Assert.isTrue(socket.sendBufferSize >= asked, 'asked for a send buffer of $asked, read back ${socket.sendBufferSize}');

			Assert.isTrue(throwsRangeError(() -> socket.receiveBufferSize = 0));
			Assert.isTrue(throwsRangeError(() -> socket.sendBufferSize = -1));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		socket.close();
		Assert.equals(0, socket.receiveBufferSize, "a closed socket read a buffer size");
		Assert.raises(() -> socket.receiveBufferSize = 4096, IOError);
	}

	public function testBindEphemeralPortSetsLocalEndpoint():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		try {
			socket.bind(0, "127.0.0.1");

			Assert.isTrue(socket.bound);
			Assert.equals("127.0.0.1", socket.localAddress);
			Assert.isTrue(socket.localPort > 0);
		} catch (e:Dynamic) {
			closeQuietly(socket);
			throw e;
		}

		closeQuietly(socket);
	}

	public function testValidationErrors():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		var bytes = bytesOf("x");

		Assert.isTrue(throwsRangeError(() -> socket.bind(-1)));
		Assert.isTrue(throwsRangeError(() -> socket.connect("127.0.0.1", 65536)));
		Assert.isTrue(throwsRangeError(() -> socket.connect("127.0.0.1", 0)));
		Assert.isTrue(throwsArgumentError(() -> socket.connect("", 1234)));
		Assert.isTrue(throwsArgumentError(() -> socket.send(bytes)));
		Assert.isTrue(throwsArgumentError(() -> socket.send(null, 0, 0, "127.0.0.1", 1234)));
		Assert.isTrue(throwsRangeError(() -> socket.send(bytes, 0, 0, "127.0.0.1", 0)));
		Assert.isTrue(throwsRangeError(() -> socket.send(bytes, -1, 0, "127.0.0.1", 1234)));
		Assert.isTrue(throwsRangeError(() -> socket.send(bytes, 0, bytes.length + 1, "127.0.0.1", 1234)));

		socket.bind(0, "127.0.0.1");
		socket.connect("127.0.0.1", socket.localPort);
		Assert.isTrue(throwsIllegalOperationError(() -> socket.send(bytes, 0, 0, "127.0.0.1", socket.localPort)));

		closeQuietly(socket);
	}

	public function testReceiveRegistrationFollowsDataListener():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		var listener = (_:DatagramSocketDataEvent) -> {};

		try {
			socket.bind(0, "127.0.0.1");
			socket.receive();

			Assert.isFalse(socket.__registered);
			socket.addEventListener(DatagramSocketDataEvent.DATA, listener);
			Assert.isTrue(socket.__registered);

			socket.removeEventListener(DatagramSocketDataEvent.DATA, listener);
			Assert.isFalse(socket.__registered);
			Assert.isTrue(socket.receiving);
		} catch (e:Dynamic) {
			closeQuietly(socket);
			throw e;
		}

		closeQuietly(socket);
	}

	public function testCloseStopsReceivingAndDispatchesOnce():Void {
		if (!requireDatagramSupport()) return;

		var socket = new DatagramSocket();
		var closeEvents = 0;
		socket.addEventListener(Event.CLOSE, _ -> closeEvents++);
		socket.bind(0, "127.0.0.1");
		socket.addEventListener(DatagramSocketDataEvent.DATA, (_:DatagramSocketDataEvent) -> {});
		socket.receive();

		socket.close();
		socket.close();

		Assert.isFalse(socket.bound);
		Assert.isFalse(socket.connected);
		Assert.isFalse(socket.receiving);
		Assert.isFalse(socket.__registered);
		Assert.equals(1, closeEvents);
	}

	public function testSendReceiveOverLocalhost():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var payload:String = null;
		var srcPort = 0;
		var dstPort = 0;

		try {
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, event -> {
				event.data.position = 0;
				payload = event.data.readUTFBytes(event.data.length);
				srcPort = event.srcPort;
				dstPort = event.dstPort;
			});
			receiver.receive();

			sender.bind(0, "127.0.0.1");
			sender.send(bytesOf("ping"), 0, 0, "127.0.0.1", receiver.localPort);

			pumpUntil(() -> payload != null, 2.0);

			Assert.equals("ping", payload);
			Assert.equals(sender.localPort, srcPort);
			Assert.equals(receiver.localPort, dstPort);
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(receiver);
	}

	public function testConnectedSendUsesDefaultEndpoint():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var payload:String = null;

		try {
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, event -> {
				event.data.position = 0;
				payload = event.data.readUTFBytes(event.data.length);
			});
			receiver.receive();

			sender.bind(0, "127.0.0.1");
			sender.connect("127.0.0.1", receiver.localPort);
			sender.send(bytesOf("connected"));

			pumpUntil(() -> payload != null, 2.0);

			Assert.isTrue(sender.connected);
			Assert.equals("connected", payload);
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(receiver);
	}

	public function testIpv6SendReceiveOverLocalhost():Void {
		if (!requireDatagramSupport()) {
			return;
		}

		var ipv6Supported = requireIpv6Loopback();
		if (!ipv6Supported) {
			Assert.isFalse(ipv6Supported);
			return;
		}

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var payload:String = null;

		try {
			receiver.bind(0, "::1");
			var srcAddress = "";
			receiver.addEventListener(DatagramSocketDataEvent.DATA, event -> {
				event.data.position = 0;
				payload = event.data.readUTFBytes(event.data.length);
				srcAddress = event.srcAddress;
			});
			receiver.receive();

			sender.bind(0, "::1");
			sender.send(bytesOf("ping"), 0, 0, "::1", receiver.localPort);

			pumpUntil(() -> payload != null, 2.0);

			Assert.equals("ping", payload);
			Assert.equals("::1", srcAddress);
			Assert.equals("::1", receiver.localAddress);
			Assert.equals("::1", sender.localAddress);
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(receiver);
	}

	public function testIpv6ConnectedSendUsesDefaultEndpoint():Void {
		if (!requireDatagramSupport()) {
			return;
		}

		var ipv6Supported = requireIpv6Loopback();
		if (!ipv6Supported) {
			Assert.isFalse(ipv6Supported);
			return;
		}

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var payload:String = null;

		try {
			receiver.bind(0, "::1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, event -> {
				event.data.position = 0;
				payload = event.data.readUTFBytes(event.data.length);
			});
			receiver.receive();

			sender.bind(0, "::1");
			sender.connect("::1", receiver.localPort);
			sender.send(bytesOf("connected"));

			pumpUntil(() -> payload != null, 2.0);

			Assert.isTrue(sender.connected);
			Assert.equals("connected", payload);
			Assert.equals("::1", sender.remoteAddress);
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(receiver);
	}

	/**
		A burst larger than one read's worth is taken in on one pass.

		A socket read only 64 datagrams each time it was reported readable,
		once a pass, could take in no more than 64 a pass whatever was arriving
		(3,840 a second at 60 passes), and the rest would wait in, then
		overflow, the kernel's buffer.
	**/
	public function testABurstIsTakenInOnOnePass():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var received:Int = 0;
		var count:Int = 150;

		try {
			// Where it can be asked for: 150 small datagrams fit a default
			// buffer too, which is all HashLink and Neko have.
			if (DatagramSocket.bufferSizeSupported) {
				receiver.receiveBufferSize = 1024 * 1024;
			}
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, function(_) received++);
			receiver.receive();

			sender.bind(0, "127.0.0.1");
			var payload = bytesOf("burst");
			for (_ in 0...count) {
				sender.send(payload, 0, 0, "127.0.0.1", receiver.localPort);
			}
			// Into the receiver's buffer before the pass that reads it.
			crossbyte.sys.System.sleep(0.1);

			CrossByte.current().pump(0, 0);
			var firstPass:Int = received;
			pumpUntil(() -> false, 0.2);

			Assert.isTrue(received > 64, 'only $received of $count datagrams arrived, too few to tell');
			Assert.equals(received, firstPass, 'the pass that found $received datagrams waiting read $firstPass of them');
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(receiver);
	}

	/**
		Datagrams past what one pass takes are read in the same frame.

		A socket takes at most 1,024 a pass, so that a flood cannot hold the
		loop, and the registry asks it once a pass, so it is read again in the
		same frame: otherwise a runtime polled once a frame (the DEFAULT loop,
		or a host's pump) would take no more than 1,024 a frame, 12,288 a second
		at twelve ticks, however many were arriving, and the rest would overflow
		the kernel's buffer.
	**/
	public function testDatagramsPastOnePassesShareAreReadInTheSameFrame():Void {
		#if (cpp || jvm)
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var flood = new FloodUdpSocket();
		var sender = new DatagramSocket();
		var received:Int = 0;
		#if cpp
		// The flood is the read one datagram at a time; a batch is read by
		// recvmmsg, past it. Batches past a pass's share are the case below.
		var batches:Bool = DatagramSocket.__batchReads;
		DatagramSocket.__batchReads = false;
		#end

		try {
			flood.setBlocking(false);
			try receiver.__socket.close() catch (_:Dynamic) {}
			flood.custom = receiver;
			receiver.__socket = flood;
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, function(_) received++);
			receiver.receive();

			sender.bind(0, "127.0.0.1");
			// One datagram really sent, read only once the flood is: it keeps
			// the socket readable for as long as the flood lasts.
			sender.send(bytesOf("x"), 0, 0, "127.0.0.1", receiver.localPort);
			crossbyte.sys.System.sleep(0.05);
			flood.remaining = 3000;

			CrossByte.current().pump(0.25, 0);

			Assert.equals(3001, received, 'one frame read $received of the 3,001 datagrams waiting');
		} catch (e:Dynamic) {
			#if cpp
			DatagramSocket.__batchReads = batches;
			#end
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}

		#if cpp
		DatagramSocket.__batchReads = batches;
		#end
		closeQuietly(sender);
		closeQuietly(receiver);
		#else
		Assert.pass();
		#end
	}

	/**
		A socket read for many peers at once (a reliable UDP server's, for
		all its sessions) takes a share for each in one pass, as each TCP
		connection takes its own: 500 peers' socket takes 3,001 datagrams in
		one, where a socket for one takes 1,024. At 1,024 a pass a server out
		of processor time left the rest in the system's buffer to be read a
		frame later, behind everything since, and every call waited the
		length of that queue.
	**/
	public function testASocketReadForManyPeersTakesAShareForEachInAPass():Void {
		#if (cpp || jvm)
		if (!requireDatagramSupport()) return;
		for (peers in [1, 500]) {
			var receiver = new DatagramSocket();
			var flood = new FloodUdpSocket();
			var received:Int = 0;
			#if cpp
			var batches:Bool = DatagramSocket.__batchReads;
			DatagramSocket.__batchReads = false;
			#end
			try {
				flood.setBlocking(false);
				try receiver.__socket.close() catch (_:Dynamic) {}
				flood.custom = receiver;
				receiver.__socket = flood;
				receiver.bind(0, "127.0.0.1");
				receiver.addEventListener(DatagramSocketDataEvent.DATA, function(_) received++);
				receiver.receive();
				receiver.__readFor(peers);
				flood.remaining = 3001;
				// One pass: the share it takes, and no more.
				receiver.registryOnReadable();
				Assert.equals(peers == 1 ? 1024 : 3001, received, '$peers peers\' socket read $received in a pass');
			} catch (e:Dynamic) {
				#if cpp
				DatagramSocket.__batchReads = batches;
				#end
				closeQuietly(receiver);
				throw e;
			}
			#if cpp
			DatagramSocket.__batchReads = batches;
			#end
			closeQuietly(receiver);
		}
		#else
		Assert.pass();
		#end
	}

	/**
		A burst read in batches (Linux, natively: `recvmmsg`, up to 64 a call)
		arrives as read one at a time: every datagram whole, in the order each
		sender sent it, named as from its sender, the largest UDP carries over
		IPv4 included, an empty one handed out as one at a time does (not at
		all), and the batch grown to its most by a burst that keeps filling it.
		The same with batches turned off, where the result must not differ.
		Elsewhere both runs read one at a time.
	**/
	public function testABurstReadInBatchesArrivesAsReadOneAtATime():Void {
		if (!requireDatagramSupport()) return;
		for (batches in [true, false]) {
			burstOf(batches);
		}
	}

	private function burstOf(batches:Bool):Void {
		var receiver = new DatagramSocket();
		var first = new DatagramSocket();
		var second = new DatagramSocket();
		var got:Map<Int, Array<String>> = new Map();
		var wrong:Array<String> = [];
		var empties:Int = 0;
		#if cpp
		var before:Bool = DatagramSocket.__batchReads;
		var here:Bool = before && batches;
		DatagramSocket.__batchReads = here;
		#end

		try {
			if (DatagramSocket.bufferSizeSupported) {
				receiver.receiveBufferSize = 1024 * 1024;
			}
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
				if (e.data.length == 0) {
					empties++;
					return;
				}
				var index:Int = indexOf(e.data);
				var problem:Null<String> = wrongIn(e.data, index);
				if (problem != null) {
					wrong.push(problem);
				}
				if (!got.exists(e.srcPort)) {
					got.set(e.srcPort, []);
				}
				got.get(e.srcPort).push(index + "/" + e.data.length + "@" + e.srcAddress);
			});
			receiver.receive();
			for (sender in [first, second]) {
				// The largest datagram needs it on macOS.
				if (DatagramSocket.bufferSizeSupported) {
					sender.sendBufferSize = 128 * 1024;
				}
				sender.bind(0, "127.0.0.1");
			}

			// Where the receive buffer cannot be raised (HashLink and Neko), a
			// burst that fits Windows' 64 KB default, without the largest datagram.
			var sizable:Bool = DatagramSocket.bufferSizeSupported;
			var perSender:Int = sizable ? 100 : 30;
			var expected:Map<Int, Array<String>> = [first.localPort => [], second.localPort => []];
			for (i in 0...perSender) {
				for (sender in [first, second]) {
					var index:Int = sender == first ? i : 1000 + i;
					var length:Int = i % 7 == 0 ? 1200 : 4 + i;
					if (sender == second && i == 60) {
						length = 65507;
					}
					#if cpp
					if (sender == first && i == 50) {
						// An empty datagram: none is handed out. Natively only:
						// the jvm's send takes one for a full buffer.
						sender.send(new ByteArray(), 0, 0, "127.0.0.1", receiver.localPort);
					}
					#end
					sender.send(numbered(index, length), 0, 0, "127.0.0.1", receiver.localPort);
					expected[sender.localPort].push(index + "/" + length + "@127.0.0.1");
				}
			}
			// All of it waiting before the first pass reads.
			crossbyte.sys.System.sleep(0.05);
			pumpUntil(() -> count(got) >= 2 * perSender, 3.0);

			var mode:String = batches ? "in batches" : "one at a time";
			for (sender in [first, second]) {
				var port:Int = sender.localPort;
				var arrived:Array<String> = got.exists(port) ? got[port] : [];
				var missing:Array<String> = expected[port].filter(e -> arrived.indexOf(e) < 0);
				Assert.same(expected[port], arrived, 'what a sender sent, read $mode: ${arrived.length} of ${expected[port].length} arrived, missing ${missing.slice(0, 5)}');
			}
			Assert.same([], wrong, 'datagrams read $mode were not as sent');
			Assert.equals(0, empties, 'an empty datagram was handed out, read $mode');
			#if cpp
			if (here) {
				Assert.notNull(receiver.__batch, "a burst was not read in batches");
				Assert.equals(DatagramSocket.BATCH_MOST, receiver.__batchCapacity, "a burst that kept filling the batch did not grow it to its most");
			} else {
				Assert.isNull(receiver.__batch, "a batch was made with batches off, or where there are none");
			}
			DatagramSocket.__batchReads = before;
			#end
		} catch (e:Dynamic) {
			#if cpp
			DatagramSocket.__batchReads = before;
			#end
			closeQuietly(first);
			closeQuietly(second);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(first);
		closeQuietly(second);
		closeQuietly(receiver);
		#if cpp
		Assert.isNull(receiver.__batch, "a closed socket kept its batch");
		#end
	}

	/** Batched, over IPv6: each datagram named as from its sender, `::1`. **/
	public function testABurstOverIpv6IsNamedAsFromEachSender():Void {
		if (!requireDatagramSupport()) return;
		if (!requireIpv6Loopback()) {
			Assert.pass();
			return;
		}

		var receiver = new DatagramSocket();
		var first = new DatagramSocket();
		var second = new DatagramSocket();
		var got:Array<String> = [];

		try {
			receiver.bind(0, "::1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
				got.push(indexOf(e.data) + "@" + e.srcAddress + ":" + e.srcPort);
			});
			receiver.receive();
			first.bind(0, "::1");
			second.bind(0, "::1");

			var expected:Array<String> = [];
			for (i in 0...20) {
				first.send(numbered(i, 40), 0, 0, "::1", receiver.localPort);
				second.send(numbered(100 + i, 40), 0, 0, "::1", receiver.localPort);
				expected.push(i + "@::1:" + first.localPort);
				expected.push((100 + i) + "@::1:" + second.localPort);
			}
			crossbyte.sys.System.sleep(0.05);
			pumpUntil(() -> got.length >= 40, 3.0);

			Assert.same(expected, got, "a datagram over IPv6 was not named as from its sender");
			#if cpp
			if (DatagramSocket.__batchReads) {
				Assert.notNull(receiver.__batch, "a burst over IPv6 was not read in batches");
			}
			#end
		} catch (e:Dynamic) {
			closeQuietly(first);
			closeQuietly(second);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(first);
		closeQuietly(second);
		closeQuietly(receiver);
	}

	/**
		A listener that stops the socket receiving, a few datagrams into a
		batch, is handed the rest once it receives again, before anything
		read after: in order, each once, though the kernel no longer has
		them and so the poll cannot say they are there.
	**/
	public function testWhatABatchHeldWhenReceivingStoppedComesFirstOnReceivingAgain():Void {
		if (!requireDatagramSupport()) return;

		var pair = new BatchPair();
		try {
			pair.onIndex = index -> {
				if (index == 3) {
					pair.receiver.stopReceiving();
				}
			};
			pair.send(0, 8);
			pumpUntil(() -> false, 0.2);
			Assert.same([0, 1, 2, 3], pair.got, "a socket stopped from its listener went on handing datagrams out");

			pair.receiver.receive();
			pumpUntil(() -> pair.got.length >= 8, 2.0);
			pair.send(8, 2);
			pumpUntil(() -> pair.got.length >= 10, 2.0);
			Assert.same([for (i in 0...10) i], pair.got, "what a batch held was lost, repeated or put out of order");
		} catch (e:Dynamic) {
			pair.close();
			throw e;
		}
		pair.close();
	}

	/**
		A listener that throws a few datagrams into a batch ends the pass, as
		it does reading one at a time, and what the batch still holds is
		handed out on the next: in order, each once.
	**/
	public function testWhatABatchHeldWhenAListenerThrewComesNext():Void {
		if (!requireDatagramSupport()) return;

		var pair = new BatchPair();
		try {
			pair.onIndex = index -> {
				if (index == 3) {
					throw "a listener's own failure";
				}
			};
			pair.send(0, 8);
			pumpUntil(() -> pair.got.length >= 8, 2.0);
			Assert.same([for (i in 0...8) i], pair.got, "what a batch held after a listener threw was lost, repeated or put out of order");
			Assert.isTrue(pair.receiver.receiving, "a listener that threw stopped the socket receiving");
		} catch (e:Dynamic) {
			pair.close();
			throw e;
		}
		pair.close();
	}

	/** A listener that closes the socket a few datagrams into a batch is handed nothing more, and the batch goes with the socket. **/
	public function testClosingInsideABatchHandsOutNothingMore():Void {
		if (!requireDatagramSupport()) return;

		var pair = new BatchPair();
		try {
			pair.onIndex = index -> {
				if (index == 3) {
					pair.receiver.close();
				}
			};
			pair.send(0, 8);
			pumpUntil(() -> false, 0.3);
			Assert.same([0, 1, 2, 3], pair.got, "a socket closed from its listener went on handing datagrams out");
			#if cpp
			Assert.isNull(pair.receiver.__batch, "a socket closed from its listener kept its batch");
			#end
		} catch (e:Dynamic) {
			pair.close();
			throw e;
		}
		pair.close();
	}

	/**
		A listener that runs the loop, a few datagrams into a batch, is handed
		the rest inside its own call, from the same batch and then the
		kernel: every datagram once, in order.
	**/
	public function testADatagramArrivingInsideAListenerMidBatchComesInOrder():Void {
		if (!requireDatagramSupport()) return;

		var pair = new BatchPair();
		try {
			var runtime = CrossByte.current();
			pair.onIndex = index -> {
				if (index == 2) {
					var deadline:Float = haxe.Timer.stamp() + 2.0;
					while (pair.got.length < 12 && haxe.Timer.stamp() < deadline) {
						runtime.pump(0, 0);
						crossbyte.sys.System.sleep(0.001);
					}
				}
			};
			pair.send(0, 12);
			pumpUntil(() -> pair.got.length >= 12, 3.0);
			Assert.same([for (i in 0...12) i], pair.got, "datagrams handed out inside a listener were lost, repeated or put out of order");
		} catch (e:Dynamic) {
			pair.close();
			throw e;
		}
		pair.close();
	}

	/** A socket that never has a second datagram waiting at once makes no batch. **/
	public function testASocketReadOneDatagramAtATimeMakesNoBatch():Void {
		if (!requireDatagramSupport()) return;

		var pair = new BatchPair();
		try {
			for (i in 0...5) {
				pair.send(i, 1);
				pumpUntil(() -> pair.got.length > i, 2.0);
			}
			Assert.same([0, 1, 2, 3, 4], pair.got);
			#if cpp
			Assert.isNull(pair.receiver.__batch, "a socket that never had two datagrams waiting made a batch");
			#end
		} catch (e:Dynamic) {
			pair.close();
			throw e;
		}
		pair.close();
	}

	private static function count(got:Map<Int, Array<String>>):Int {
		var n:Int = 0;
		for (list in got) {
			n += list.length;
		}
		return n;
	}

	/** `length` bytes: `index` big-endian, then bytes that follow from it. **/
	private static function numbered(index:Int, length:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.endian = crossbyte.io.Endian.BIG_ENDIAN;
		bytes.writeInt(index);
		for (k in 4...length) {
			bytes.writeByte((index * 31 + k) & 0xFF);
		}
		bytes.position = 0;
		return bytes;
	}

	private static function indexOf(data:ByteArray):Int {
		var raw:haxe.io.Bytes = data;
		return (raw.get(0) << 24) | (raw.get(1) << 16) | (raw.get(2) << 8) | raw.get(3);
	}

	/** Where a datagram `numbered` made is not as made, or null. **/
	private static function wrongIn(data:ByteArray, index:Int):Null<String> {
		var raw:haxe.io.Bytes = data;
		for (k in 4...data.length) {
			if (raw.get(k) != ((index * 31 + k) & 0xFF)) {
				return 'datagram $index of ${data.length} bytes differs at byte $k';
			}
		}
		return data.position == 0 ? null : 'datagram $index was handed out at position ${data.position}';
	}

	/**
		What a pass sends through `__sendInPass` goes when the pass ends,
		every datagram whole and each to its own peer: a run of equal ones to
		one peer, which Linux sends as one call the kernel cuts up, and
		datagrams to two peers in turn, which go 64 to a call. A datagram
		that cannot go is told to its sender.
	**/
	public function testWhatAPassSendsGoesWholeWhenThePassEnds():Void {
		#if (cpp || jvm)
		if (!requireDatagramSupport()) return;

		var sender = new DatagramSocket();
		var first = new DatagramSocket();
		var second = new DatagramSocket();
		var got:Map<String, Array<String>> = ["first" => [], "second" => []];

		try {
			for (receiver in [first, second]) {
				if (DatagramSocket.bufferSizeSupported) {
					receiver.receiveBufferSize = 1024 * 1024;
				}
				receiver.bind(0, "127.0.0.1");
				var name:String = receiver == first ? "first" : "second";
				receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
					e.data.position = 0;
					got[name].push(e.data.readUTFBytes(e.data.length));
				});
				receiver.receive();
			}
			sender.bind(0, "127.0.0.1");

			var toFirst = sender.__resolveTarget("127.0.0.1", first.localPort);
			var toSecond = sender.__resolveTarget("127.0.0.1", second.localPort);
			var expected:Map<String, Array<String>> = ["first" => [], "second" => []];
			function queue(name:String, text:String):Void {
				var bytes = haxe.io.Bytes.ofString(text);
				sender.__sendInPass(bytes, 0, bytes.length, name == "first" ? toFirst : toSecond, null);
				expected[name].push(text);
			}
			// A run of equal datagrams to one peer, the last shorter.
			for (i in 0...40) {
				queue("first", StringTools.lpad(Std.string(i), "0", 1000));
			}
			queue("first", "the end of the run");
			// Then two peers in turn, of every length.
			for (i in 0...50) {
				queue(i % 2 == 0 ? "first" : "second", "datagram " + i + " " + StringTools.lpad("", "x", i * 7));
			}

			var bad = new BadDestination();
			// An IPv6 destination from an IPv4 socket, which every system refuses.
			var nowhere = new sys.net.Address();
			nowhere.setHost(new sys.net.Host("::1"));
			nowhere.port = first.localPort;
			var ping = haxe.io.Bytes.ofString("to an address of the wrong family");
			sender.__sendInPass(ping, 0, ping.length, nowhere, bad);

			#if cpp
			// Asked of the system, not of the listeners, which nothing has pumped.
			var watched:Array<sys.net.Socket> = [first.__socket, second.__socket];
			Assert.equals(0, sys.net.Socket.select(watched, [], [], 0.05).read.length, "a datagram went before the pass ended");
			#end
			@:privateAccess CrossByte.current().__flushHeld();
			pumpUntil(() -> got["first"].length >= expected["first"].length && got["second"].length >= expected["second"].length, 3.0);

			Assert.same(expected["first"], got["first"], "what the first peer received");
			Assert.same(expected["second"], got["second"], "what the second peer received");
			Assert.equals(1, bad.failures, "a datagram that could not go was not reported to its sender");
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(first);
			closeQuietly(second);
			throw e;
		}

		closeQuietly(sender);
		closeQuietly(first);
		closeQuietly(second);
		#else
		Assert.pass();
		#end
	}

	/**
		One pass of datagrams of every size up to the largest UDP carries,
		mixed, and more of them than the runtime's pool of chunks holds:
		natively each lies whole in one chunk, every chunk but the pass's last
		is filled as far as the next datagram allows, and once the pass has
		gone its chunks are back in the pool. Every datagram arrives whole
		and in order.
	**/
	public function testAPassOfEverySizeGoesWholeFromItsChunks():Void {
		#if (cpp || jvm)
		if (!requireDatagramSupport()) return;

		var sender = new DatagramSocket();
		var receiver = new DatagramSocket();
		var got:Array<String> = [];
		var wrong:Array<String> = [];
		try {
			if (DatagramSocket.bufferSizeSupported) {
				receiver.receiveBufferSize = 8 * 1024 * 1024;
				// The largest datagram needs it on macOS.
				sender.sendBufferSize = 128 * 1024;
			}
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
				var index:Int = indexOf(e.data);
				var problem:Null<String> = wrongIn(e.data, index);
				if (problem != null) {
					wrong.push(problem);
				}
				got.push(index + "/" + e.data.length);
			});
			receiver.receive();
			sender.bind(0, "127.0.0.1");
			var target = sender.__resolveTarget("127.0.0.1", receiver.localPort);

			// Every size from 4 (the index) to 65,507, the largest over IPv4,
			// small and large in turn, so chunks end on every kind of remainder.
			var sizes:Array<Int> = [4, 65507, 5, 65000, 1200, 32769, 32768, 64 * 1024 - 1000, 999, 65507, 65507, 1];
			var step:Int = 4;
			while (step < 65507) {
				sizes.push(step);
				step = step * 3 + 1;
			}
			for (i in 0...40) {
				sizes.push(1 + (i * 7919) % 65507);
			}
			var expected:Array<String> = [];
			var total:Int = 0;
			for (i in 0...sizes.length) {
				var length:Int = sizes[i] < 4 ? 4 : sizes[i];
				var bytes:haxe.io.Bytes = numbered(i, length);
				sender.__sendInPass(bytes, 0, length, target, null);
				expected.push(i + "/" + length);
				total += length;
			}

			#if cpp
			var pool = CrossByte.current().__datagramChunks();
			var chunks:Int = sender.__outChunks.length;
			Assert.isTrue(chunks > crossbyte._internal.net.DatagramChunks.SPARE, 'a pass of $total bytes took $chunks chunks, no more than the pool keeps');
			Assert.isTrue(chunks * crossbyte._internal.net.DatagramChunks.CHUNK_SIZE >= total, 'a pass of $total bytes in $chunks chunks');
			Assert.equals(chunks, pool.inUse, "the chunks the pass holds are not those the pool has out");
			var spans:Array<Int> = sender.__outSpans;
			var lastChunk:Int = 0;
			for (k in 0...sizes.length) {
				var chunk:Int = spans[3 * k];
				var at:Int = spans[3 * k + 1];
				var length:Int = spans[3 * k + 2];
				if (at + length > crossbyte._internal.net.DatagramChunks.CHUNK_SIZE) {
					wrong.push('datagram $k runs past its chunk: $at + $length');
				}
				if (chunk != lastChunk && chunk != lastChunk + 1) {
					wrong.push('datagram $k skipped from chunk $lastChunk to $chunk');
				}
				if (chunk == lastChunk + 1 && k > 0) {
					// A new chunk only when the datagram did not fit the last.
					var end:Int = spans[3 * (k - 1) + 1] + spans[3 * (k - 1) + 2];
					if (end + length <= crossbyte._internal.net.DatagramChunks.CHUNK_SIZE) {
						wrong.push('datagram $k went to a new chunk with room in the last');
					}
				}
				lastChunk = chunk;
			}
			var idleBefore:Int = pool.idle;
			@:privateAccess CrossByte.current().__flushHeld();
			Assert.equals(0, sender.__outChunks.length, "the pass kept its chunks after it was sent");
			Assert.equals(0, pool.inUse, "chunks were still out of the pool once the pass had gone");
			Assert.equals(idleBefore + chunks, pool.idle, "the pass's chunks did not go back to the pool");
			#end

			pumpUntil(() -> got.length >= expected.length, 5.0);
			Assert.same(expected, got, 'what arrived: ${got.length} of ${expected.length}');
			Assert.same([], wrong, "datagrams were not as sent");
		} catch (e:Dynamic) {
			closeQuietly(sender);
			closeQuietly(receiver);
			throw e;
		}
		closeQuietly(sender);
		closeQuietly(receiver);
		#else
		Assert.pass();
		#end
	}

	/**
		The pool keeps every chunk while chunks are being taken, up to the
		most a pass held since it was last asked, so a server broadcasting
		every frame takes nothing new. What an interval did not need waits one
		interval more as spare: a burst after a pause of one quiet interval
		takes every chunk back, and after two the pool is down to one. Asked
		by the registry every few seconds; asked directly here.
	**/
	public function testThePoolOfChunksKeepsABurstAcrossAPauseAndLetsItGoWhenQuiet():Void {
		#if cpp
		var pool = new crossbyte._internal.net.DatagramChunks(null);
		var made:Array<haxe.io.Bytes> = [];
		function pass(count:Int):Int {
			var taken = [for (_ in 0...count) pool.take()];
			var fresh:Int = 0;
			for (chunk in taken) {
				if (made.indexOf(chunk) < 0) {
					made.push(chunk);
					fresh++;
				}
				pool.give(chunk);
			}
			return fresh;
		}

		Assert.equals(20, pass(20));
		Assert.equals(20, pool.idle, "a pass's chunks were not kept for the next");
		Assert.equals(0, pass(20), "a second pass as large as the first made chunks of its own");

		// Busy: a pass since the last ask keeps the most it needed.
		pass(5);
		Assert.isTrue(pool.__releaseIfQuiet(), "a busy pool stopped being asked");
		Assert.equals(20, pool.idle, "a busy pool let go of what its largest pass needed");

		// One quiet interval: kept as spare, and taken back by the next burst.
		Assert.isTrue(pool.__releaseIfQuiet(), "a pool holding spare chunks stopped being asked");
		Assert.equals(20, pool.idle, "a pool let go of a burst after one quiet interval");
		Assert.equals(0, pass(20), "a burst after one quiet interval made chunks of its own");

		// Two quiet intervals: down to one.
		Assert.isTrue(pool.__releaseIfQuiet());
		Assert.isTrue(pool.__releaseIfQuiet());
		Assert.isFalse(pool.__releaseIfQuiet(), "a quiet pool holding only its floor went on being asked");
		Assert.equals(crossbyte._internal.net.DatagramChunks.SPARE, pool.idle, "a quiet pool kept more than its floor");

		// Smaller passes since a burst: the rest waits one interval, then goes.
		pass(20);
		Assert.isTrue(pool.__releaseIfQuiet());
		pass(5);
		Assert.isTrue(pool.__releaseIfQuiet());
		Assert.equals(20, pool.idle, "what the smaller passes did not need was let go at once");
		pass(5);
		Assert.isTrue(pool.__releaseIfQuiet());
		Assert.equals(5, pool.idle, "what the smaller passes did not need was kept past a second interval");

		// Chunks out when asked are not counted against the pool.
		pool.__releaseIfQuiet();
		pool.__releaseIfQuiet();
		var out = [for (_ in 0...3) pool.take()];
		pool.__releaseIfQuiet();
		pool.__releaseIfQuiet();
		Assert.equals(3, pool.inUse);
		for (chunk in out) {
			pool.give(chunk);
		}
		Assert.equals(0, pool.inUse);
		Assert.isTrue(pool.idle >= 3, "chunks out when the pool was asked were not taken back");
		#else
		Assert.pass();
		#end
	}

	/**
		Datagrams from two peers in turn, each reported as from its own: the
		source a datagram names is kept from one to the next, and must not be
		kept past a change of sender.
	**/
	public function testInterleavedSendersAreEachNamed():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var first = new DatagramSocket();
		var second = new DatagramSocket();
		var seen:Array<String> = [];

		try {
			receiver.bind(0, "127.0.0.1");
			receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
				e.data.position = 0;
				seen.push(e.data.readUTFBytes(e.data.length) + "@" + e.srcAddress + ":" + e.srcPort + ">" + e.dstAddress + ":" + e.dstPort);
			});
			receiver.receive();
			first.bind(0, "127.0.0.1");
			second.bind(0, "127.0.0.1");

			for (i in 0...3) {
				first.send(bytesOf("a" + i), 0, 0, "127.0.0.1", receiver.localPort);
				second.send(bytesOf("b" + i), 0, 0, "127.0.0.1", receiver.localPort);
			}
			pumpUntil(() -> seen.length >= 6, 2.0);

			var to:String = ">127.0.0.1:" + receiver.localPort;
			seen.sort(Reflect.compare);
			Assert.same([
				"a0@127.0.0.1:" + first.localPort + to,
				"a1@127.0.0.1:" + first.localPort + to,
				"a2@127.0.0.1:" + first.localPort + to,
				"b0@127.0.0.1:" + second.localPort + to,
				"b1@127.0.0.1:" + second.localPort + to,
				"b2@127.0.0.1:" + second.localPort + to
			], seen);
		} catch (e:Dynamic) {
			closeQuietly(first);
			closeQuietly(second);
			closeQuietly(receiver);
			throw e;
		}

		closeQuietly(first);
		closeQuietly(second);
		closeQuietly(receiver);
	}

	// Through a parameter: a local `Dynamic` copied from a typed one would
	// be compiled for neko as the method read off and called unbound,
	// calling `send` without its socket whatever `send` was.
	private static function sendThroughDynamic(socket:Dynamic, bytes:ByteArray, port:Int):Void {
		socket.send(bytes, 0, 0, "127.0.0.1", port);
	}

	private static function sendThroughDynamicConnected(socket:Dynamic, bytes:ByteArray):Void {
		#if (neko || hl)
		// neko and HashLink call any function through Dynamic with exactly
		// the arguments it takes, so one left out is an error there:
		// "Invalid call" on neko, "Missing arguments" on HashLink.
		socket.send(bytes, 0, 0, null, 0);
		#else
		socket.send(bytes);
		#end
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function requireDatagramSupport():Bool {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return false;
		}
		return true;
	}

	private static function requireIpv6Loopback():Bool {
		var socket = new DatagramSocket();
		try {
			socket.bind(0, "::1");
			socket.close();
			return true;
		} catch (_:Dynamic) {
			try {
				socket.close();
			} catch (_:Dynamic) {}
			return false;
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

	private static function closeQuietly(socket:DatagramSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function throwsArgumentError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:ArgumentError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	private static function throwsIllegalOperationError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IllegalOperationError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	private static function throwsRangeError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:RangeError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}

/**
	A receiver and a sender on the loopback, for the batched-receive cases:
	`send(from, n)` sends datagrams numbered `from` on and waits until they
	are all in the receiver's queue; `got` is the numbers handed out, in
	order, and `onIndex` runs inside the listener for each.
**/
@:access(crossbyte.net.DatagramSocketTest)
private class BatchPair {
	public var receiver:DatagramSocket;
	public var sender:DatagramSocket;
	public var got:Array<Int> = [];
	public var onIndex:Int->Void = null;

	public function new() {
		receiver = new DatagramSocket();
		sender = new DatagramSocket();
		if (DatagramSocket.bufferSizeSupported) {
			receiver.receiveBufferSize = 1024 * 1024;
		}
		receiver.bind(0, "127.0.0.1");
		receiver.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent) {
			var index:Int = DatagramSocketTest.indexOf(e.data);
			got.push(index);
			if (onIndex != null) {
				onIndex(index);
			}
		});
		receiver.receive();
		sender.bind(0, "127.0.0.1");
	}

	public function send(from:Int, n:Int):Void {
		for (i in from...from + n) {
			sender.send(DatagramSocketTest.numbered(i, 40), 0, 0, "127.0.0.1", receiver.localPort);
		}
		crossbyte.sys.System.sleep(0.02);
	}

	public function close():Void {
		DatagramSocketTest.closeQuietly(sender);
		DatagramSocketTest.closeQuietly(receiver);
	}
}

#if (sys && !nodejs)
/** A UDP socket that counts the times its own address is asked of the system. **/
private class CountingUdpSocket extends sys.net.UdpSocket {
	public var asked:Int = 0;

	override public function host():{host:sys.net.Host, port:Int} {
		asked++;
		return super.host();
	}
}
#end

#if (cpp || jvm)
/**
	A UDP socket whose reads find `remaining` one-byte datagrams from the
	loopback before anything really sent: a peer sending faster than they
	are read, which a real one only sometimes manages and whose kernel buffer
	would not hold the flood on Linux anyway.
**/
private class FloodUdpSocket extends sys.net.UdpSocket {
	static final LOOPBACK:sys.net.Host = new sys.net.Host("127.0.0.1");

	public var remaining:Int = 0;

	// The read a DatagramSocket makes: the one that answers -1, rather than
	// throwing, for nothing waiting.
	override private function __tryReadFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:sys.net.Address):Int {
		if (remaining <= 0) {
			return super.__tryReadFrom(buf, pos, len, addr);
		}
		remaining--;
		buf.set(pos, 0x2A);
		addr.host = LOOPBACK.ip;
		addr.port = 9;
		return 1;
	}
}
#end

#if (cpp || jvm)
/** A sender through a socket's pass batch, counting what it is told could not go. **/
private class BadDestination implements crossbyte._internal.net.DatagramSender {
	public var failures:Int = 0;

	public function new() {}

	public function __datagramFailed(error:String):Void {
		failures++;
	}
}
#end
