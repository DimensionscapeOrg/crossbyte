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
