package crossbyte.net;

#if (sys && !(js || php) && !eval)
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.test.Require;
#end
import utest.Assert;

/**
	What a TCP connection holds once its traffic is over.

	A connection keeps its storage while it is busy, so a message read or
	written allocates nothing, and lets go of it once it has read and
	written nothing for a sweep of its registry; a buffer past 64 KB lets
	go as soon as it empties. Kept for as long as the connection was open,
	each buffer would hold the largest it had ever needed: after one 16 KB
	message each way, about 51 KB natively for an idle connection that
	held 1.5 KB before any.

	Natively, on the jvm, and on neko and HashLink; not on eval, whose
	blocking sockets the echo below would stall.
**/
@:access(crossbyte.net.Socket)
@:access(crossbyte.core.CrossByte)
class SocketMemoryTest extends utest.Test {
	#if (sys && !(js || php) && !eval)
	/**
		After a 16 KB message each way both ends hold their storage while the
		connection is busy, and let go of all of it once it has been quiet
		for a sweep: one sweep finds it was busy, the next that it was not.
	**/
	public function testAQuietConnectionLetsGoOfItsBuffers():Void {
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			__exchange(client, accepted, 16 * 1024);
			// The registry's own sweep held off, so the two below are the only
			// ones, and the connection busy again just before them.
			var registry = @:privateAccess CrossByte.current().__socketRegistry;
			@:privateAccess registry.__nextQuietSweep = haxe.Timer.stamp() + 1000;
			__exchange(client, accepted, 16 * 1024);
			Assert.isTrue(__storage(accepted.__input) > 0, "the busy connection kept nothing to read into");
			Assert.isTrue(__storage(accepted.__output) > 0, "the busy connection kept nothing to write from");
			Assert.isTrue(__held(accepted), "a connection holding storage was not watched for going quiet");

			// The sweep that finds it was busy keeps everything.
			__sweep();
			Assert.isTrue(__storage(accepted.__input) > 0, "a connection busy since the last sweep let go of its storage");

			// The next finds it quiet.
			__sweep();
			Assert.equals(0, __storage(accepted.__input), "a quiet connection kept what it read into");
			Assert.equals(0, __storage(accepted.__output), "a quiet connection kept what it wrote from");
			Assert.equals(0, __storage(client.__input), "a quiet client kept what it read into");
			Assert.equals(0, __storage(client.__output), "a quiet client kept what it wrote from");
			Assert.isFalse(__held(accepted), "a connection holding nothing was still watched");

			// And works as before.
			__exchange(client, accepted, 1000);
			Assert.isTrue(accepted.connected && client.connected);
			@:privateAccess registry.__nextQuietSweep = haxe.Timer.stamp();
		});
	}

	/**
		What the application has not read, or the peer not taken, is kept
		however quiet the connection.
	**/
	public function testWhatIsUnreadIsKeptHoweverQuiet():Void {
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			var message = new ByteArray();
			message.length = 5000;
			client.writeBytes(message);
			client.flush();
			__pumpUntil(() -> accepted.bytesAvailable >= 5000, 5.0);
			Assert.equals(5000, accepted.bytesAvailable);
			__sweep();
			__sweep();
			__sweep();
			Assert.equals(5000, accepted.bytesAvailable, "unread bytes were let go of");
			var read = new ByteArray();
			accepted.readBytes(read, 0, 5000);
			Assert.equals(5000, read.length);
		});
	}

	/**
		A buffer grown past 64 KB lets go as soon as it empties, rather than
		holding what one large message made it grow to while smaller ones
		follow.
	**/
	public function testALargeBufferLetsGoAsSoonAsItEmpties():Void {
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			var size:Int = 200 * 1024;
			var message = new ByteArray();
			message.length = size;
			client.writeBytes(message);
			client.flush();
			var received:Int = 0;
			var most:Int = 0;
			var sink = new ByteArray();
			accepted.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				var storage:Int = __storage(accepted.__input);
				if (storage > most) {
					most = storage;
				}
				received += accepted.bytesAvailable;
				sink.clear();
				accepted.readBytes(sink, 0, accepted.bytesAvailable);
			});
			// One read pass takes up to 1 MB: read it all before draining it.
			__pumpUntil(() -> received >= size, 10.0);
			Assert.equals(size, received);
			// Drained: the next pass finds it empty and lets go.
			client.writeUTFBytes("x");
			client.flush();
			__pumpUntil(() -> received >= size + 1, 5.0);
			Assert.isTrue(__storage(accepted.__input) <= 64 * 1024, "a buffer past 64 KB kept " + __storage(accepted.__input) + " bytes once it had emptied");
		});
	}

	/**
		Natively and on the jvm a buffer grown past 64 KB takes its storage
		from the runtime's pool and gives it back when it empties, so a
		connection sending a large burst each pass takes the same storage
		again rather than growing anew; the bytes already waiting are carried
		into the larger storage; and the pool lets go of what it keeps once a
		whole sweep passes with nothing taken.
	**/
	public function testALargeOutputTakesItsStorageFromTheRuntimesPool():Void {
		#if (cpp || jvm)
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			var pool = CrossByte.current().__storagePool();
			var size:Int = 150 * 1024;
			// The receiver's input held under 64 KB, so it takes nothing from
			// the pool and leaves its storage to the output.
			accepted.maxInputBufferSize = 32 * 1024;
			var received = new ByteArray();
			accepted.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				accepted.readBytes(received, received.length, accepted.bytesAvailable);
			});
			function burst(seed:Int):haxe.io.BytesData {
				// Two writes, the second past 64 KB with the first still waiting:
				// what waits is carried into the pool's storage.
				for (half in 0...2) {
					var part = new ByteArray();
					for (i in 0...size) {
						part.writeByte((seed + half * size + i) * 31);
					}
					client.writeBytes(part);
				}
				var storage = (client.__output : crossbyte.io.ByteArray.ByteArrayData).getData();
				client.flush();
				return storage;
			}
			function check(seed:Int):Void {
				__pumpUntil(() -> received.length >= 2 * size, 10.0);
				Assert.equals(2 * size, received.length, "what arrived");
				var wrong:Int = -1;
				for (i in 0...2 * size) {
					if (received[i] != (((seed + i) * 31) & 0xFF)) {
						wrong = i;
						break;
					}
				}
				Assert.equals(-1, wrong, "the bytes arrived as sent, first wrong at " + wrong);
				received.clear();
			}

			var first = burst(1);
			check(1);
			__pumpUntil(() -> client.__output.length == 0, 5.0);
			Assert.isTrue(__storage(client.__output) <= 64 * 1024, "the drained output kept " + __storage(client.__output) + " bytes");
			Assert.isTrue(pool.held() >= 2 * size, "its storage did not go back to the pool, which holds " + pool.held());

			var second = burst(2);
			Assert.isTrue(first == second, "the second burst grew storage of its own rather than taking the pool's");
			check(2);
			__pumpUntil(() -> client.__output.length == 0, 5.0);

			// Busy since the last ask: kept. One interval with none taken: kept
			// as spare. A second: gone.
			pool.__releaseIfQuiet();
			Assert.isTrue(pool.held() > 0, "a pool in use let go at once");
			pool.__releaseIfQuiet();
			Assert.isTrue(pool.held() > 0, "a pool let go after one quiet interval");
			pool.__releaseIfQuiet();
			Assert.equals(0.0, pool.held(), "a pool quiet for two intervals kept storage");
		});
		#else
		Assert.pass();
		#end
	}

	/**
		Natively and on the jvm a large input takes its storage from the
		runtime's pool as it grows and gives it back once read: the bytes not
		yet read are carried across each growth and each move down, in order,
		and a second burst of the same size takes the size the first held at
		most at once, from the storage the first gave back, rather than
		growing through the sizes below it or making storage of its own. An
		input read whole gives its storage back when the connection closes.
	**/
	public function testALargeInputTakesItsStorageFromTheRuntimesPool():Void {
		#if (cpp || jvm)
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			var pool = CrossByte.current().__storagePool();
			var sent:Int = 0;
			var read:Int = 0;
			function send(count:Int):Void {
				// In pieces each sent before the next, so the sender's output
				// stays under 64 KB and takes nothing from the pool itself.
				var left:Int = count;
				while (left > 0) {
					var piece:Int = left < 16 * 1024 ? left : 16 * 1024;
					var part = new ByteArray();
					for (i in 0...piece) {
						part.writeByte((sent + i) * 31);
					}
					sent += piece;
					left -= piece;
					client.writeBytes(part);
					client.flush();
					__pumpUntil(() -> client.outputBufferLength == 0, 10.0);
				}
				// Nothing read until all of it has arrived, so the input holds it.
				__pumpUntil(() -> read + accepted.bytesAvailable >= sent, 10.0);
				Assert.equals(sent - read, Std.int(accepted.bytesAvailable), "what arrived");
			}
			function take(count:Int):Void {
				var got = new ByteArray();
				accepted.readBytes(got, 0, count);
				var wrong:Int = -1;
				for (i in 0...count) {
					if (got[i] != (((read + i) * 31) & 0xFF)) {
						wrong = read + i;
						break;
					}
				}
				Assert.equals(-1, wrong, "the bytes were read as sent, first wrong at " + wrong);
				read += count;
			}
			function burst(again:Bool):Void {
				// Grown past 64 KB with nothing read; read in part, then grown
				// again with what was not read carried across.
				send(200 * 1024);
				if (again) {
					// The size the last burst held at most, taken at once.
					Assert.isTrue(__storage(accepted.__input) >= 450 * 1024, "a burst like the last grew to " + __storage(accepted.__input)
						+ " rather than taking the size the last held at once");
				}
				take(150 * 1024);
				send(400 * 1024);
				Assert.isTrue(__storage(accepted.__input) >= 450 * 1024, "the input held " + __storage(accepted.__input));
				take(sent - read);
				// The next arrival finds it read, and gives its storage back.
				send(1);
				take(1);
				Assert.isTrue(__storage(accepted.__input) <= 64 * 1024, "the drained input kept " + __storage(accepted.__input) + " bytes");
			}

			burst(false);
			Assert.isTrue(pool.held() >= 450 * 1024, "its storage did not go back to the pool, which holds " + pool.held());
			var made:Int = pool.made;
			Assert.isTrue(made > 0, "the input took nothing from the pool");
			burst(true);
			Assert.equals(made, pool.made, "the second burst made storage of its own rather than taking the pool's");

			// Read whole, and closed before another arrival finds it read: its
			// storage goes back as the connection closes.
			send(300 * 1024);
			take(sent - read);
			var before:Float = pool.held();
			accepted.close();
			Assert.isTrue(pool.held() >= before + 300 * 1024, "the storage of an input read whole went with the closed connection");
		});
		#else
		Assert.pass();
		#end
	}

	/**
		Natively and on the jvm an output that must grow while part of it has
		been sent lets go of the sent part first: it takes storage for what
		waits and what is written, not for those and what already went, and
		what waits stays in order ahead of what follows it.
	**/
	public function testAnOutputLetsGoOfWhatWasSentAsItGrows():Void {
		#if (cpp || jvm)
		__pair(function(server:ServerSocket, client:Socket, accepted:Socket):Void {
			function bytes(from:Int, count:Int):ByteArray {
				var out = new ByteArray();
				for (i in 0...count) {
					out.writeByte((from + i) * 31);
				}
				return out;
			}
			client.writeBytes(bytes(0, 300 * 1024));
			// As a slow reader leaves it: 120 KB of it sent, the rest waiting.
			client.__retainPendingOutput(120 * 1024, 300 * 1024);
			Assert.equals(120 * 1024, client.__outputSent, "the sent part was moved before the test could grow past it");
			client.writeBytes(bytes(300 * 1024, 200 * 1024));
			var held:Int = __storage(client.__output);
			Assert.isTrue(held < crossbyte._internal.socket.StoragePool.sizeFor(500 * 1024),
				'the output took $held bytes, room for what had been sent as well as what waits');
			Assert.equals(0, client.__outputSent);
			Assert.equals(380 * 1024, Std.int(client.__output.length));
			var wrong:Int = -1;
			for (i in 0...380 * 1024) {
				if (client.__output[i] != (((120 * 1024 + i) * 31) & 0xFF)) {
					wrong = i;
					break;
				}
			}
			Assert.equals(-1, wrong, "what waits was not kept in order, first wrong at " + wrong);
		});
		#else
		Assert.pass();
		#end
	}

	/**
		The pool's sizes are a quarter apart within each doubling, so storage
		is never more than a quarter larger than what it was taken for: just
		past 64 KB takes 80 KB, 1.1 MB takes 1.25 MB, 4.5 MB 5 MB and 9 MB
		10 MB, where powers of two alone gave 128 KB, 2, 8 and 16 MB. Each
		size is kept, and let go when quiet, on its own; what a buffer grew
		out of only until the next ask.
	**/
	public function testThePoolsSizesAreAQuarterApart():Void {
		#if (cpp || jvm)
		var kb:Int = 1024;
		var mb:Int = 1024 * 1024;
		Assert.equals(64 * kb, crossbyte._internal.socket.StoragePool.sizeFor(1));
		Assert.equals(64 * kb, crossbyte._internal.socket.StoragePool.sizeFor(64 * kb));
		Assert.equals(80 * kb, crossbyte._internal.socket.StoragePool.sizeFor(64 * kb + 1));
		Assert.equals(128 * kb, crossbyte._internal.socket.StoragePool.sizeFor(112 * kb + 1));
		Assert.equals(1280 * kb, crossbyte._internal.socket.StoragePool.sizeFor(Std.int(1.1 * mb)));
		Assert.equals(5 * mb, crossbyte._internal.socket.StoragePool.sizeFor(Std.int(4.5 * mb)));
		Assert.equals(10 * mb, crossbyte._internal.socket.StoragePool.sizeFor(9 * mb));
		Assert.equals(32 * mb, crossbyte._internal.socket.StoragePool.sizeFor(32 * mb));
		Assert.equals(-1, crossbyte._internal.socket.StoragePool.sizeFor(32 * mb + 1));
		var worst:Float = 0;
		var wrong:Int = -1;
		var size:Int = 64 * kb + 1;
		while (size <= 32 * mb) {
			var kept:Int = crossbyte._internal.socket.StoragePool.sizeFor(size);
			if (kept < size || crossbyte._internal.socket.StoragePool.sizeFor(kept) != kept) {
				wrong = size;
			}
			if (kept / size > worst) {
				worst = kept / size;
			}
			size += 4093;
		}
		Assert.equals(-1, wrong, "a size the pool kept was short of what it was asked for, or not a size it keeps");
		Assert.isTrue(worst <= 1.25, "storage was up to " + worst + " times what it was taken for");

		var pool = new crossbyte._internal.socket.StoragePool(null);
		var large = pool.take(9 * mb);
		var small = pool.take(Std.int(1.1 * mb));
		Assert.equals(10 * mb, large.length);
		Assert.equals(1280 * kb, small.length);
		pool.give(large);
		pool.give(small);
		Assert.equals(11.25 * mb, pool.held());
		Assert.isTrue(pool.take(Std.int(9.5 * mb)) == large, "storage of the size given back was not taken again");
		pool.give(large);
		// Taken since the last ask: kept. Then a quiet interval: kept as
		// spare. A second: gone, every size.
		pool.__releaseIfQuiet();
		Assert.equals(11.25 * mb, pool.held());
		pool.__releaseIfQuiet();
		Assert.equals(11.25 * mb, pool.held());
		pool.__releaseIfQuiet();
		Assert.equals(0.0, pool.held());

		// What a buffer grew out of is kept only until the next ask.
		var passed = pool.take(Std.int(1.1 * mb));
		pool.giveGrown(passed);
		Assert.equals(1280.0 * kb, pool.held());
		Assert.isTrue(pool.take(Std.int(1.1 * mb)) == passed, "storage a buffer grew out of was not taken again");
		pool.giveGrown(passed);
		pool.__releaseIfQuiet();
		Assert.equals(0.0, pool.held(), "storage a buffer grew out of was kept past the next ask");
		#else
		Assert.pass();
		#end
	}

	private static function __exchange(client:Socket, accepted:Socket, size:Int):Void {
		var message = new ByteArray();
		message.length = size;
		var echoed:Int = 0;
		var echo = (_:ProgressEvent) -> {
			if (accepted.bytesAvailable >= size) {
				var got = new ByteArray();
				accepted.readBytes(got, 0, size);
				accepted.writeBytes(got);
				accepted.flush();
			}
		};
		var back = (_:ProgressEvent) -> {
			if (client.bytesAvailable >= size) {
				var got = new ByteArray();
				client.readBytes(got, 0, size);
				echoed++;
			}
		};
		accepted.addEventListener(ProgressEvent.SOCKET_DATA, echo);
		client.addEventListener(ProgressEvent.SOCKET_DATA, back);
		client.writeBytes(message);
		client.flush();
		__pumpUntil(() -> echoed > 0, 5.0);
		accepted.removeEventListener(ProgressEvent.SOCKET_DATA, echo);
		client.removeEventListener(ProgressEvent.SOCKET_DATA, back);
		Assert.equals(1, echoed, "the message did not come back");
	}

	private static function __pair(run:(ServerSocket, Socket, Socket) -> Void):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		var client = new Socket();
		try {
			server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> accepted = e.socket);
			server.bind(0, "127.0.0.1");
			server.listen();
			var connected:Bool = false;
			client.addEventListener(Event.CONNECT, _ -> connected = true);
			client.connect("127.0.0.1", server.localPort);
			__pumpUntil(() -> connected && accepted != null, 5.0);
			Require.notNull(accepted);
			run(server, client, accepted);
		} catch (e:Dynamic) {
			Assert.fail("the connection failed: " + Std.string(e));
		}
		try client.close() catch (_:Dynamic) {}
		if (accepted != null) {
			try accepted.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}

	/** One sweep of the runtime's registry for sockets gone quiet, as its clock would run. **/
	private static function __sweep():Void {
		@:privateAccess CrossByte.current().__socketRegistry.__sweepQuiet();
	}

	private static function __held(socket:Socket):Bool {
		return socket.__holdingStorage;
	}

	private static function __storage(buffer:ByteArray):Int {
		return buffer == null ? 0 : @:privateAccess (buffer : crossbyte.io.ByteArray.ByteArrayData).__length;
	}

	private static function __pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}
	#end
}
