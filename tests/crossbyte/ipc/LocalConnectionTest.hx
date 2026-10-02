package crossbyte.ipc;

import crossbyte.core.CrossByte;
import crossbyte.events.TickEvent;
import crossbyte.events.UncaughtErrorEvent;
import crossbyte.io.ByteArray;
import crossbyte.utils.Logger;
import crossbyte.net.NetConnection;
import crossbyte.net.Protocol;
import haxe.io.Bytes;
import utest.Assert;

@:access(crossbyte.ipc.LocalConnection)
@:access(crossbyte.core.CrossByte)
class LocalConnectionTest extends utest.Test {
	public function testSupportFlagMatchesTarget():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(LocalConnection.isSupported);
		#else
		Assert.isFalse(LocalConnection.isSupported);
		#end
	}

	public function testListenAndConnectThrowOnUnsupportedTargets():Void {
		#if (cpp && (windows || linux || mac || macos))
		Assert.isTrue(LocalConnection.isSupported);
		#else
		var server = new LocalConnection();
		var client = new LocalConnection();
		Assert.raises(() -> server.listen("__crossbyte_test__"), crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> client.connect("__crossbyte_test__"), crossbyte.errors.IllegalOperationError);
		#end
	}

	public function testRoundTripBytesThroughLocalTransport():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("roundtrip");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:String = null;
		var readyCount = 0;

		try {
			server.onReady = () -> readyCount++;
			server.onData = input -> received = input.readUTFBytes(input.length);
			server.readEnabled = true;
			server.listen(name);

			client.onReady = () -> readyCount++;
			client.connect(name);

			// Waits for what the assertions below actually check. `connected`
			// flips before the ready callbacks have been dispatched, they are
			// queued onto the runtime tick when they cannot run inline, so
			// waiting on it alone let the send go out against a half-ready pair
			// and left readyCount at 1 with nothing delivered.
			pumpUntil(() -> readyCount == 2 && server.connected && client.connected, 2.0);
			client.send(bytesOf("hello local"));
			pumpUntil(() -> received != null, 2.0);

			Assert.equals(2, readyCount);
			Assert.equals("hello local", received);
			Assert.equals(Protocol.LOCAL, server.protocol);
			Assert.equals(Protocol.LOCAL, client.protocol);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(server);
		#else
		Assert.pass();
		#end
	}

	public function testReadyAndDataArriveWhileTheRuntimesListenersChange():Void {
		// The reader thread attached the tick listener that carries its
		// dispatches to this thread, and EventDispatcher is not thread-safe:
		// an attach that met a listener change made here was lost, and the
		// listening side then never saw onReady nor anything sent to it. Here
		// the listeners change as fast as this thread can change them, the way
		// timers and sockets change them all the time.
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var kept:TickEvent->Void = _ -> {};
		var churn:TickEvent->Void = _ -> {};
		runtime.addEventListener(TickEvent.TICK, kept);
		var lost:Array<String> = [];

		for (round in 0...40) {
			var server = new LocalConnection();
			var client = new LocalConnection();
			var ready = false;
			var received:String = null;
			try {
				var name = uniqueName("churn");
				server.onReady = () -> ready = true;
				server.onData = input -> received = input.readUTFBytes(input.length);
				server.readEnabled = true;
				server.listen(name);
				client.connect(name);
				client.send(bytesOf('round $round'));

				var deadline = haxe.Timer.stamp() + 2.0;
				while ((!ready || received == null) && haxe.Timer.stamp() < deadline) {
					for (_ in 0...200) {
						runtime.addEventListener(TickEvent.TICK, churn);
						runtime.removeEventListener(TickEvent.TICK, churn);
					}
					runtime.pump(1 / 60, 0);
				}
				if (!ready || received != 'round $round') {
					lost.push('round $round: ready=$ready received=$received');
				}
			} catch (e:Dynamic) {
				lost.push('round $round threw $e');
			}
			closeQuietly(client);
			closeQuietly(server);
		}

		runtime.removeEventListener(TickEvent.TICK, kept);
		Assert.equals(0, lost.length, lost.join("; "));
		#else
		Assert.pass();
		#end
	}

	public function testAConnectionWhosePeerWentAwayIsLetGoOfByTheRuntime():Void {
		// The runtime holds nothing of a connection whose peer went away. It
		// delivered through a tick listener, which had to come off again when
		// the connection ended; it delivers through posts to the runtime now,
		// which leave nothing behind, and this stays to say so.
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var before = tickListeners(runtime);
		var name = uniqueName("peergone");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var readyCount = 0;
		var closed = false;

		try {
			server.onReady = () -> readyCount++;
			client.onReady = () -> readyCount++;
			client.onClose = _ -> closed = true;
			server.listen(name);
			client.connect(name);
			pumpUntil(() -> readyCount == 2, 2.0);
			Assert.equals(2, readyCount);

			server.close();
			pumpUntil(() -> closed && tickListeners(runtime) == before, 2.0);

			Assert.isTrue(closed, "the client was not told its peer went away");
			Assert.equals(before, tickListeners(runtime), "the runtime still holds a connection whose peer went away");
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		#else
		Assert.pass();
		#end
	}

	public function testAConnectionListenedOrConnectedAgainKeepsOneReader():Void {
		// listen() and connect() begin with close(), and the reader thread of
		// the session that ends sleeps between polls: it woke to find the
		// connection running again and carried on beside the new session's
		// reader. Two threads read one pipe, splitting its bytes, and tearing
		// the connection down when the read that lost found nothing, and the
		// old one's teardown closed the new session's pipes.
		#if (cpp && (windows || linux || mac || macos))
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:Array<String> = [];
		var expected:Array<String> = [];
		var problems:Array<String> = [];
		server.readEnabled = true;
		server.onData = input -> received.push(input.readUTFBytes(input.length));
		server.onError = reason -> problems.push('server error: $reason');
		client.onError = reason -> problems.push('client error: $reason');

		try {
			for (round in 0...20) {
				var name = uniqueName("again");
				server.listen(name);
				client.connect(name);
				pumpUntil(() -> server.connected, 2.0);
				if (!server.connected) {
					problems.push('round $round: never connected');
					break;
				}
				for (i in 0...10) {
					var message = 'round $round message $i';
					expected.push(message);
					client.send(bytesOf(message));
				}
				pumpUntil(() -> received.length >= expected.length, 2.0);
			}
		} catch (e:Dynamic) {
			problems.push('threw $e');
		}

		closeQuietly(client);
		closeQuietly(server);
		Assert.equals(0, problems.length, problems.join("; "));
		Assert.same(expected, received);
		#else
		Assert.pass();
		#end
	}

	public function testPendingReadsFlushWhenReadEnabledBecomesTrue():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("buffered");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:String = null;

		var readyCount = 0;

		try {
			server.onReady = () -> readyCount++;
			server.onData = input -> received = input.readUTFBytes(input.length);
			server.readEnabled = false;
			server.listen(name);

			client.onReady = () -> readyCount++;
			client.connect(name);

			// Both ends ready, not merely connected: `connected` flips before
			// the ready callbacks are dispatched, and a send against a
			// half-ready pair is lost with nothing to say so. That is what made
			// the round-trip case above fail intermittently.
			pumpUntil(() -> readyCount == 2 && server.connected && client.connected, 2.0);
			client.send(bytesOf("deferred"));
			pumpUntil(() -> true, 0.05);
			Assert.isNull(received);

			server.readEnabled = true;
			pumpUntil(() -> received != null, 2.0);
			Assert.equals("deferred", received);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(server);
		#else
		Assert.pass();
		#end
	}

	public function testAConnectionMadeFromAUrlIsToldItIsReady():Void {
		// `new NetConnection("local://...")` connects as it is made, and
		// connect() dispatched Ready from inside itself: an onReady set once
		// the constructor had returned, as the RPC guide sets one, never ran.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("url");
		var server = new LocalConnection();
		var connection:NetConnection = null;
		try {
			server.listen(name);
			connection = new NetConnection('local://$name');
			var ready = false;
			connection.onReady = () -> ready = true;
			pumpUntil(() -> ready, 2.0);
			Assert.isTrue(ready, "onReady set after the connection was made never ran");
		} catch (e:Dynamic) {
			if (connection != null) {
				connection.close();
			}
			closeQuietly(server);
			throw e;
		}
		connection.close();
		closeQuietly(server);
		#else
		Assert.pass();
		#end
	}

	public function testSendDoesNotWaitForAPeerThatIsNotReading():Void {
		// send() wrote until all of it was gone, on the runtime's thread: five
		// seconds a send on Windows, and for good elsewhere, to a peer that
		// had stopped reading. What the channel does not take is queued now,
		// and a peer that leaves more than maxQueuedBytes unread is closed,
		// with an error that says so.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("stuck");
		var peer = LocalConnection.__createInboundPipe(name);
		var client = new LocalConnection();
		var errors:Array<String> = [];
		var closed = false;
		var closedWith:String = null;
		client.onError = reason -> errors.push(Std.string(reason));
		client.onClose = reason -> {
			closed = true;
			closedWith = Std.string(reason);
		};
		var slowest = 0.0;
		var sends = 0;

		try {
			Assert.notNull(peer, "the peer did not listen");
			client.connect(name);
			var acceptBy = haxe.Timer.stamp() + 2.0;
			while (!LocalConnection.__accept(peer) && haxe.Timer.stamp() < acceptBy) {
				crossbyte.sys.System.sleep(0.001);
			}
			var frame = new ByteArray();
			frame.length = 1024 * 1024;
			var began = haxe.Timer.stamp();
			while (client.connected && sends < 40 && haxe.Timer.stamp() - began < 3.0) {
				var started = haxe.Timer.stamp();
				client.send(frame);
				var took = haxe.Timer.stamp() - started;
				if (took > slowest) {
					slowest = took;
				}
				sends++;
			}
			pumpUntil(() -> closed, 1.0);
		} catch (e:Dynamic) {
			closeQuietly(client);
			LocalConnection.__close(peer);
			throw e;
		}

		closeQuietly(client);
		LocalConnection.__close(peer);
		Assert.isTrue(slowest < 0.25, 'a send waited ${slowest}s for a peer that was not reading');
		Assert.isFalse(client.connected, 'still connected after $sends sends of 1 MB that nobody read');
		Assert.isTrue(closed, "the connection was not closed");
		Assert.isTrue(closedWith != null && closedWith.indexOf("not reading") >= 0, 'it was closed with $closedWith');
		Assert.isTrue(errors.filter(error -> error.indexOf("not reading") >= 0).length > 0, 'no error said the peer was not reading: $errors');
		#else
		Assert.pass();
		#end
	}

	/**
		A connect to a listener that takes nobody ends at its deadline. On
		Linux a connect to a listener whose backlog was full waited in the
		kernel for it to take someone, past any `timeout`, on the calling
		thread: a listener hung, or simply busy, held every client's runtime
		for good. The connects run on a thread of their own, so a wait that
		never ends fails the case instead of the run.
	**/
	@:timeout(60000)
	public function testAConnectToAListenerTakingNobodyEndsAtItsDeadline():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("backlog");
		var peer = LocalConnection.__createInboundPipe(name);
		var results = new sys.thread.Deque<String>();
		var finished = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			var slowest = 0.0;
			// Past any backlog: Linux queues 17 for a listen(16), macOS 16
			// and Windows' one instance one. A client closed at once still
			// holds its place until the listener takes it.
			for (_ in 0...40) {
				var started = haxe.Timer.stamp();
				var handle = LocalConnection.__connect(name, 300);
				var took = haxe.Timer.stamp() - started;
				if (took > slowest) {
					slowest = took;
				}
				if (handle != null) {
					LocalConnection.__close(handle);
				}
			}
			results.add('$slowest');
			finished.release();
		});

		var ended = finished.wait(30.0);
		LocalConnection.__close(peer);
		if (!ended) {
			// Closing the listener ends a connect still waiting on it.
			finished.wait(10.0);
		}
		Assert.isTrue(ended, "a connect to a listener taking nobody never ended");
		var slowest:Null<String> = results.pop(false);
		if (slowest != null) {
			Assert.isTrue(Std.parseFloat(slowest) < 2.0, 'a connect with a 300 ms timeout took ${slowest}s');
		}
		#else
		Assert.pass();
		#end
	}

	public function testTwoSidesSendingAtOnceDoNotWaitOnEachOther():Void {
		// Each side's send held its own lock while it waited for the other to
		// read, and its reader needed that lock to read: two sides filling each
		// other's channels at once each waited on the other, five seconds a
		// send on Windows, and for good elsewhere, and a write that gave up
		// part way through a frame left the other side reading from the middle
		// of it.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("both");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var toServer:Array<Int> = [];
		var toClient:Array<Int> = [];
		var problems:Array<String> = [];
		var readyCount = 0;
		var frames = 4;
		var size = 512 * 1024;
		server.readEnabled = true;
		client.readEnabled = true;
		server.onData = input -> toServer.push(numberOf(input, size));
		client.onData = input -> toClient.push(numberOf(input, size));
		server.onError = reason -> problems.push('server: $reason');
		client.onError = reason -> problems.push('client: $reason');
		server.onReady = () -> readyCount++;
		client.onReady = () -> readyCount++;
		var took = 0.0;
		var bothSent = false;

		try {
			server.listen(name);
			client.connect(name);
			pumpUntil(() -> readyCount == 2, 2.0);
			Assert.equals(2, readyCount);

			var finished = new sys.thread.Lock();
			var began = haxe.Timer.stamp();
			sys.thread.Thread.create(() -> {
				for (i in 0...frames) {
					server.send(numbered(i, size));
				}
				finished.release();
			});
			for (i in 0...frames) {
				client.send(numbered(i, size));
			}
			bothSent = finished.wait(30.0);
			took = haxe.Timer.stamp() - began;
			pumpUntil(() -> toServer.length >= frames && toClient.length >= frames, 5.0);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(server);
		var expected = [for (i in 0...frames) i];
		Assert.isTrue(bothSent, "the other side's sends never finished");
		Assert.isTrue(took < 1.0, 'sending took ${took}s');
		Assert.same(expected, toServer);
		Assert.same(expected, toClient);
		Assert.equals(0, problems.length, problems.join("; "));
		#else
		Assert.pass();
		#end
	}

	public function testFramesLargerThanTheChannelArriveWhole():Void {
		// Each is written as far as the channel takes it and the rest queued,
		// from where it stopped.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("large");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:Array<Int> = [];
		var readyCount = 0;
		var size = 3 * 1024 * 1024;
		server.readEnabled = true;
		server.onData = input -> received.push(input.length == 5 ? -2 : numberOf(input, size));
		server.onReady = () -> readyCount++;
		client.onReady = () -> readyCount++;

		try {
			server.listen(name);
			client.connect(name);
			pumpUntil(() -> readyCount == 2, 2.0);
			for (i in 0...3) {
				client.send(numbered(i, size));
			}
			client.send(bytesOf("after"));
			pumpUntil(() -> received.length >= 4, 10.0);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(server);
		Assert.same([0, 1, 2, -2], received);
		#else
		Assert.pass();
		#end
	}

	public function testManyMessagesAreDeliveredInATick():Void {
		// Thirty-two a tick were delivered, whatever they cost: 384 a second
		// at 12 ticks a second, and anything faster waited in a queue with no
		// bound. Delivery is by time now.
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var name = uniqueName("many");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:Array<String> = [];
		var readyCount = 0;
		var count = 2000;
		server.readEnabled = true;
		server.onData = input -> received.push(input.readUTFBytes(input.length));
		server.onReady = () -> readyCount++;
		client.onReady = () -> readyCount++;
		var afterOneTick = 0;

		try {
			server.listen(name);
			client.connect(name);
			pumpUntil(() -> readyCount == 2, 2.0);
			for (i in 0...count) {
				client.send(bytesOf('m$i'));
			}
			// The reader takes them in meanwhile, with the runtime not ticking.
			crossbyte.sys.System.sleep(0.3);
			runtime.pump(1 / 60, 0);
			afterOneTick = received.length;
			pumpUntil(() -> received.length >= count, 5.0);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(server);
		Assert.isTrue(afterOneTick > 256, 'one tick delivered $afterOneTick of $count');
		Assert.same([for (i in 0...count) 'm$i'], received);
		#else
		Assert.pass();
		#end
	}

	public function testAReceiverThatFallsBehindStopsTakingData():Void {
		// Everything that arrived was read and queued for the runtime, however
		// far behind it was, so a sender faster than the application grew this
		// process without bound. Past maxQueuedBytes waiting to be delivered
		// the reader stops, and the sender's data waits on its own side.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("behind");
		var server = new LocalConnection();
		var client = new LocalConnection();
		var received:Array<Int> = [];
		var readyCount = 0;
		var size = 256 * 1024;
		server.maxQueuedBytes = 1024 * 1024;
		server.readEnabled = true;
		server.onData = input -> received.push(numberOf(input, size));
		server.onReady = () -> readyCount++;
		client.onReady = () -> readyCount++;
		var sent = 0;
		var held = 0;

		try {
			server.listen(name);
			client.connect(name);
			pumpUntil(() -> readyCount == 2, 2.0);
			// Paced as a sender should be, and without the runtime delivering
			// anything meanwhile.
			var began = haxe.Timer.stamp();
			while (sent < 64 && haxe.Timer.stamp() - began < 2.0) {
				if (client.bytesPending > 512 * 1024) {
					crossbyte.sys.System.sleep(0.001);
					continue;
				}
				client.send(numbered(sent, size));
				sent++;
			}
			held = server.__inQueued;
			pumpUntil(() -> received.length >= sent, 5.0);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(server);
			throw e;
		}

		var stillConnected = client.connected;
		closeQuietly(client);
		closeQuietly(server);
		Assert.isTrue(sent < 16, 'the receiver took in $sent frames of 256 KB with none delivered');
		Assert.isTrue(held <= 1024 * 1024 + 2 * size, 'the receiver held $held bytes for delivery');
		Assert.isTrue(stillConnected, "a sender that paced itself was cut off");
		Assert.same([for (i in 0...sent) i], received);
		#else
		Assert.pass();
		#end
	}

	public function testSendingToAPeerThatHasGoneEndsTheConnectionNotTheProcess():Void {
		// On POSIX a send to a peer that had gone raised SIGPIPE, which ends
		// the process. send() looked first, and a peer that had simply gone
		// looked closed; one that said something before it went looked open
		// until that was read, and the send went ahead.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("gone");
		var peer = LocalConnection.__createInboundPipe(name);
		var client = new LocalConnection();
		var closed = false;
		client.onClose = _ -> closed = true;

		try {
			Assert.notNull(peer, "the peer did not listen");
			client.connect(name);
			var acceptBy = haxe.Timer.stamp() + 2.0;
			while (!LocalConnection.__accept(peer) && haxe.Timer.stamp() < acceptBy) {
				crossbyte.sys.System.sleep(0.001);
			}
			var parting = new ByteArray();
			parting.writeInt(3);
			parting.writeUTFBytes("bye");
			LocalConnection.__write(peer, (cast parting : Bytes).getData(), parting.length);
			LocalConnection.__close(peer);
			// At once, while what the peer said is still unread here.
			for (_ in 0...200) {
				if (!client.connected) {
					break;
				}
				client.send(bytesOf("anyone there?"));
			}
			var deadline = haxe.Timer.stamp() + 2.0;
			while (client.connected && haxe.Timer.stamp() < deadline) {
				client.send(bytesOf("anyone there?"));
				pumpUntil(() -> false, 0.005);
			}
			pumpUntil(() -> closed, 1.0);
		} catch (e:Dynamic) {
			closeQuietly(client);
			throw e;
		}

		closeQuietly(client);
		Assert.isFalse(client.connected, "a connection whose peer went is still connected");
		Assert.isTrue(closed, "a connection whose peer went was not closed");
		#else
		Assert.pass();
		#end
	}

	public function testASecondListenerOnANameInUseIsRefused():Void {
		// Windows made a second instance of the pipe beside the first, and
		// POSIX removed the first's socket file and bound its own: either way
		// listen() said nothing, and the first listener's clients went to the
		// second.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("taken");
		var first = new LocalConnection();
		var second = new LocalConnection();
		var client = new LocalConnection();
		var firstGot:String = null;
		var secondGot:String = null;
		first.readEnabled = true;
		second.readEnabled = true;
		first.onData = input -> firstGot = input.readUTFBytes(input.length);
		second.onData = input -> secondGot = input.readUTFBytes(input.length);
		var refused = false;

		try {
			first.listen(name);
			refused = throws(() -> second.listen(name));
			client.connect(name);
			pumpUntil(() -> first.connected || second.connected, 2.0);
			client.send(bytesOf("for the first"));
			pumpUntil(() -> firstGot != null || secondGot != null, 2.0);
		} catch (e:Dynamic) {
			closeQuietly(client);
			closeQuietly(second);
			closeQuietly(first);
			throw e;
		}

		closeQuietly(client);
		closeQuietly(second);
		closeQuietly(first);
		Assert.isTrue(refused, "a second listen() on a name in use was not refused");
		Assert.isNull(secondGot, "the second listener took the first's client");
		Assert.equals("for the first", firstGot);
		#else
		Assert.pass();
		#end
	}

	public function testAClientThatWritesAndLeavesBeforeItIsTakenIsHeard():Void {
		// On Windows a client that had come and gone before the listener next
		// looked left the pipe closing: ConnectNamedPipe answered ERROR_NO_DATA,
		// which was taken for "nobody yet", and the listener took nobody again.
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("brief");
		var server = new LocalConnection();
		var later = new LocalConnection();
		var received:Array<String> = [];
		server.readEnabled = true;
		server.onData = input -> received.push(input.readUTFBytes(input.length));

		try {
			server.listen(name);
			// Idle, the listener looks every few milliseconds; the client below
			// is gone within microseconds.
			crossbyte.sys.System.sleep(0.05);
			var brief = LocalConnection.__connect(name, 2000);
			Assert.notNull(brief, "the brief client did not connect");
			var frame = new ByteArray();
			frame.writeInt(5);
			frame.writeUTFBytes("brief");
			LocalConnection.__write(brief, (cast frame : Bytes).getData(), frame.length);
			LocalConnection.__close(brief);
			pumpUntil(() -> received.length >= 1, 2.0);

			later.connect(name);
			pumpUntil(() -> server.connected, 2.0);
			later.send(bytesOf("later"));
			pumpUntil(() -> received.length >= 2, 2.0);
		} catch (e:Dynamic) {
			closeQuietly(later);
			closeQuietly(server);
			throw e;
		}

		closeQuietly(later);
		closeQuietly(server);
		Assert.same(["brief", "later"], received);
		#else
		Assert.pass();
		#end
	}

	public function testNamesAlikeUpToPunctuationOrLengthAreDifferentChannels():Void {
		// POSIX made a name's socket path by turning everything but letters,
		// digits, '-' and '_' into '_', and cutting it to 48 characters: "a.b"
		// and "a_b", or two long names alike for their first 48, were one
		// channel.
		#if (cpp && (windows || linux || mac || macos))
		var base = uniqueName("alike");
		var long = base + "_" + [for (_ in 0...60) "x"].join("");
		var problems:Array<String> = [];
		for (pair in [[base + ".dot", base + "_dot"], [long + "1", long + "2"]]) {
			var a = new LocalConnection();
			var b = new LocalConnection();
			var toA = new LocalConnection();
			var toB = new LocalConnection();
			var gotA:String = null;
			var gotB:String = null;
			a.readEnabled = true;
			b.readEnabled = true;
			a.onData = input -> gotA = input.readUTFBytes(input.length);
			b.onData = input -> gotB = input.readUTFBytes(input.length);
			try {
				a.listen(pair[0]);
				if (throws(() -> b.listen(pair[1]))) {
					problems.push('${pair[1]} was refused as in use by ${pair[0]}');
				} else {
					toA.connect(pair[0]);
					toB.connect(pair[1]);
					pumpUntil(() -> a.connected && b.connected, 2.0);
					toA.send(bytesOf("to a"));
					toB.send(bytesOf("to b"));
					pumpUntil(() -> gotA != null && gotB != null, 2.0);
					if (gotA != "to a" || gotB != "to b") {
						problems.push('${pair[0]} got $gotA and ${pair[1]} got $gotB');
					}
				}
			} catch (e:Dynamic) {
				problems.push('${pair[0]}: threw $e');
			}
			closeQuietly(toA);
			closeQuietly(toB);
			closeQuietly(a);
			closeQuietly(b);
		}
		Assert.equals(0, problems.length, problems.join("; "));
		#else
		Assert.pass();
		#end
	}

	/**
		A callback that throws is reported as a socket handler's failure is,
		logged, and dispatched as `UncaughtErrorEvent.UNCAUGHT_ERROR`, and,
		as before, ends the connection and is told to `onError`. With no
		`onError` set it went without a word, and so did whatever `onClose`
		threw as `close()` called it.
	**/
	public function testACallbackThatThrowsIsReported():Void {
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var reports:Array<UncaughtErrorEvent> = [];
		var watch = (event:UncaughtErrorEvent) -> reports.push(event);
		runtime.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, watch);
		Logger.sink = _ -> {};
		var name = uniqueName("throws");
		var server = new LocalConnection();
		var client = new LocalConnection();

		var leaving = new LocalConnection();

		try {
			server.readEnabled = true;
			server.listen(name);
			// onClose, as close() calls it.
			leaving.connect(name);
			pumpUntil(() -> server.connected, 2.0);
			leaving.onClose = _ -> throw "close bug";
			leaving.close();
			pumpUntil(() -> !server.connected, 2.0);

			// onData, as the runtime delivers what arrived.
			server.onData = _ -> throw "data bug";
			client.connect(name);
			pumpUntil(() -> server.connected, 2.0);
			client.send(bytesOf("anything"));
			pumpUntil(() -> reports.length >= 2, 2.0);
		} catch (e:Dynamic) {
			Assert.fail("a callback's failure escaped: " + e);
		}

		Logger.sink = null;
		runtime.removeEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, watch);
		closeQuietly(leaving);
		closeQuietly(client);
		closeQuietly(server);
		Assert.equals(2, reports.length, "reported: " + [for (report in reports) Std.string(report.error)]);
		if (reports.length == 2) {
			Assert.equals("close bug", Std.string(reports[0].error));
			Assert.equals(leaving, reports[0].origin);
			Assert.equals("data bug", Std.string(reports[1].error));
			Assert.equals(UncaughtErrorEvent.SOCKET, reports[1].source);
			Assert.equals(server, reports[1].origin);
		}
		Assert.isFalse(server.connected, "the connection whose callback threw is still open");
		#else
		Assert.pass();
		#end
	}

	/**
		`timeout = 0` means no deadline, as it does on every connect: the
		connect waits, on the calling thread, until something listens on the
		name. It made one try and gave up at once.
	**/
	@:timeout(30000)
	public function testATimeoutOfZeroWaitsForTheListenerWithoutADeadline():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("nodeadline");
		var listening = LateListener.start(name, 0.4);
		var client = new LocalConnection();
		client.timeout = 0;
		var started = haxe.Timer.stamp();
		var raised:Dynamic = null;
		try {
			client.connect(name);
		} catch (e:Dynamic) {
			raised = e;
		}
		var waited = haxe.Timer.stamp() - started;
		var connected = client.connected;
		closeQuietly(client);
		listening.stop();

		Assert.isNull(raised, 'connect() with no deadline gave up after $waited s: $raised');
		Assert.isTrue(connected, "connect() returned without a connection");
		Assert.isTrue(waited >= 0.3, 'connect() returned after $waited s, before anything listened');
		#else
		Assert.pass();
		#end
	}

	/** A deadline still ends the wait: the connect fails once it passes, and not before. **/
	@:timeout(30000)
	public function testATimeoutEndsTheWaitForAListener():Void {
		#if (cpp && (windows || linux || mac || macos))
		var client = new LocalConnection();
		client.timeout = 300;
		var started = haxe.Timer.stamp();
		var raised:Dynamic = null;
		try {
			client.connect(uniqueName("nobody"));
		} catch (e:Dynamic) {
			raised = e;
		}
		var waited = haxe.Timer.stamp() - started;
		closeQuietly(client);

		Assert.isTrue(Std.isOfType(raised, crossbyte.errors.ArgumentError), "connect() to a name nobody listens on threw " + raised);
		Assert.isTrue(waited >= 0.2 && waited < 5, 'connect() gave up after $waited s');
		#else
		Assert.pass();
		#end
	}

	/** The argument that runs the native suite's binary as `crossProcessChild`. **/
	public static inline var CHILD:String = "--crossbyte-child=localconnection";

	/**
		Another process of this user's meets this one over a name, both ways:
		a name being the user's own, a directory only the user can enter on
		Linux and macOS, a pipe only the user can open on Windows, keeps out
		other users, not the user's other processes. The child is this suite's
		own binary, run again: it connects, says so, and waits for an answer.
	**/
	@:timeout(60000)
	public function testAnotherProcessOfThisUserMeetsItOverAName():Void {
		#if (cpp && (windows || linux || mac || macos))
		var name = uniqueName("child");
		var server = new LocalConnection();
		var heard:String = null;
		server.readEnabled = true;
		server.onData = input -> {
			heard = input.readUTFBytes(input.length);
			server.send(bytesOf("from the parent"));
		};
		var code:Null<Int> = null;
		var output = "";
		try {
			server.listen(name);
			var child = new sys.io.Process(Sys.programPath(), [CHILD, name]);
			var deadline = haxe.Timer.stamp() + 30.0;
			while (code == null && haxe.Timer.stamp() < deadline) {
				pumpUntil(() -> false, 0.02);
				code = child.exitCode(false);
			}
			if (code == null) {
				child.kill();
			}
			output = child.stdout.readAll().toString();
			child.close();
		} catch (e:Dynamic) {
			Assert.fail("threw " + e);
		}
		closeQuietly(server);

		Assert.equals("from the child", heard, "the parent did not hear the child: " + output);
		Assert.equals(0, code, "the child did not hear the parent: " + output);
		#else
		Assert.pass();
		#end
	}

	/**
		The child's side of testAnotherProcessOfThisUserMeetsItOverAName:
		connects to `name`, sends, and exits 0 once answered, or with a code
		saying where it stopped.
	**/
	public static function crossProcessChild(name:String):Void {
		#if (cpp && (windows || linux || mac || macos))
		var runtime = new CrossByte(false, DEFAULT, true);
		var connection = new LocalConnection();
		var answer:String = null;
		connection.readEnabled = true;
		connection.onData = input -> answer = input.readUTFBytes(input.length);
		try {
			connection.connect(name);
		} catch (e:Dynamic) {
			Sys.println("child: connect threw " + e);
			Sys.exit(2);
		}
		connection.send(bytesOf("from the child"));
		var deadline = haxe.Timer.stamp() + 10.0;
		while (answer == null && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.005);
		}
		connection.close();
		runtime.exit();
		Sys.println("child: answered " + answer);
		Sys.exit(answer == "from the parent" ? 0 : 3);
		#end
	}

	/**
		Two listeners racing for one name leave exactly one listening, and a
		client reaches it. Each pair starts on threads of their own, released
		together, forty times over.
	**/
	@:timeout(60000)
	public function testListenersRacingForANameLeaveOneListening():Void {
		#if (cpp && (windows || linux || mac || macos))
		var problems:Array<String> = [];
		for (round in 0...40) {
			var name = uniqueName("race");
			var ready = new sys.thread.Lock();
			var go = new sys.thread.Lock();
			var results = new sys.thread.Deque<LocalConnection>();
			for (_ in 0...2) {
				sys.thread.Thread.create(() -> {
					var server = new LocalConnection();
					ready.release();
					go.wait();
					try {
						server.listen(name);
						results.add(server);
					} catch (_:Dynamic) {
						results.add(null);
					}
				});
			}
			ready.wait();
			ready.wait();
			go.release();
			go.release();
			var listening:Array<LocalConnection> = [];
			for (_ in 0...2) {
				var server = results.pop(true);
				if (server != null) {
					listening.push(server);
				}
			}
			if (listening.length != 1) {
				problems.push('round $round: ${listening.length} listened');
			}
			var client = new LocalConnection();
			client.timeout = 2000;
			try {
				client.connect(name);
			} catch (e:Dynamic) {
				problems.push('round $round: no listener took the client: $e');
			}
			closeQuietly(client);
			for (server in listening) {
				closeQuietly(server);
			}
		}
		Assert.equals(0, problems.length, problems.join("; "));
		#else
		Assert.pass();
		#end
	}

	/**
		On Windows a listener's pipe admits this user and SYSTEM alone. It was
		made with the default security, which lets everyone read a pipe, the
		anonymous user included, so another local user could open it and
		take what the listener sent.
	**/
	public function testAPipeAdmitsNoneButItsUser():Void {
		#if (cpp && windows)
		var server = new LocalConnection();
		var admitsOthers = true;
		try {
			server.listen(uniqueName("acl"));
			admitsOthers = LocalConnection.__admitsOthersForTest(server.__listeningPipe);
		} catch (e:Dynamic) {
			Assert.fail("listen() threw " + e);
		}
		closeQuietly(server);
		Assert.isFalse(admitsOthers, "the pipe admits someone besides this user and SYSTEM, or another owns it");
		#else
		Assert.pass();
		#end
	}

	#if (cpp && (linux || mac || macos))
	/**
		A link put where a listener's lock file goes is not followed, and the
		name is not listened on. On Linux and macOS a listener holds its name
		by a lock on a file. It was in /tmp, where any user can put something
		first, and was opened following a link: another user's link there
		made this process make, or lock, a file wherever it pointed. The file
		is in this user's own directory now, where only this user can put a
		link, and one is still not followed.
	**/
	public function testALinkWhereTheListenersLockFileGoesIsNotFollowed():Void {
		var name = uniqueName("lnk");
		var lockPath = socketPathOf(name) + ".lock";
		var target = lockPath + ".target";
		Assert.equals(0, Sys.command("ln", ["-s", target, lockPath]), "could not make the link");
		var server = new LocalConnection();
		var refused = throws(() -> server.listen(name));
		closeQuietly(server);
		var followed = sys.FileSystem.exists(target);
		removeQuietly(lockPath);
		removeQuietly(target);

		Assert.isFalse(followed, "the link was followed: " + target + " was made");
		Assert.isTrue(refused, "a name whose lock file is a link was listened on");
	}

	/**
		Nor a FIFO, nor anything else that is not a regular file of this
		user's: a FIFO opened for reading and writing does not wait, and was
		locked and taken for the name's lock file.
	**/
	public function testAFifoWhereTheListenersLockFileGoesIsRefused():Void {
		var name = uniqueName("fifo");
		var lockPath = socketPathOf(name) + ".lock";
		Assert.equals(0, Sys.command("mkfifo", [lockPath]), "could not make the FIFO");
		var server = new LocalConnection();
		var refused = throws(() -> server.listen(name));
		closeQuietly(server);
		removeQuietly(lockPath);

		Assert.isTrue(refused, "a name whose lock file is a FIFO was listened on");
	}

	/**
		Listening brings the lock file's times up to date, as each hour of
		listening does, so a cleaner of old files in /tmp, macOS's takes
		what nobody has touched for three days, systemd's for ten, does not
		find a listener's old and delete it, which let a second listener
		take the name from the first.
	**/
	public function testListeningBringsTheLockFilesTimesUpToDate():Void {
		var name = uniqueName("fresh");
		var lockPath = socketPathOf(name) + ".lock";
		// Left by an earlier listener of this user's, four days ago.
		sys.io.File.saveContent(lockPath, "");
		Sys.command("chmod", ["600", lockPath]);
		var fourDaysAgo = Date.fromTime(Date.now().getTime() - 4 * 24 * 3600 * 1000.0);
		Assert.equals(0, Sys.command("touch", ["-t", DateTools.format(fourDaysAgo, "%Y%m%d%H%M"), lockPath]), "could not age the file");
		var aged:Float = sys.FileSystem.stat(lockPath).mtime.getTime();

		var server = new LocalConnection();
		var refreshed:Float = 0;
		try {
			server.listen(name);
			refreshed = sys.FileSystem.stat(lockPath).mtime.getTime();
		} catch (e:Dynamic) {
			Assert.fail("listen() threw " + e);
		}
		closeQuietly(server);
		removeQuietly(lockPath);

		Assert.isTrue(Date.now().getTime() - aged > 3 * 24 * 3600 * 1000.0, "the file was not aged");
		Assert.isTrue(Date.now().getTime() - refreshed < 3600 * 1000.0, "the lock file still looks old");
	}

	/**
		A link at the socket path is not followed: a connect that finds one
		is refused, not taken to wherever it points. The socket was in /tmp,
		where any user could put a link under a name first, and connect()
		followed it to their listener. The link here is planted where the
		name's socket goes in either layout, /tmp, and this user's own
		directory, where only this user could put one, and points at a
		listener on another name.
	**/
	public function testALinkAtTheSocketPathIsNotFollowed():Void {
		var directory = ensureUserDirectory();
		var decoy = uniqueName("decoy");
		var victim = uniqueName("victim");
		var listener = LocalConnection.__createInboundPipe(decoy);
		var links = [
			['/tmp/crossbyte_local_connection_$victim', '/tmp/crossbyte_local_connection_$decoy'],
			['$directory/$victim', '$directory/$decoy']
		];
		for (link in links) {
			Sys.command("ln", ["-s", link[1], link[0]]);
		}
		var client = new LocalConnection();
		client.timeout = 300;
		var raised:Dynamic = null;
		try {
			client.connect(victim);
		} catch (e:Dynamic) {
			raised = e;
		}
		var reached = client.connected;
		closeQuietly(client);
		for (link in links) {
			removeQuietly(link[0]);
		}
		if (listener != null) {
			LocalConnection.__close(listener);
		}

		Assert.isFalse(reached, "a link at the socket path took the client to another name's listener");
		Assert.isTrue(Std.isOfType(raised, crossbyte.errors.IOError), "a link at the socket path was not refused as not this user's: " + raised);
	}

	/**
		A directory for this user's names that others can enter is refused,
		by a listener and by a client alike: what is in it could be anyone's.
		The directory here is this user's own, made 0755 for the case and
		put back after; another process of this user's listening meanwhile
		is refused its clients for that moment.
	**/
	public function testADirectoryOthersCanEnterIsRefused():Void {
		var directory = ensureUserDirectory();
		var name = uniqueName("mode");
		Sys.command("chmod", ["755", directory]);
		var refusals = listenAndConnect(name);
		Sys.command("chmod", ["700", directory]);

		for (refusal in refusals) {
			Assert.isTrue(Std.isOfType(refusal, crossbyte.errors.IOError), "not refused as not this user's own: " + refusal);
			Assert.isTrue(Std.string(refusal).indexOf("not this user's own") >= 0, Std.string(refusal));
		}
	}

	/**
		A link where the directory goes is refused, not followed: it could
		lead anywhere. Made only while the directory is empty, so that no
		listener of this user's loses its socket; otherwise the case passes
		having checked nothing.
	**/
	public function testALinkInPlaceOfTheDirectoryIsRefused():Void {
		var directory = userDirectory();
		if (sys.FileSystem.exists(directory) && sys.FileSystem.readDirectory(directory).length > 0) {
			Assert.pass();
			return;
		}
		if (sys.FileSystem.exists(directory)) {
			sys.FileSystem.deleteDirectory(directory);
		}
		var elsewhere = directory + "-elsewhere-" + Std.random(1000000);
		Sys.command("mkdir", ["-m", "700", elsewhere]);
		Sys.command("ln", ["-s", elsewhere, directory]);
		var refusals = listenAndConnect(uniqueName("dirlnk"));
		removeQuietly(directory);
		Sys.command("rm", ["-rf", elsewhere]);
		Sys.command("mkdir", ["-m", "700", directory]);

		for (refusal in refusals) {
			Assert.isTrue(Std.isOfType(refusal, crossbyte.errors.IOError), "a link in place of the directory was not refused: " + refusal);
		}
	}

	/**
		A directory another user owns is refused. Needs root, to give the
		directory to another user for the moment; elsewhere the case passes
		having checked nothing.
	**/
	public function testADirectoryAnotherUserOwnsIsRefused():Void {
		var directory = ensureUserDirectory();
		// Nothing to give it to without root, nor when this user is nobody.
		if (Sys.command("chown", ["nobody", directory]) != 0 || Std.string(sys.FileSystem.stat(directory).uid) == userId()) {
			Assert.pass();
			return;
		}
		var refusals = listenAndConnect(uniqueName("theirs"));
		Sys.command("chown", [userId(), directory]);

		for (refusal in refusals) {
			Assert.isTrue(Std.isOfType(refusal, crossbyte.errors.IOError), "another user's directory was not refused: " + refusal);
		}
	}

	/** What `listen(name)` and then `connect(name)` threw, null for one that did not. **/
	private static function listenAndConnect(name:String):Array<Dynamic> {
		var thrown:Array<Dynamic> = [];
		var server = new LocalConnection();
		try {
			server.listen(name);
			thrown.push(null);
		} catch (e:Dynamic) {
			thrown.push(e);
		}
		closeQuietly(server);
		var client = new LocalConnection();
		client.timeout = 100;
		try {
			client.connect(name);
			thrown.push(null);
		} catch (e:Dynamic) {
			thrown.push(e);
		}
		closeQuietly(client);
		return thrown;
	}

	private static function userId():String {
		var process = new sys.io.Process("id", ["-u"]);
		var id = StringTools.trim(process.stdout.readAll().toString());
		process.close();
		return id;
	}

	/** Where this user's names live on Linux and macOS. **/
	private static function userDirectory():String {
		return "/tmp/crossbyte-" + userId();
	}

	/** userDirectory(), made 0700 if it is not there yet. **/
	private static function ensureUserDirectory():String {
		var directory = userDirectory();
		if (!sys.FileSystem.exists(directory)) {
			Sys.command("mkdir", ["-m", "700", directory]);
		}
		return directory;
	}

	/** The socket of `name`, a name of letters, digits, '_' and '-' and no more than 48 of them. **/
	private static function socketPathOf(name:String):String {
		return ensureUserDirectory() + "/" + name;
	}

	private static function removeQuietly(path:String):Void {
		try {
			sys.FileSystem.deleteFile(path);
		} catch (_:Dynamic) {}
	}
	#end

	public function testNetConnectionRoundTripKeepsLocalTransport():Void {
		var local = new LocalConnection();
		var wrapped:NetConnection = local;
		var restored:LocalConnection = NetConnection.toLocalConnection(wrapped);

		Assert.equals(Protocol.LOCAL, wrapped.protocol);
		Assert.equals(local, restored);
	}

	// `size` bytes: `id`, then a pattern that shifts with it, so a frame read
	// from its middle or cut short does not pass for one.
	private static function numbered(id:Int, size:Int):ByteArray {
		var bytes = Bytes.alloc(size);
		bytes.setInt32(0, id);
		for (i in 4...size) {
			bytes.set(i, (id + i) & 0xFF);
		}
		return ByteArray.fromBytes(bytes);
	}

	// The id of a frame made by `numbered`, or -1 if it is not one of `size`.
	private static function numberOf(input:crossbyte.io.ByteArrayInput, size:Int):Int {
		if (input.length != size) {
			return -1;
		}
		var bytes = Bytes.alloc(size);
		input.position = 0;
		input.readBytes(bytes, 0, size);
		var id = bytes.getInt32(0);
		for (i in 4...size) {
			if (bytes.get(i) != ((id + i) & 0xFF)) {
				return -1;
			}
		}
		return id;
	}

	private static function bytesOf(value:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(value);
		bytes.position = 0;
		return bytes;
	}

	private static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		#if (cpp && (windows || linux || mac || macos))
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
		#end
	}

	private static function tickListeners(runtime:CrossByte):Int {
		var map = @:privateAccess runtime.__eventMap;
		var listeners:Array<Dynamic> = map == null ? null : cast map.get(TickEvent.TICK);
		return listeners == null ? 0 : listeners.length;
	}

	private static function closeQuietly(connection:LocalConnection):Void {
		try {
			if (connection != null) {
				connection.close();
			}
		} catch (_:Dynamic) {}
	}

	private static function uniqueName(label:String):String {
		return '__crossbyte_local_${label}_${Std.int(Sys.time() * 1000)}_${Std.random(1000000)}'; // time of day: a name no other run has used
	}

	private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}
