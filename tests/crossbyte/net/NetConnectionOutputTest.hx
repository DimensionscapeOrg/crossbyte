package crossbyte.net;

import crossbyte.errors.RangeError;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import utest.Assert;
import utest.Async;

/**
	What a `NetConnection` says of what waits unsent: `bytesPending`, the
	`outputHighWater` and `outputLowWater` marks with `onOutputHigh` and
	`onOutputDrained`, and `Reason.Overflow` for a connection its transport
	closed for passing its output limit, over TCP, WebSocket and reliable UDP.
**/
class NetConnectionOutputTest extends utest.Test {
	#if (cpp || java || jvm || eval || nodejs)
	public function testTheMarksAreOffUntilSetAndRefuseANegative():Void {
		var connection = new NetConnection("tcp://127.0.0.1:9");
		Assert.equals(0, connection.outputHighWater);
		Assert.equals(0, connection.outputLowWater);
		Assert.isNull(connection.onOutputHigh);
		Assert.isNull(connection.onOutputDrained);
		Assert.raises(() -> connection.outputHighWater = -1, RangeError);
		Assert.raises(() -> connection.outputLowWater = -1, RangeError);
		connection.outputHighWater = 1024;
		connection.outputLowWater = 512;
		Assert.equals(1024, connection.outputHighWater);
		Assert.equals(512, connection.outputLowWater);
		connection.close();
	}

	/**
		What a pass sends over TCP waits for the pass to end, and counts in
		`bytesPending` until then; the marks are checked once it is handed to
		the system, so a burst a reading peer's connection takes whole is no
		backlog, and nothing is told.
	**/
	@:timeout(20000)
	public function testATcpBurstTheSystemTakesWholeTellsNothing(async:Async):Void {
		var read:Int = 0;
		var host = new NetHost("tcp://127.0.0.1:0", function(peer:INetConnection) {
			peer.onData = (input:ByteArrayInput) -> {
				read += input.bytesAvailable;
				input.position = input.length;
			};
			peer.readEnabled = true;
		}, null, null, true);
		NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
			var ready = false;
			var connection = new NetConnection('tcp://127.0.0.1:${host.localPort}', null, () -> ready = true);
			var highs = 0;
			var drains = 0;
			connection.outputHighWater = 32 * 1024;
			connection.onOutputHigh = () -> highs++;
			connection.onOutputDrained = () -> drains++;
			NetPump.until(() -> ready, 5.0, function(_) {
				connection.send(__bytes(64 * 1024));
				Assert.isTrue(connection.bytesPending >= 64 * 1024, "the pass's burst was not pending: " + connection.bytesPending);
				Assert.equals(0, highs, "a burst still in the pass was told as a backlog");
				NetPump.until(() -> read >= 64 * 1024, 5.0, function(_) {
					Assert.equals(64 * 1024, read);
					Assert.equals(0, connection.bytesPending);
					Assert.equals(0, highs, "a burst the system took whole was told as a backlog");
					Assert.equals(0, drains);
					connection.close();
					host.close();
					async.done();
				});
			});
		});
	}

	/**
		Reliable UDP's backlog is what its congestion window holds back: a
		burst past the high water is told, and the drain once the peer's
		acknowledgements have let it out. A session whose queue passes its
		`maxOutputBufferSize` ends with `Reason.Overflow`.
	**/
	// Not eval, which has no UDP.
	#if !eval
	@:timeout(20000)
	public function testAReliableSessionIsToldHighAndDrainedAndClosedForOverflow(async:Async):Void {
		var read:Int = 0;
		var host = new NetHost("rudp://127.0.0.1:0", function(peer:INetConnection) {
			peer.onData = (input:ByteArrayInput) -> {
				read += input.bytesAvailable;
				input.position = input.length;
			};
			peer.readEnabled = true;
		}, null, null, true);
		NetPump.until(() -> host.localPort != 0, 5.0, function(_) {
			var ready = false;
			var connection = new NetConnection('rudp://127.0.0.1:${host.localPort}', null, () -> ready = true);
			var highs = 0;
			var drains = 0;
			connection.outputHighWater = 16 * 1024;
			connection.outputLowWater = 0;
			connection.onOutputHigh = () -> highs++;
			connection.onOutputDrained = () -> drains++;
			NetPump.until(() -> ready, 5.0, function(_) {
				for (_ in 0...16) {
					connection.send(__bytes(8 * 1024));
				}
				Assert.equals(1, highs, "a burst past the window and the high water was not told: " + connection.bytesPending + " pending");
				NetPump.until(() -> drains > 0 && read >= 128 * 1024, 10.0, function(_) {
					Assert.equals(1, drains, "the drain was not told once");
					Assert.equals(1, highs);
					Assert.equals(0, connection.bytesPending);
					Assert.equals(128 * 1024, read);

					// Past the session's own limit: closed, and told why.
					var reasons:Array<Reason> = [];
					var errors:Array<Reason> = [];
					connection.onClose = reason -> reasons.push(reason);
					connection.onError = reason -> errors.push(reason);
					NetConnection.toReliableDatagramSocket(connection).maxOutputBufferSize = 16 * 1024;
					// More than a window grown on loopback lets out at once.
					for (_ in 0...256) {
						if (connection.connected) {
							connection.send(__bytes(8 * 1024));
						}
					}
					NetPump.until(() -> reasons.length > 0, 5.0, function(_) {
						Assert.equals(1, reasons.length);
						Assert.isTrue(reasons.length > 0 && reasons[0].match(Overflow), "an overflow ended with " + reasons);
						Assert.isTrue(errors.length > 0 && errors[0].match(Overflow), "the error was " + errors);
						Assert.equals(1, drains, "a connection that ended was told it drained");
						host.close();
						async.done();
					});
				});
			});
		});
	}
	#end
	#end

	#if (cpp || java || jvm || nodejs || eval)
	/**
		A peer that stops reading holds the connection above its high water,
		with no drain told, until it reads again; one that never does is
		closed at the socket's `maxOutputBufferSize`, as `Reason.Overflow`.
		The buffers are made small where they can be, so the kernel holds
		little; on Node and the interpreter the marks are larger than what it
		holds.
	**/
	@:timeout(30000)
	public function testATcpPeerThatStopsReadingIsHeldHighAndOneThatNeverReadsOverflows(async:Async):Void {
		var stalled = new StalledPeer(false);
		NetPump.until(() -> stalled.port != 0, 5.0, function(_) {
			var ready = false;
			var connection = new NetConnection('tcp://127.0.0.1:${stalled.port}', null, () -> ready = true);
			__smallBuffer(NetConnection.toSocket(connection));
			var highs = 0;
			var drains = 0;
			connection.outputHighWater = HIGH;
			connection.outputLowWater = LOW;
			connection.onOutputHigh = () -> highs++;
			connection.onOutputDrained = () -> drains++;
			NetPump.until(() -> ready && stalled.accepted != null, 5.0, function(_) {
				var piece = __bytes(PIECE);
				var sent = 0;
				// A piece a pass, so each pass's flush hands the kernel what it takes.
				NetPump.until(() -> {
					if (highs == 0 && sent < MOST) {
						connection.send(piece);
						sent += piece.length;
					}
					return highs > 0;
				}, 10.0, function(_) {
					Assert.equals(1, highs, "a peer that stopped reading did not take the connection past its high water");
					NetPump.wait(0.3, function() {
						Assert.equals(0, drains, "a drain was told while the peer read nothing");
						Assert.isTrue(connection.bytesPending > LOW, "the backlog went with no one reading: " + connection.bytesPending);
						stalled.readAll();
						NetPump.until(() -> drains > 0, 10.0, function(_) {
							Assert.equals(1, drains, "the drain was not told once the peer read");
							Assert.isTrue(connection.bytesPending <= LOW);
							connection.close();
							stalled.close();
							__overflowsAgainstAPeerThatNeverReads(async);
						});
					});
				});
			});
		});
	}

	private static function __overflowsAgainstAPeerThatNeverReads(async:Async):Void {
		var stalled = new StalledPeer(false);
		NetPump.until(() -> stalled.port != 0, 5.0, function(_) {
			var ready = false;
			var reasons:Array<Reason> = [];
			var errors:Array<Reason> = [];
			var connection = new NetConnection('tcp://127.0.0.1:${stalled.port}', null, () -> ready = true, reason -> reasons.push(reason),
				reason -> errors.push(reason));
			var socket = NetConnection.toSocket(connection);
			__smallBuffer(socket);
			socket.maxOutputBufferSize = LIMIT;
			NetPump.until(() -> ready && stalled.accepted != null, 5.0, function(_) {
				var piece = __bytes(PIECE);
				var sent = 0;
				NetPump.until(() -> {
					if (reasons.length == 0 && sent < MOST) {
						connection.send(piece);
						sent += piece.length;
					}
					return reasons.length > 0;
				}, 10.0, function(_) {
					Assert.equals(1, reasons.length, "a peer that never read was not closed at the output limit");
					Assert.isTrue(reasons.length > 0 && reasons[0].match(Overflow), "it ended with " + reasons);
					Assert.isTrue(errors.length > 0 && errors[0].match(Overflow), "the error was " + errors);
					stalled.close();
					async.done();
				});
			});
		});
	}

	#end

	// Not eval: a WebSocket client masks what it sends with secure random
	// bytes, which the interpreter has not got.
	#if (cpp || java || jvm || nodejs)
	/**
		The same over a WebSocket, whose frames wait in its session: held
		high while the peer reads nothing, drained once it reads, and closed
		as `Reason.Overflow` past the session's `maxOutputBufferSize`.
	**/
	@:timeout(30000)
	public function testAWebSocketToAPeerThatStopsReadingIsHeldHighThenDrainedThenOverflows(async:Async):Void {
		var stalled = new StalledPeer(true);
		NetPump.until(() -> stalled.port != 0, 5.0, function(_) {
			var ready = false;
			var reasons:Array<Reason> = [];
			var connection = new NetConnection('ws://127.0.0.1:${stalled.port}/', null, () -> ready = true, reason -> reasons.push(reason));
			var socket = NetConnection.toWebSocket(connection);
			var highs = 0;
			var drains = 0;
			connection.outputHighWater = HIGH;
			connection.outputLowWater = LOW;
			connection.onOutputHigh = () -> highs++;
			connection.onOutputDrained = () -> drains++;
			NetPump.until(() -> ready, 5.0, function(_) {
				var piece = __bytes(PIECE);
				var sent = 0;
				NetPump.until(() -> {
					if (highs == 0 && sent < MOST) {
						connection.send(piece);
						sent += piece.length;
					}
					return highs > 0;
				}, 10.0, function(_) {
					Assert.equals(1, highs, "a peer that stopped reading did not take the session past its high water");
					NetPump.wait(0.3, function() {
						Assert.equals(0, drains, "a drain was told while the peer read nothing");
						stalled.readAll();
						NetPump.until(() -> drains > 0, 10.0, function(_) {
							Assert.equals(1, drains, "the drain was not told once the peer read");
							// It stops reading again, and the session's own limit closes it.
							stalled.stopReading();
							socket.maxOutputBufferSize = LIMIT;
							sent = 0;
							NetPump.until(() -> {
								if (reasons.length == 0 && sent < MOST) {
									connection.send(piece);
									sent += piece.length;
								}
								return reasons.length > 0;
							}, 10.0, function(_) {
								Assert.isTrue(reasons.length > 0 && reasons[0].match(Overflow), "it ended with " + reasons);
								stalled.close();
								async.done();
							});
						});
					});
				});
			});
		});
	}

	#if (cpp && (windows || linux || mac || macos))
	/**
		Over local IPC what waits is what the peer has not taken: a peer
		holding its arrivals takes the connection past its high water, and
		the drain is told once it reads.
	**/
	@:timeout(20000)
	public function testALocalConnectionToAPeerThatHoldsItsArrivalsIsToldHighAndDrained(async:Async):Void {
		var name = '__crossbyte_local_marks_${Std.int(Sys.time() * 1000)}_${Std.random(1000000)}'; // time of day: a name no other run has used
		var server = new crossbyte.ipc.LocalConnection();
		var client = new crossbyte.ipc.LocalConnection();
		var read = 0;
		server.onData = (input:ByteArrayInput) -> {
			read += input.bytesAvailable;
			input.position = input.length;
		};
		// Reads are held until enabled, and no more than this is held.
		server.maxQueuedBytes = 1024 * 1024;
		server.listen(name);
		client.connect(name);
		var connection = NetConnection.fromLocalConnection(client);
		var highs = 0;
		var drains = 0;
		connection.outputHighWater = 4 * 1024 * 1024;
		connection.onOutputHigh = () -> highs++;
		connection.onOutputDrained = () -> drains++;
		NetPump.until(() -> client.connected && server.connected, 5.0, function(_) {
			var piece = __bytes(1024 * 1024);
			var sent = 0;
			NetPump.until(() -> {
				if (highs == 0 && sent < 64 * 1024 * 1024 && client.connected) {
					connection.send(piece);
					sent += piece.length;
				}
				return highs > 0;
			}, 10.0, function(_) {
				Assert.equals(1, highs, "a peer holding its arrivals did not take the connection past its high water: " + connection.bytesPending);
				Assert.equals(client.bytesPending, connection.bytesPending, "bytesPending is not the local connection's");
				NetPump.wait(0.2, function() {
					Assert.equals(0, drains, "a drain was told while the peer held everything");
					server.readEnabled = true;
					NetPump.until(() -> drains > 0 && read >= sent, 10.0, function(_) {
						Assert.equals(1, drains, "the drain was not told once the peer read");
						Assert.equals(sent, read);
						Assert.equals(0, connection.bytesPending);
						try client.close() catch (_:Dynamic) {}
						try server.close() catch (_:Dynamic) {}
						async.done();
					});
				});
			});
		});
	}
	#end
	#end

	#if (cpp || java || jvm || nodejs || eval)
	// The marks and the limit the stalled cases use, and the most they send.
	// Node and the interpreter cannot size a socket's buffers, so their
	// kernel holds more: on Linux a loopback connection takes megabytes
	// before a send would wait.
	private static inline var HIGH:Int = #if (nodejs || eval) 8 * 1024 * 1024 #else 512 * 1024 #end;
	private static inline var LOW:Int = #if (nodejs || eval) 1024 * 1024 #else 64 * 1024 #end;
	private static inline var LIMIT:Int = #if (nodejs || eval) 4 * 1024 * 1024 #else 256 * 1024 #end;
	private static inline var MOST:Int = 128 * 1024 * 1024;
	// Sent a pass, the next once the pass has handed it to the system.
	private static inline var PIECE:Int = #if (nodejs || eval) 1024 * 1024 #else 64 * 1024 #end;

	private static function __smallBuffer(socket:Socket):Void {
		if (Socket.bufferSizeSupported) {
			socket.sendBufferSize = 16 * 1024;
		}
	}
	#end

	private static function __bytes(length:Int):ByteArray {
		var bytes = new ByteArray();
		bytes.length = length;
		bytes.position = 0;
		return bytes;
	}
}

#if (cpp || java || jvm || nodejs || eval)
/**
	A server that accepts one connection (answering a WebSocket upgrade
	first, if asked) and then reads nothing, with small buffers, until told
	to read; told to stop, it stops again.
**/
private class StalledPeer {
	public var port(get, never):Int;
	public var accepted(default, null):Socket = null;

	var __server:ServerSocket;
	var __reading:Bool = false;
	var __upgraded:Bool;
	var __sink:ByteArray = new ByteArray();

	public function new(webSocket:Bool) {
		__upgraded = !webSocket;
		__server = new ServerSocket();
		if (Socket.bufferSizeSupported) {
			__server.receiveBufferSize = 16 * 1024;
		}
		__server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var socket:Socket = e.socket;
			accepted = socket;
			// Holds at most this much unread, and asks the kernel for no more.
			socket.maxInputBufferSize = 1024;
			socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_) {
				if (!__upgraded) {
					socket.readBytes(__sink, __sink.length, socket.bytesAvailable);
					var request:String = __sink.toString();
					if (request.indexOf("\r\n\r\n") < 0) {
						return;
					}
					var keyMatch = ~/Sec-WebSocket-Key: ([^\r]+)/;
					var key:String = keyMatch.match(request) ? keyMatch.matched(1) : "";
					var accept:String = haxe.crypto.Base64.encode(haxe.crypto.Sha1.make(haxe.io.Bytes.ofString(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
					socket.writeUtfBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept
						+ "\r\n\r\n");
					socket.flush();
					__upgraded = true;
					return;
				}
				if (__reading) {
					__drain();
				}
			});
		});
		__server.bind(0, "127.0.0.1");
		__server.listen();
	}

	inline function get_port():Int {
		return __server.localPort;
	}

	/** Reads what is held, and everything after, until told to stop. **/
	public function readAll():Void {
		__reading = true;
		__drain();
	}

	public function stopReading():Void {
		__reading = false;
	}

	function __drain():Void {
		if (accepted != null && accepted.connected && accepted.bytesAvailable > 0) {
			__sink.position = 0;
			__sink.length = 0;
			accepted.readBytes(__sink, 0, accepted.bytesAvailable);
		}
	}

	public function close():Void {
		try {
			if (accepted != null && accepted.connected) {
				accepted.close();
			}
		} catch (_:Dynamic) {}
		try __server.close() catch (_:Dynamic) {}
	}
}
#end
