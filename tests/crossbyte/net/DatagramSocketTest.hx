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

		It said `false` on neko after neko was given a working
		`sys.net.UdpSocket`, which skipped every case here there and left
		`LocalAddress` refusing to answer; before that it said `true` while
		the constructor threw. Either way the flag and the socket disagreed.
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

	public function testAFailedSendDoesNotDeafenTheSocket():Void {
		if (!DatagramSocket.isSupported) {
			Assert.isFalse(DatagramSocket.isSupported);
			return;
		}

		// Sending to an address the socket cannot reach -- here an IPv6
		// destination from a socket bound to IPv4 -- fails at the `sendto`, and
		// is supposed to. What must not follow is the socket going deaf.
		//
		// It did. `send` routed the failure into __dispatchIoError, which calls
		// stopReceiving, so one unroutable destination stopped every other peer
		// being heard from -- permanently, and with nothing to say why. ICE
		// finds a path by trying every candidate a peer offered and expecting
		// most of them to fail, so this was one failed check away on every
		// connection, and a browser interoperability run is what finally
		// surfaced it.
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
		// an error on a later read. That read error used to reach
		// __dispatchIoError, which calls stopReceiving() -- so one datagram to
		// a departed peer silenced the socket for every other peer too.
		//
		// A connectionless socket has no connection to lose: the datagram the
		// error complains about is already gone, and nothing about the socket
		// has changed. Measured before the fix, a socket that had just
		// completed an exchange stopped receiving entirely.
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

	public function testBufferSizesCanBeReadAndAskedFor():Void {
		if (!requireDatagramSupport()) return;

		#if hl
		// HashLink has no native to read or size a socket's buffers, so they
		// read 0 there, as documented, and there is no size to check.
		var unsized = new DatagramSocket();
		unsized.bind(0, "127.0.0.1");
		Assert.equals(0, unsized.receiveBufferSize);
		Assert.equals(0, unsized.sendBufferSize);
		unsized.close();
		return;
		#end

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

		At most 64 datagrams were read each time the socket was reported
		readable, and that is once a pass, so a socket could take in no more
		than 64 a pass whatever was arriving -- 3,840 a second at 60 passes --
		and the rest waited in, then overflowed, the kernel's buffer.
	**/
	public function testABurstIsTakenInOnOnePass():Void {
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var sender = new DatagramSocket();
		var received:Int = 0;
		var count:Int = 150;

		try {
			receiver.receiveBufferSize = 1024 * 1024;
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
