package crossbyte.net;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.rpc.RPCCommands;
import crossbyte.rpc.RPCHandler;
import crossbyte.rpc.RPCResponse;
import crossbyte.rpc.RPCSession;
import crossbyte.test.Require;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	What is handed out other than as an event stays the receiver's: an RPC
	argument a handler keeps and answers with a frame later, over TCP,
	WebSocket and reliable UDP; a `NetConnection`'s input kept past its call;
	and an echo written while the peer is not reading.

	The transports underneath reuse what they hand their own listeners, so
	a value that is the application's has to be a copy, which these check
	in every mode, and under `-D crossbyte_check_events` against payloads
	killed as each call returns.
**/
class TransportArrivalTest extends utest.Test {
	#if (cpp || java || jvm || nodejs)
	@:timeout(20000)
	public function testAnRpcHandlerKeepsItsArgumentsOverTcp(async:Async):Void {
		__keptArguments("tcp", async);
	}

	@:timeout(20000)
	public function testAnRpcHandlerKeepsItsArgumentsOverWebSocket(async:Async):Void {
		__keptArguments("ws", async);
	}

	@:timeout(20000)
	public function testAnRpcHandlerKeepsItsArgumentsOverReliableUdp(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}
		__keptArguments("rudp", async);
	}

	@:timeout(15000)
	public function testATcpConnectionsInputIsItsOwnToKeep(async:Async):Void {
		var server = new ServerSocket();
		var sessions:Array<Socket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var kept:ByteArrayInput = null;
			var calls:Int = 0;
			var connection:NetConnection = new NetConnection('tcp://127.0.0.1:${server.localPort}', input -> {
				calls++;
				kept = input;
			}, null, null, null, true);

			NetPump.until(() -> connection.connected && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no connection");
					__closeAll(server, sessions, connection);
					async.done();
					return;
				}
				sessions[0].writeUTFBytes("kept, ");
				sessions[0].flush();

				NetPump.until(() -> calls >= 1, 5.0, function(_) {
					sessions[0].writeUTFBytes("and read a frame later");
					sessions[0].flush();

					NetPump.until(() -> kept != null && kept.bytesAvailable >= 28, 5.0, function(_) {
						Require.notNull(kept, "onData was never called");
						Assert.equals("kept, and read a frame later", kept.readUTFBytes(28), "the input kept past its call lost what arrived");
						__closeAll(server, sessions, connection);
						async.done();
					});
				});
			});
		});
	}
	#end

	#if ((cpp || java || jvm) && !eval)
	/**
		An echo the peer is not reading: written from inside the listener, out
		of a buffer the listener reuses for the next read, and queued behind
		the kernel's buffers long after, and still what arrived.
	**/
	@:timeout(30000)
	public function testATcpEchoQueuedBehindAPeerNotReadingIsWhatArrived():Void {
		var server = new ServerSocket();
		var queued:Int = 0;
		var scratch = new ByteArray();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var socket = e.socket;
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				// One buffer for every read, as a server that allocates
				// nothing per message has.
				scratch.clear();
				socket.readBytes(scratch, 0, socket.bytesAvailable);
				socket.writeBytes(scratch);
				socket.flush();
				if (socket.bytesPending > queued) {
					queued = socket.bytesPending;
				}
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var runtime = CrossByte.current();
		var client = new sys.net.Socket();
		try {
			client.connect(new sys.net.Host("127.0.0.1"), server.localPort);
			client.setBlocking(false);
			// More than the kernel holds on both ends of a loopback connection,
			// which on Windows grows its buffers to a few megabytes.
			var total:Int = 16 * 1024 * 1024;
			var sent:Int = 0;
			var chunk = Bytes.alloc(65536);
			var deadline:Float = haxe.Timer.stamp() + 20;
			while (sent < total && haxe.Timer.stamp() < deadline) {
				for (i in 0...chunk.length) {
					chunk.set(i, ((sent + i) * 7) & 0xFF);
				}
				try {
					sent += client.output.writeBytes(chunk, 0, chunk.length);
				} catch (_:Dynamic) {}
				runtime.pump(0, 0);
			}
			Assert.equals(total, sent, "the client could not send everything");
			// The server echoes while the client reads nothing.
			var settle:Float = haxe.Timer.stamp() + 0.5;
			while (haxe.Timer.stamp() < settle) {
				runtime.pump(0, 0);
			}
			Assert.isTrue(queued > 0, "nothing was ever queued, so the echo was not tested behind a peer that is not reading");

			var received:Int = 0;
			var wrong:Int = -1;
			var buffer = Bytes.alloc(65536);
			deadline = haxe.Timer.stamp() + 20;
			while (received < total && haxe.Timer.stamp() < deadline) {
				var read:Int = 0;
				try {
					read = client.input.readBytes(buffer, 0, buffer.length);
				} catch (_:Dynamic) {}
				for (i in 0...read) {
					if (wrong < 0 && buffer.get(i) != (((received + i) * 7) & 0xFF)) {
						wrong = received + i;
					}
				}
				received += read;
				runtime.pump(0, 0);
			}
			Assert.equals(total, received, "the echo did not all come back");
			Assert.equals(-1, wrong, "the echo carried bytes other than what arrived");
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}
		try client.close() catch (_:Dynamic) {}
		try server.close() catch (_:Dynamic) {}
	}
	#end

	// ------------------------------------------------------------- helpers

	/**
		Three calls, each kept by the handler and answered only once all three
		and a fourth have arrived: each answer is its own argument, whatever
		arrived over the transport after it.
	**/
	private function __keptArguments(scheme:String, async:Async):Void {
		var handler = new KeepingHandler();
		var serverSessions:Array<RPCSession<Dynamic, Dynamic>> = [];
		var host:NetHost = new NetHost(scheme + "://127.0.0.1:0", connection -> {
			var session:RPCSession<Dynamic, Dynamic> = new RPCSession(connection, null, handler);
			serverSessions.push(session);
		}, null, null, true);

		NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
			var connection:NetConnection = new NetConnection(scheme + "://127.0.0.1:" + host.localPort);
			var commands = new KeepingCommands();
			var client:RPCSession<KeepingCommands> = new RPCSession(connection, commands);

			NetPump.until(() -> connection.connected && serverSessions.length > 0, 5.0, function(_) {
				var answers:Array<RPCResponse<Bytes>> = [for (i in 0...3) commands.hold(pattern(200 + i * 300, i))];

				NetPump.until(() -> handler.held.length >= 3, 5.0, function(_) {
					var late = commands.hold(pattern(1500, 9));
					NetPump.until(() -> handler.held.length >= 4, 5.0, function(_) {
						Assert.equals(4, handler.held.length, "not every call reached the handler");
						handler.answerAll();

						NetPump.until(() -> answers[0].completed && answers[1].completed && answers[2].completed && late.completed, 5.0, function(_) {
							for (i in 0...3) {
								Assert.isTrue(answers[i].succeeded, "call " + i + " failed: " + answers[i].error);
								Assert.equals(-1, wrongByte(answers[i].result, 200 + i * 300, i), 'call $i over $scheme was answered with other bytes');
							}
							Assert.equals(-1, wrongByte(late.result, 1500, 9));
							try client.close() catch (_:Dynamic) {}
							try connection.close() catch (_:Dynamic) {}
							try host.close() catch (_:Dynamic) {}
							NetPump.wait(0.1, () -> async.done());
						});
					});
				});
			});
		});
	}

	private static function __closeAll(server:ServerSocket, sessions:Array<Socket>, connection:NetConnection):Void {
		try connection.close() catch (_:Dynamic) {}
		for (session in sessions) {
			try session.close() catch (_:Dynamic) {}
		}
		try server.close() catch (_:Dynamic) {}
	}

	private static function pattern(length:Int, seed:Int):Bytes {
		var bytes = Bytes.alloc(length);
		for (i in 0...length) {
			bytes.set(i, (i * 11 + seed * 5) & 0xFF);
		}
		return bytes;
	}

	private static function wrongByte(bytes:Bytes, length:Int, seed:Int):Int {
		if (bytes == null || bytes.length != length) {
			return -2;
		}
		for (i in 0...length) {
			if (bytes.get(i) != ((i * 11 + seed * 5) & 0xFF)) {
				return i;
			}
		}
		return -1;
	}
}

private class KeepingCommands extends RPCCommands {
	public function new() {}

	@:rpc public function hold(data:Bytes):RPCResponse<Bytes> {}
}

/** Keeps every argument, and answers each with it only when asked to. **/
private class KeepingHandler extends RPCHandler {
	public final held:Array<{data:Bytes, answer:Completer<Bytes>}> = [];

	public function new() {}

	@:rpc public function hold(data:Bytes):Future<Bytes> {
		var answer = new Completer<Bytes>();
		held.push({data: data, answer: answer});
		return answer.future;
	}

	public function answerAll():Void {
		for (entry in held) {
			entry.answer.complete(entry.data);
		}
	}
}
