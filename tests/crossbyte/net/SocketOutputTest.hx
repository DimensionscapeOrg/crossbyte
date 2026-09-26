package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import utest.Assert;
import utest.Async;

/**
	What a socket sends to a peer that reads slower than it is written to.

	Both cases were broken on Node alone, and both run everywhere a socket is
	non-blocking, since what they describe is not a Node property: a slow
	reader must get exactly what was written, and `maxOutputBufferSize` must be
	reachable. Not on eval, whose sockets block, so a write to a peer that has
	stopped reading waits for it rather than buffering.
**/
class SocketOutputTest extends utest.Test {
	#if (cpp || java || jvm || nodejs)
	/**
		Ten half-megabyte messages, each filled with its own letter, written to
		a peer that is not reading yet.

		On Node a flush handed Node a view over the output buffer and then
		cleared it for reuse, so each message was written over the bytes of
		the one Node still had queued: what a slow reader got was the first
		few messages and then the last one, repeated.
	**/
	@:timeout(30000)
	public function testASlowReaderReceivesExactlyWhatWasWritten(async:Async):Void {
		var count:Int = 10;
		var size:Int = 512 * 1024;

		__withPeer(function(server:ServerSocket, accepted:Socket, peer:SlowPeer, finish:Void->Void) {
			var message = new ByteArray();
			for (i in 0...count) {
				message.clear();
				for (_ in 0...size) {
					message.writeByte(0x61 + i);
				}
				accepted.writeBytes(message, 0, size);
				accepted.flush();
			}

			peer.resume();

			NetPump.until(() -> {
				peer.drain();
				return peer.received >= count * size;
			}, 20.0, function(_) {
				Assert.equals(count * size, peer.received, "not everything written arrived");
				Assert.equals(0, peer.misplaced, peer.misplaced + " bytes arrived as something other than what was written in their place");
				finish();
			});
		}, async);
	}

	/**
		A peer that never reads, and a socket that goes on writing to it.

		On Node the backlog is Node's queue rather than the socket's buffer, so
		`outputBufferLength` read 0 however much was waiting and the limit,
		measured against it, could never be reached: the queue grew for as long
		as the writer did.
	**/
	@:timeout(60000)
	public function testTheOutputLimitIsReachedAgainstAPeerThatDoesNotRead(async:Async):Void {
		var limit:Int = 256 * 1024;
		var chunk:Int = 64 * 1024;
		// Far past what the kernel will hold for a stalled loopback peer, so
		// reaching it without a close means the limit never engaged.
		var ceiling:Int = 256 * 1024 * 1024;

		__withPeer(function(server:ServerSocket, accepted:Socket, peer:SlowPeer, finish:Void->Void) {
			var closed:Bool = false;
			var refusal:String = null;
			var written:Int = 0;
			var largest:Int = 0;
			var payload = new ByteArray();
			for (_ in 0...chunk) {
				payload.writeByte(0x43);
			}

			accepted.maxOutputBufferSize = limit;
			accepted.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) refusal = e.text);
			accepted.addEventListener(Event.CLOSE, function(_) closed = true);

			NetPump.until(() -> {
				if (!closed && accepted.connected && written < ceiling) {
					try {
						accepted.writeBytes(payload, 0, chunk);
						accepted.flush();
						written += chunk;
						if (accepted.connected && accepted.outputBufferLength > largest) {
							largest = accepted.outputBufferLength;
						}
					} catch (e:Dynamic) {
						// Written after the policy closed it.
					}
				}
				return closed || written >= ceiling;
			}, 40.0, function(_) {
				Assert.isTrue(closed, 'wrote $written bytes to a peer that reads nothing and the $limit byte limit never closed it');
				Assert.isTrue(refusal != null && refusal.indexOf("limit") >= 0, "the close did not say it was the output limit: " + refusal);
				Assert.isTrue(largest > 0, "outputBufferLength never counted anything waiting to be sent");
				finish();
			});
		}, async);
	}

	#if (cpp || java || jvm)
	/**
		Written and flushed straight after `connect()`, before the connection
		is up: the bytes wait and go once it is.

		The flush wrote to a socket not yet connected, which Windows refuses
		("not connected"), so it threw -- and the tick's own flush reported the
		same refusal as an `ioError` on every tick until the connect finished.
	**/
	@:timeout(15000)
	public function testWritingBeforeTheConnectFinishesIsNotAnError(async:Async):Void {
		var server = new ServerSocket();
		var got:String = "";
		var accepted:Socket = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			accepted = e.socket;
			accepted.addEventListener(crossbyte.events.ProgressEvent.SOCKET_DATA, function(_) got += accepted.readUTFBytes(accepted.bytesAvailable));
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var client = new Socket();
			var errors:Array<String> = [];
			var thrown:Dynamic = null;
			client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) errors.push(e.text));
			client.connect("127.0.0.1", server.localPort);
			try {
				client.writeUTFBytes("early");
				client.flush();
			} catch (e:Dynamic) {
				thrown = e;
			}

			NetPump.until(() -> got == "early", 5.0, function(_) {
				Assert.isNull(thrown, "a flush before the connect finished threw: " + thrown);
				Assert.same([], errors, "writing before the connect finished was reported as an error");
				Assert.equals("early", got, "what was written before the connect finished never arrived");
				try client.close() catch (_:Dynamic) {}
				if (accepted != null) {
					try accepted.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		The same, against a connect that stays pending: a listener whose queue
		is full and never accepted from, so the kernel drops the connect's
		SYN and retries it. Over plain loopback the connect finishes before
		anything is written, and the old flush got away with it.
	**/
	@:timeout(15000)
	public function testWritingWhileTheConnectIsPendingIsNotAnError(async:Async):Void {
		var host = new sys.net.Host("127.0.0.1");
		var listener = new sys.net.Socket();
		listener.bind(host, 0);
		listener.listen(1);
		var port:Int = listener.host().port;

		// Nobody accepts, so these fill its queue.
		var fillers:Array<sys.net.Socket> = [];
		for (_ in 0...4) {
			var filler = new sys.net.Socket();
			filler.setBlocking(false);
			try {
				filler.connect(host, port);
			} catch (_:Dynamic) {}
			fillers.push(filler);
		}

		var client = new Socket();
		var writeErrors:Array<String> = [];
		var thrown:Dynamic = null;
		client.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
			// A connect the queue refused outright is not what this is about.
			if (e.text.indexOf("write") >= 0) {
				writeErrors.push(e.text);
			}
		});
		client.connect("127.0.0.1", port);
		try {
			client.writeUTFBytes("early");
			client.flush();
		} catch (e:Dynamic) {
			thrown = e;
		}

		NetPump.wait(0.3, function() {
			Assert.isNull(thrown, "a flush while the connect was pending threw: " + thrown);
			Assert.same([], writeErrors, "writing while the connect was pending was reported as an error");
			try client.close() catch (_:Dynamic) {}
			for (filler in fillers) {
				try filler.close() catch (_:Dynamic) {}
			}
			try listener.close() catch (_:Dynamic) {}
			async.done();
		});
	}

	/**
		Four megabytes sent by a WebSocket session through a socket that takes
		16 KB a write and 64 KB a pass, as a TLS socket does against a slow
		reader.

		Every write the socket took only part of used to copy everything still
		waiting into a new buffer -- a copy of the backlog per 16 KB record,
		quadratic in its size -- and a pass wrote once, whatever room there
		was. What went is now stepped over, the buffer compacted only when what
		went is at least what remains, and a pass writes until the socket takes
		no more. Not on Node, which takes every write whole.
	**/
	@:timeout(30000)
	public function testAWebSocketBacklogIsSteppedThroughNotCopied(async:Async):Void {
		var size:Int = 4 * 1024 * 1024;
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade();

			NetPump.until(() -> {
				peer.poll();
				return sessions.length > 0 && peer.head() != null;
			}, 5.0, function(_) {
				var session = sessions[0];
				var internal = @:privateAccess session.__webSocket;
				var raw:sys.net.Socket = cast @:privateAccess internal.__socket;
				var original = raw.output;
				var throttled = new ThrottledOutput(16 * 1024, 64 * 1024);
				@:privateAccess raw.output = throttled;

				var payload = new ByteArray();
				payload.length = size;
				for (i in 0...size) {
					payload[i] = i & 0xFF;
				}
				session.sendBinary(payload);

				var buffer:ByteArray = @:privateAccess internal.__pendingOutput;
				var copies:Int = 0;
				var passes:Int = 0;

				NetPump.until(() -> {
					var now:ByteArray = @:privateAccess internal.__pendingOutput;
					if (now != buffer) {
						copies++;
						buffer = now;
					}
					if (throttled.room <= 0) {
						passes++;
						throttled.room = 64 * 1024;
					}
					return internal.outputBufferLength == 0;
				}, 20.0, function(_) {
					@:privateAccess raw.output = original;

					// The frames the session wrote: the message's first and its
					// continuations, unmasked, in order.
					var sent = throttled.taken.getBytes();
					var at:Int = 0;
					var received:Int = 0;
					var wrong:Int = 0;
					while (at + 2 <= sent.length) {
						var length:Int = sent.get(at + 1) & 0x7F;
						var start:Int = at + 2;
						if (length == 126) {
							length = (sent.get(at + 2) << 8) | sent.get(at + 3);
							start = at + 4;
						} else if (length == 127) {
							length = (sent.get(at + 6) << 24) | (sent.get(at + 7) << 16) | (sent.get(at + 8) << 8) | sent.get(at + 9);
							start = at + 10;
						}
						for (i in 0...length) {
							if (start + i >= sent.length || sent.get(start + i) != ((received + i) & 0xFF)) {
								wrong++;
							}
						}
						received += length;
						at = start + length;
					}

					Assert.equals(size, received, "the message did not go out whole");
					Assert.equals(0, wrong, '$wrong bytes of the message went out as something else');
					Assert.isTrue(copies <= 8, 'the backlog was copied into a new buffer $copies times over $passes passes');
					Assert.isTrue(passes <= size / (64 * 1024) + 2, '$passes passes of 64 KB for $size bytes: a pass wrote once where there was room for more');

					peer.close();
					for (s in sessions) {
						try s.close() catch (_:Dynamic) {}
					}
					try server.close() catch (_:Dynamic) {}
					NetPump.wait(0.1, () -> async.done());
				});
			});
		});
	}
	#end

	/**
		A listener, one accepted connection, and a peer on the other end that
		reads only when told. Everything is closed on every path.
	**/
	private function __withPeer(body:(ServerSocket, Socket, SlowPeer, Void->Void)->Void, async:Async):Void {
		var server = new ServerSocket();
		var accepted:Socket = null;
		var peer:SlowPeer = null;

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) accepted = e.socket);
		server.bind(0, "127.0.0.1");
		server.listen();

		function finish():Void {
			if (peer != null) {
				peer.close();
			}
			if (accepted != null) {
				try accepted.close() catch (_:Dynamic) {}
			}
			try server.close() catch (_:Dynamic) {}
			async.done();
		}

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			peer = new SlowPeer(server.localPort);

			NetPump.until(() -> accepted != null, 5.0, function(arrived:Bool) {
				if (!arrived) {
					Assert.fail("the peer's connection was never accepted");
					finish();
					return;
				}

				body(server, accepted, peer, finish);
			});
		});
	}
	#end
}

#if (cpp || java || jvm || nodejs)
/**
	The far end, reading only once told to, and checking that each byte is
	the one written in its place: a run of `a`, then of `b`, and so on, each
	half a megabyte long.
**/
private class SlowPeer {
	public var received(default, null):Int = 0;
	public var misplaced(default, null):Int = 0;

	private static inline var RUN:Int = 512 * 1024;

	#if nodejs
	private var __socket:js.node.net.Socket;
	#else
	private var __socket:sys.net.Socket;
	private var __scratch:haxe.io.Bytes = haxe.io.Bytes.alloc(64 * 1024);
	private var __reading:Bool = false;
	#end

	public function new(port:Int) {
		#if nodejs
		__socket = js.node.Net.connect({port: port, host: "127.0.0.1"});
		__socket.pause();
		__socket.on("data", function(chunk:js.node.Buffer) {
			for (i in 0...chunk.length) {
				__check(chunk[i]);
			}
		});
		__socket.on("error", function(_) {});
		#else
		__socket = new sys.net.Socket();
		__socket.connect(new sys.net.Host("127.0.0.1"), port);
		__socket.setBlocking(false);
		#end
	}

	public function resume():Void {
		#if nodejs
		__socket.resume();
		#else
		__reading = true;
		#end
	}

	/** Reads what has arrived, where reading is not Node's own doing. **/
	public function drain():Void {
		#if !nodejs
		if (!__reading) {
			return;
		}

		while (true) {
			var got:Int = 0;
			try {
				got = __socket.input.readBytes(__scratch, 0, __scratch.length);
			} catch (_:Dynamic) {
				return;
			}
			if (got <= 0) {
				return;
			}
			for (i in 0...got) {
				__check(__scratch.get(i));
			}
		}
		#end
	}

	public function close():Void {
		try {
			#if nodejs
			__socket.destroy();
			#else
			__socket.close();
			#end
		} catch (_:Dynamic) {}
	}

	private inline function __check(value:Int):Void {
		if (value != 0x61 + Std.int(received / RUN)) {
			misplaced++;
		}
		received++;
	}
}
#end
