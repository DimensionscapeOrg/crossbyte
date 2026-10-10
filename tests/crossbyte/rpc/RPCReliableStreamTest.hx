package crossbyte.rpc;

// A page has no reliable UDP.
#if !(js && !nodejs)
import crossbyte.events.ReliableDatagramSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.NetConnection;
import crossbyte.net.NetPump;
import crossbyte.net.ReliableDatagramServerSocket;
import crossbyte.net.ReliableDatagramSocket;
import utest.Assert;
import utest.Async;
#end

/**
	An RPC session over a reliable UDP connection in `STREAM` mode, where
	what arrives is bytes in order, not one message a frame: a frame split
	across arrivals (at any byte, and with several frames in one arrival or
	one frame over several) is read whole once its last byte is in.

	The connection handed each arrival over as a buffer of its own, so the
	part of a frame that had arrived went with it, and the rest read as a
	frame of its own: a call larger than one datagram ended the connection
	as one whose framing was lost.
**/
class RPCReliableStreamTest extends utest.Test {
	#if !(js && !nodejs)
	@:timeout(30000)
	public function testCallsLargerThanADatagramAreAnswered(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}
		StreamPair.open(false, pair -> {
			final commands = new StreamCommands();
			final client = new RPCSession<StreamCommands>(pair.client, commands);
			// Each over several datagrams: a stream's frame is ~1,200 bytes.
			final texts = [for (size in [3000, 20000, 1, 9000]) StringTools.lpad("", String.fromCharCode(97 + size % 26), size)];
			final answers = [for (text in texts) commands.echo(text)];
			NetPump.until(() -> answers[answers.length - 1].completed || !pair.client.connected, 10.0, function(_) {
				for (i in 0...texts.length) {
					Assert.isTrue(answers[i].succeeded, 'call $i failed: ' + answers[i].error);
					Assert.equals(texts[i].length, answers[i].succeeded ? (answers[i].result : String).length : -1);
				}
				Assert.isTrue(pair.client.connected, "the connection ended");
				pair.close();
				async.done();
			});
		}, failure -> {
			Assert.fail(failure);
			async.done();
		});
	}

	@:timeout(60000)
	public function testAFrameSplitAtEveryByteIsReadWhole(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}
		// What a session sends for three one-way calls (and its hello), as
		// bytes: written to a raw stream split at every byte, then a byte at a
		// time.
		final bytes = framesOf(commands -> {
			commands.add(1);
			commands.add(2);
			commands.add(3);
		});
		StreamPair.open(true, pair -> {
			final writer:ReliableDatagramSocket = pair.rawClient;
			final added:Array<Int> = pair.handler.added;
			var split:Int = 1;
			var step:Void->Void = null;
			final finish = function():Void {
				pair.close();
				async.done();
			};
			final aByteAtATime = function():Void {
				final before:Int = added.length;
				for (at in 0...bytes.length) {
					writer.writeBytes(bytes, at, 1);
					writer.flush();
				}
				NetPump.until(() -> added.length == before + 3 || !pair.accepted.connected, 5.0, function(_) {
					Assert.same([1, 2, 3], added.slice(before), "a byte at a time");
					finish();
				});
			};
			step = function():Void {
				if (split == bytes.length) {
					aByteAtATime();
					return;
				}
				final before:Int = added.length;
				writer.writeBytes(bytes, 0, split);
				writer.flush();
				// The first part arrives, and is read as far as it goes, before
				// the rest is sent.
				NetPump.wait(0.01, function() {
					writer.writeBytes(bytes, split, bytes.length - split);
					writer.flush();
					NetPump.until(() -> added.length == before + 3 || !pair.accepted.connected, 5.0, function(_) {
						if (added.length != before + 3) {
							Assert.fail('split at $split of ${bytes.length}: ' + (added.length - before) + " calls read, connected "
								+ pair.accepted.connected);
							finish();
							return;
						}
						Assert.same([1, 2, 3], added.slice(before), 'split at $split');
						split++;
						step();
					});
				});
			};
			step();
		}, failure -> {
			Assert.fail(failure);
			async.done();
		});
	}

	/** What a session with commands sends as `calls` runs, as one run of bytes. **/
	private static function framesOf(calls:StreamCommands->Void):ByteArray {
		final link = LinkedConnection.pair();
		link.server.bufferInbound = true;
		final commands = new StreamCommands();
		final session = new RPCSession<StreamCommands>(link.client, commands);
		calls(commands);
		var captured:ByteArray = null;
		link.server.onData = input -> {
			captured = new ByteArray();
			while (input.bytesAvailable > 0) {
				captured.writeByte(input.readByte());
			}
		};
		link.server.deliverBufferedAsOneRead();
		captured.position = 0;
		return captured;
	}
	#end
}

#if !(js && !nodejs)
/**
	A reliable UDP server in `STREAM` mode whose sessions answer with
	`StreamHandler`, and a client: a `NetConnection`, or (`raw`) a stream
	socket written by hand.
**/
private class StreamPair {
	public final server = new ReliableDatagramServerSocket();
	public final handler = new StreamHandler();
	public var accepted:NetConnection = null;
	public var acceptedSession:RPCSession<Dynamic> = null;
	public var client:NetConnection = null;
	public var rawClient:ReliableDatagramSocket = null;

	function new() {}

	/** A pair, connected, given to `then`; or why not, to `failed`. **/
	public static function open(raw:Bool, then:StreamPair->Void, failed:String->Void):Void {
		final pair = new StreamPair();
		final server = pair.server;
		server.socketMode = STREAM;
		server.bind(0, "127.0.0.1");
		server.addEventListener(ReliableDatagramSocketConnectEvent.CONNECT, event -> {
			pair.accepted = NetConnection.fromReliableDatagramSocket(event.socket);
			pair.acceptedSession = new RPCSession(pair.accepted, null, pair.handler);
		});
		server.listen();
		// Node binds a turn later.
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			final socket = new ReliableDatagramSocket();
			socket.mode = STREAM;
			if (raw) {
				pair.rawClient = socket;
			} else {
				pair.client = NetConnection.fromReliableDatagramSocket(socket);
			}
			socket.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> socket.connected && pair.accepted != null && pair.accepted.connected, 5.0, function(up:Bool) {
				if (!up) {
					pair.close();
					failed("the reliable stream pair did not connect");
					return;
				}
				then(pair);
			});
		});
	}

	public function close():Void {
		try {
			if (client != null) {
				client.close();
			}
			if (rawClient != null) {
				rawClient.close();
			}
		} catch (_:Dynamic) {}
		try {
			if (accepted != null) {
				accepted.close();
			}
		} catch (_:Dynamic) {}
		try {
			server.close();
		} catch (_:Dynamic) {}
	}
}

private class StreamCommands extends RPCCommands {
	public function new() {}

	@:rpc public function add(value:Int):Void {}

	@:rpc public function echo(text:String):RPCResponse<String> {}
}

private class StreamHandler extends RPCHandler {
	public final added:Array<Int> = [];

	public function new() {}

	@:rpc public function add(value:Int):Void {
		added.push(value);
	}

	@:rpc public function echo(text:String):String {
		return text;
	}
}
#end
