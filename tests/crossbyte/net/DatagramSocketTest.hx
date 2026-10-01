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

	/**
		There is no read timeout to set. A datagram socket never blocks,
		every read waits on the registry's poll, and Node's socket has no
		timeout at all, so the one `timeout` set on the socket underneath
		had nothing to time, on any target. It went rather than stay a
		setting that changed nothing.
	**/
	public function testThereIsNoReadTimeoutToSet():Void {
		var fields:Array<String> = Type.getInstanceFields(DatagramSocket);
		Assert.isTrue(fields.indexOf("bind") >= 0, "the class's fields cannot be read here: " + fields.length);
		for (name in ["timeout", "get_timeout", "set_timeout"]) {
			Assert.equals(-1, fields.indexOf(name), name + " is still there");
		}
	}

	/**
		A port one datagram socket holds is not given to another. hxcpp set
		SO_REUSEADDR on every socket it bound, and on Linux two datagram
		sockets that both set it may share a port: a bind to port 0 handed out
		ports already in use, 25 of a thousand game clients over reliable
		UDP shared one with another client, and never connected, and any
		local process could bind a server's port as well. Fixed in hxcpp's
		socket_bind (the fork's production); Windows never set it. The other
		sys runtimes' own binds still do, and Node's is asynchronous.
	**/
	public function testAPortHeldIsNotGivenToAnother():Void {
		#if (cpp || jvm)
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
		A socket's own address is asked of the system once, and kept while
		nothing can change it. Every read of `localAddress` or `localPort` was a
		getsockname() call, and a reliable session reads both for every message
		it hands over, two system calls a message, an eighth of a game
		server's time at a thousand clients.
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
		datagram that carried it. Datagram payloads came big-endian, where a
		ByteArray an application makes, and every other CrossByte socket, is
		little-endian, so a message built with `new ByteArray()` arrived with
		its integers byte-swapped.
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

		// Sending to an address the socket cannot reach, here an IPv6
		// destination from a socket bound to IPv4, fails at the `sendto`, and
		// is supposed to. What must not follow is the socket going deaf.
		//
		// It did. `send` routed the failure into __dispatchIoError, which calls
		// stopReceiving, so one unroutable destination stopped every other peer
		// being heard from, permanently, and with nothing to say why. ICE
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
		// __dispatchIoError, which calls stopReceiving(), so one datagram to
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

	/**
		Where buffers cannot be sized, the socket says so rather than taking
		the size and dropping it.

		HashLink and Neko have UDP and no native for either socket option.
		Setting a size there did nothing, silently, and it read 0, so a caller
		sizing its buffers for a burst could not tell that it had not. It
		throws now, and `bufferSizeSupported` is how a caller asks first.
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

		At most 64 datagrams were read each time the socket was reported
		readable, and that is once a pass, so a socket could take in no more
		than 64 a pass whatever was arriving, 3,840 a second at 60 passes,
		and the rest waited in, then overflowed, the kernel's buffer.
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
		loop, and the registry asks it once a pass: a runtime polled once a
		frame, the DEFAULT loop, or a host's pump, took no more than
		1,024 a frame, 12,288 a second at twelve ticks, however many were
		arriving, and the rest overflowed the kernel's buffer.
	**/
	public function testDatagramsPastOnePassesShareAreReadInTheSameFrame():Void {
		#if (cpp || jvm)
		if (!requireDatagramSupport()) return;

		var receiver = new DatagramSocket();
		var flood = new FloodUdpSocket();
		var sender = new DatagramSocket();
		var received:Int = 0;

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

	override public function readFrom(buf:haxe.io.Bytes, pos:Int, len:Int, addr:sys.net.Address):Int {
		if (remaining <= 0) {
			return super.readFrom(buf, pos, len, addr);
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
