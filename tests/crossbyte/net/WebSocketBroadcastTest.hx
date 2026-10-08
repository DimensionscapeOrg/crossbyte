package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.WirePeer.WireFrame;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	One message made ready once and sent to many sessions: `PreparedMessage`,
	`WebSocket.sendPrepared` and `ServerWebSocket.broadcast`.

	Peers are `WirePeer`s, so each case reads exactly what went on the wire,
	on every target, Node included.
**/
@:access(crossbyte.net.WebSocket)
@:access(crossbyte._internal.websocket.WebSocket)
class WebSocketBroadcastTest extends utest.Test {
	private static inline var OFFER:String = "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits";

	/** Every session the server has open gets the message, text and binary, exactly. **/
	@:timeout(20000)
	public function testEverySessionGetsTheExactMessage(async:Async):Void {
		__sessions(async, 3, null, function(server, sessions, peers, done) {
			var binary = new ByteArray();
			for (i in 0...300) {
				binary.writeByte(i & 0xFF);
			}
			server.broadcast(PreparedMessage.text("héllo, wörld ✓"));
			server.broadcast(PreparedMessage.binary(binary));
			NetPump.until(() -> __allHave(peers, 2), 5.0, function(_) {
				for (i in 0...peers.length) {
					var messages = __messages(peers[i]);
					Assert.equals(2, messages.length, 'peer $i did not get both messages');
					if (messages.length == 2) {
						Assert.equals(WirePeer.TEXT, messages[0].opcode);
						Assert.equals("héllo, wörld ✓", messages[0].payload.toString());
						Assert.equals(WirePeer.BINARY, messages[1].opcode);
						Assert.equals(0, messages[1].payload.compare(__bytes(binary)), 'peer $i got other bytes than were sent');
					}
				}
				done();
			});
		});
	}

	/**
		Each length a frame's header writes differently, and messages longer
		than a frame, which go in frames of 64 KiB: every session puts each
		back together exactly.
	**/
	@:timeout(30000)
	public function testEveryLengthArrivesWhole(async:Async):Void {
		var lengths:Array<Int> = [0, 1, 125, 126, 65535, 65536, 65537, 200000];
		__sessions(async, 2, null, function(server, sessions, peers, done) {
			var sent:Array<Bytes> = [];
			for (length in lengths) {
				var bytes = Bytes.alloc(length);
				for (i in 0...length) {
					bytes.set(i, (i * 31 + length) & 0xFF);
				}
				sent.push(bytes);
				server.broadcast(PreparedMessage.binary(ByteArray.fromBytes(bytes)));
			}
			NetPump.until(() -> __allHave(peers, lengths.length), 15.0, function(_) {
				for (p in 0...peers.length) {
					var messages = __messages(peers[p]);
					Assert.equals(lengths.length, messages.length, 'peer $p got ${messages.length} messages');
					for (i in 0...messages.length) {
						Assert.equals(lengths[i], messages[i].payload.length, 'peer $p: message $i came to another length');
						Assert.equals(0, messages[i].payload.compare(sent[i]), 'peer $p: the ${lengths[i]}-byte message came back other');
					}
				}
				done();
			});
		});
	}

	/**
		`sessions` chooses who receives: those listed, once each, and only the
		open ones; a session closing is passed over without a word.
	**/
	@:timeout(20000)
	public function testAListOfSessionsChoosesWhoReceives(async:Async):Void {
		__sessions(async, 3, null, function(server, sessions, peers, done) {
			sessions[2].closeWith(1000);
			server.broadcast(PreparedMessage.text("room"), [sessions[0], sessions[2]]);
			NetPump.until(() -> __allHave([peers[0]], 1), 5.0, function(_) {
				NetPump.wait(0.2, function() {
					Assert.equals(1, __messages(peers[0]).length);
					Assert.equals(0, __messages(peers[1]).length, "a session not listed was sent the message");
					Assert.equals(0, __messages(peers[2]).length, "a session closing was sent the message");
					done();
				});
			});
		});
	}

	/**
		A broadcast from inside a message listener, of the message that
		arrived: every session, the sender included, gets it. Under
		`-D crossbyte_check_events` the arrival's payload is killed once its
		listener returns, so the broadcast made after that shows that
		preparing copied it.
	**/
	@:timeout(20000)
	public function testABroadcastOfAnArrivalFromItsListenerIsWhatArrived(async:Async):Void {
		var later:PreparedMessage = null;
		__sessions(async, 3, null, function(server, sessions, peers, done) {
			sessions[1].addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent) {
				server.broadcast(PreparedMessage.binary(e.data));
				later = PreparedMessage.binary(e.data);
			});
			var sent = Bytes.ofString("from the middle");
			peers[1].sendFrame(WirePeer.BINARY, sent);
			NetPump.until(() -> later != null && __allHave(peers, 1), 5.0, function(_) {
				// After the listener: the arrival's payload is gone by now.
				server.broadcast(later);
				NetPump.until(() -> __allHave(peers, 2), 5.0, function(_) {
					for (p in 0...peers.length) {
						var messages = __messages(peers[p]);
						Assert.equals(2, messages.length);
						for (message in messages) {
							Assert.equals("from the middle", message.payload.toString(), 'peer $p was sent other bytes');
						}
					}
					done();
				});
			});
		});
	}

	/**
		Made with `compress`, the compressed form goes to the sessions that
		agreed to permessage-deflate, and the plain one to those that did
		not; made without, every session gets it plain, which RFC 7692 leaves
		to each message.
	**/
	@:timeout(20000)
	public function testTheCompressedFormGoesToSessionsThatAgreed(async:Async):Void {
		var text:String = [for (i in 0...200) '{"id":$i,"name":"entity"}'].join(",");
		__sessions(async, 2, server -> server.perMessageDeflate = true, function(server, sessions, peers, done) {
			Assert.isTrue(sessions[0].compressed, "the first session did not agree to compression");
			Assert.isFalse(sessions[1].compressed);
			var prepared = PreparedMessage.text(text, true);
			Assert.isTrue(prepared.compressed);
			server.broadcast(prepared);
			server.broadcast(PreparedMessage.text(text));
			NetPump.until(() -> __allHave(peers, 2), 5.0, function(_) {
				var deflating = __messages(peers[0]);
				Assert.isTrue(deflating[0].rsv1, "a session that agreed was sent the plain form");
				Assert.isTrue(deflating[0].payload.length < text.length);
				Assert.equals(text, __inflate(deflating[0].payload));
				Assert.isFalse(deflating[1].rsv1, "a message made without compress went compressed");
				Assert.equals(text, deflating[1].payload.toString());
				for (message in __messages(peers[1])) {
					Assert.isFalse(message.rsv1, "a session that did not agree was sent the compressed form");
					Assert.equals(text, message.payload.toString());
				}
				done();
			});
		}, [OFFER, null]);
	}

	#if !(eval || hl || neko)
	/**
		A client sends a prepared message framed and masked as its own (the
		compressed form where it agreed to compression), and the server
		reads it as any other. Not where a client cannot be made: the
		interpreter, hl and neko have no secure random for its key.
	**/
	@:timeout(20000)
	public function testAClientSendsAPreparedMessageMaskedAsItsOwn(async:Async):Void {
		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		var heard:Array<String> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			session.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> heard.push(m.text));
		});
		server.bind(0, "127.0.0.1");
		server.listen();
		var client = new WebSocket();
		client.perMessageDeflate = true;
		var opened:Bool = false;
		var failure:String = null;
		client.addEventListener(Event.CONNECT, _ -> opened = true);
		client.addEventListener(crossbyte.events.IOErrorEvent.IO_ERROR, (e:crossbyte.events.IOErrorEvent) -> failure = e.text);
		var big:String = [for (i in 0...300) "repeat"].join(" ");
		// On Node the port is known once listening has begun.
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> opened || failure != null, 5.0, function(_) {
				if (!opened) {
					Assert.fail("the client never opened: " + failure);
					server.close();
					async.done();
					return;
				}
				Assert.isTrue(client.compressed, "the client did not agree to compression");
				client.sendPrepared(PreparedMessage.text("short"));
				client.sendPrepared(PreparedMessage.text(big, true));
				client.sendPrepared(PreparedMessage.text(big));
				NetPump.until(() -> heard.length >= 3, 5.0, function(_) {
					Assert.same(["short", big, big], heard);
					client.close();
					server.close();
					async.done();
				});
			});
		});
	}
	#end

	#if !(eval || nodejs)
	/**
		A session that closes as it is sent to (past its output limit), and
		one its close listener closes, later in the list: each is passed over,
		and every other session is sent the message once. A server's list of
		sessions loses a closing one, its last taking its place, so walking
		that list would have sent one twice or passed one over.

		Not on eval, whose sockets block, nor on Node, where what waits is
		Node's and is measured as a pass ends.
	**/
	@:timeout(90000)
	public function testSessionsClosingDuringABroadcastArePassedOver(async:Async):Void {
		__sessions(async, 4, server -> server.maxOutputBufferSize = 0, function(server, sessions, peers, done) {
			// The first falls behind: enough sent that some of it waits here.
			peers[0].pause();
			var filler = new ByteArray();
			filler.length = 256 * 1024;
			var sent:Int = 0;
			NetPump.until(() -> {
				if (sessions[0].outputBufferLength > 0 || sent >= 256 * 1024 * 1024) {
					return true;
				}
				sessions[0].sendBinary(filler);
				sent += filler.length;
				return false;
			}, 40.0, function(_) {
				Assert.isTrue(sessions[0].outputBufferLength > 0, 'nothing waited after $sent bytes, so this shows nothing');
				// One byte more than waits closes it.
				sessions[0].maxOutputBufferSize = sessions[0].outputBufferLength + 1;
				var closes:Array<Int> = [];
				sessions[0].addEventListener(Event.CLOSE, function(_) {
					closes.push(0);
					sessions[1].close();
				});
				sessions[1].addEventListener(Event.CLOSE, _ -> closes.push(1));
				server.broadcast(PreparedMessage.text("to everyone"));
				Assert.same([0, 1], closes, "the sessions did not close as they were sent to");
				NetPump.until(() -> __allHave([peers[2], peers[3]], 1), 5.0, function(_) {
					NetPump.wait(0.2, function() {
						for (p in 2...4) {
							var texts = __messages(peers[p]).filter(m -> m.opcode == WirePeer.TEXT);
							Assert.equals(1, texts.length, 'peer $p was sent the message ${texts.length} times');
						}
						Assert.equals(0, __messages(peers[1]).filter(m -> m.opcode == WirePeer.TEXT).length, "a session closed during the broadcast was sent it");
						done();
					});
				});
			});
		});
	}
	#end

	/** What a prepared message refuses, and what it says of itself. **/
	public function testAPreparedMessageRefusesWhatItCannotSend():Void {
		Assert.raises(() -> PreparedMessage.binary(null), crossbyte.errors.ArgumentError);
		var bytes = new ByteArray();
		bytes.length = 10;
		Assert.raises(() -> PreparedMessage.binary(bytes, 11), crossbyte.errors.RangeError);
		Assert.raises(() -> PreparedMessage.binary(bytes, 4, 7), crossbyte.errors.RangeError);
		var part = PreparedMessage.binary(bytes, 4, 6);
		Assert.equals(6, part.length);
		Assert.isFalse(part.isText);
		Assert.isFalse(part.compressed);
		var text = PreparedMessage.text("äö");
		Assert.isTrue(text.isText);
		Assert.equals(4, text.length);
		Assert.equals(0, PreparedMessage.text(null).length);
		// Compressing a few bytes makes them larger: no compressed form then.
		Assert.isFalse(PreparedMessage.text("hi", true).compressed);
		var socket = new WebSocket();
		Assert.raises(() -> socket.sendPrepared(text), crossbyte.errors.IOError);
		Assert.raises(() -> socket.sendPrepared(null), crossbyte.errors.ArgumentError);
		Assert.raises(() -> new ServerWebSocket().broadcast(null), crossbyte.errors.ArgumentError);
	}

	/**
		Preparing copies: the buffer it was made from can be changed straight
		after, and what is sent is what it held when the message was made.
	**/
	@:timeout(20000)
	public function testTheBufferAMessageWasMadeFromIsTheCallersAgain(async:Async):Void {
		__sessions(async, 1, null, function(server, sessions, peers, done) {
			var bytes = new ByteArray();
			bytes.writeUTFBytes("original");
			var prepared = PreparedMessage.binary(bytes);
			bytes.position = 0;
			bytes.writeUTFBytes("CHANGED!");
			sessions[0].sendPrepared(prepared);
			sessions[0].sendPrepared(prepared);
			NetPump.until(() -> __allHave(peers, 2), 5.0, function(_) {
				for (message in __messages(peers[0])) {
					Assert.equals("original", message.payload.toString());
				}
				done();
			});
		});
	}

	// ------------------------------------------------------------- helpers

	private static function __bytes(array:ByteArray):Bytes {
		var out = Bytes.alloc(array.length);
		out.blit(0, array, 0, array.length);
		return out;
	}

	/**
		The whole data messages a peer has had, each put back together from
		its frames, FIN to FIN: what a receiver hands its application. Read
		from the wire here, since `WirePeer.frames` does not say which frame
		ends a message.
	**/
	private static function __messages(peer:WirePeer):Array<WireFrame> {
		peer.poll();
		var bytes:Bytes = @:privateAccess peer.__all();
		var at:Int = @:privateAccess WirePeer.__headEnd(bytes);
		var out:Array<WireFrame> = [];
		if (at < 0) {
			return out;
		}
		at += 4;
		var opcode:Int = -1;
		var rsv1:Bool = false;
		var parts:haxe.io.BytesBuffer = null;
		while (at + 2 <= bytes.length) {
			var first:Int = bytes.get(at);
			var length:Int = bytes.get(at + 1) & 0x7F;
			var start:Int = at + 2;
			if (length == 126) {
				if (at + 4 > bytes.length) {
					break;
				}
				length = (bytes.get(at + 2) << 8) | bytes.get(at + 3);
				start = at + 4;
			} else if (length == 127) {
				if (at + 10 > bytes.length) {
					break;
				}
				length = (bytes.get(at + 6) << 24) | (bytes.get(at + 7) << 16) | (bytes.get(at + 8) << 8) | bytes.get(at + 9);
				start = at + 10;
			}
			if (start + length > bytes.length) {
				break;
			}
			at = start + length;
			var frameOpcode:Int = first & 0x0F;
			if (frameOpcode >= 0x8) {
				continue;
			}
			if (frameOpcode != 0) {
				opcode = frameOpcode;
				rsv1 = (first & 0x40) != 0;
				parts = new haxe.io.BytesBuffer();
			}
			if (parts == null) {
				continue;
			}
			parts.addBytes(bytes, start, length);
			if ((first & 0x80) != 0) {
				out.push({opcode: opcode, payload: parts.getBytes(), rsv1: rsv1});
				parts = null;
			}
		}
		return out;
	}

	private static function __allHave(peers:Array<WirePeer>, count:Int):Bool {
		for (peer in peers) {
			if (__messages(peer).length < count) {
				return false;
			}
		}
		return true;
	}

	/** A compressed message's payload, inflated as a receiver does. **/
	private static function __inflate(payload:Bytes):String {
		var stream:ByteArray = new ByteArray();
		stream.writeBytes(payload, 0, payload.length);
		for (octet in [0x00, 0x00, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0xFF, 0xFF]) {
			stream.writeByte(octet);
		}
		stream.uncompress(crossbyte.utils.CompressionAlgorithm.DEFLATE);
		return stream.readUTFBytes(stream.length);
	}

	/**
		`count` sessions on one server set up by `configure`, each upgraded by
		a `WirePeer` sending `headers[i]` if given: `then` is called with them
		in the order they connected once the server has dispatched `connect`
		for every one, and calls the `Void->Void` it is given when done.
	**/
	private function __sessions(async:Async, count:Int, configure:Null<ServerWebSocket->Void>,
			then:(ServerWebSocket, Array<WebSocket>, Array<WirePeer>, Void->Void) -> Void, ?headers:Array<Null<String>>):Void {
		var server = new ServerWebSocket();
		if (configure != null) {
			configure(server);
		}
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> sessions.push(cast e.socket));
		server.bind(0, "127.0.0.1");
		server.listen();

		var peers:Array<WirePeer> = [];
		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			function next():Void {
				if (peers.length >= count) {
					then(server, sessions, peers, function() {
						for (peer in peers) {
							peer.close();
						}
						for (session in sessions) {
							try session.close() catch (_:Dynamic) {}
						}
						server.close();
						async.done();
					});
					return;
				}
				var peer = new WirePeer(server.localPort);
				var header:Null<String> = headers == null ? null : headers[peers.length];
				peer.upgrade("/", header == null ? null : [header]);
				peers.push(peer);
				// One at a time, so the sessions are in the order of the peers.
				NetPump.until(() -> {
					peer.poll();
					return sessions.length >= peers.length;
				}, 5.0, function(_) {
					if (sessions.length < peers.length) {
						Assert.fail("a session never opened");
						server.close();
						async.done();
						return;
					}
					next();
				});
			}
			next();
		});
	}
}
