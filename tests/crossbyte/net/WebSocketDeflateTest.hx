package crossbyte.net;

import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import utest.Assert;
#if (cpp || java || jvm || eval || nodejs)
import crossbyte.events.Event;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.WebSocketMessageEvent;
import utest.Async;
#end

/**
	permessage-deflate (RFC 7692), from a server's side and a client's.

	There was none: a server declined every browser's offer, so an 18 KB JSON
	frame went out raw at 5.7 times its deflated size, and a compressed frame,
	RSV1 set, closed the connection with 1002. Opt in with
	`perMessageDeflate`, on a `ServerWebSocket` or a client `WebSocket`.
	Each message is compressed on its own, in both directions.

	The compressed frames sent here are RFC 7692's own examples, the output
	of zlib, so what is checked is what browsers send rather than what this
	side's own compressor happens to agree with.
**/
@:access(crossbyte.net.WebSocket)
class WebSocketDeflateTest extends utest.Test {
	private static inline var OFFER:String = "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits";

	#if (cpp || java || jvm || eval || nodejs)
	@:timeout(20000)
	public function testAServerAgreesAndInflatesWhatBrowsersSend(async:Async):Void {
		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		var sessions:Array<WebSocket> = [];
		var heard:Array<String> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> heard.push(m.text));
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/", [OFFER]);

			NetPump.until(() -> {
				peer.poll();
				return peer.head() != null || peer.ended;
			}, 5.0, function(_) {
				var head:String = peer.head();
				Assert.notNull(head, "the upgrade was never answered");
				if (head != null) {
					Assert.isTrue(head.indexOf("Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover") >= 0,
						"the offer was not agreed to: " + head);
				}

				// RFC 7692 7.2.3: "Hello" as zlib sends it (a flush), with a
				// final block, and in a block left uncompressed.
				peer.sendFrame(WirePeer.TEXT, __hex("f248cdc9c90700"), true);
				peer.sendFrame(WirePeer.TEXT, __hex("f348cdc9c9070000"), true);
				peer.sendFrame(WirePeer.TEXT, __hex("000500faff48656c6c6f00"), true);
				// And one sent uncompressed, which RFC 7692 leaves to each message.
				peer.sendFrame(WirePeer.TEXT, Bytes.ofString("plain"));

				NetPump.until(() -> heard.length >= 4 || peer.ended, 5.0, function(_) {
					Assert.same(["Hello", "Hello", "Hello", "plain"], heard, "the compressed messages were not inflated");
					Assert.equals(1, sessions.length);
					if (sessions.length > 0) {
						Assert.isTrue(sessions[0].compressed, "the session does not say it agreed to compression");
					}
					Assert.isFalse(peer.ended, "the session was closed");
					peer.close();
					for (session in sessions) {
						try session.close() catch (_:Dynamic) {}
					}
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	@:timeout(20000)
	public function testAServerCompressesWhatIsWorthCompressing(async:Async):Void {
		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		var sessions:Array<WebSocket> = [];
		var large:String = __snapshot();
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.sendText(large);
			session.sendText("small");
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/", [OFFER]);

			NetPump.until(() -> {
				peer.poll();
				return peer.framesOf(WirePeer.TEXT).length >= 2 || peer.ended;
			}, 10.0, function(_) {
				var frames = peer.framesOf(WirePeer.TEXT);
				Assert.equals(2, frames.length, "the messages never arrived");
				if (frames.length == 2) {
					Assert.isTrue(frames[0].rsv1, "a " + large.length + "-byte message went uncompressed");
					Assert.isTrue(frames[0].payload.length < large.length / 3,
						'a ${large.length}-byte snapshot compressed only to ${frames[0].payload.length} bytes');
					Assert.equals(large, __inflate(frames[0].payload), "the compressed message did not inflate to what was sent");
					#if nodejs
					// And by zlib, which is what a browser inflates with.
					var withTail:Bytes = Bytes.alloc(frames[0].payload.length + 4);
					withTail.blit(0, frames[0].payload, 0, frames[0].payload.length);
					withTail.set(withTail.length - 2, 0xFF);
					withTail.set(withTail.length - 1, 0xFF);
					var inflated:js.node.Buffer = js.node.Zlib.inflateRawSync(js.node.Buffer.hxFromBytes(withTail));
					Assert.equals(large, inflated.toString("utf8"), "zlib did not inflate the compressed message to what was sent");
					#end
					Assert.isFalse(frames[1].rsv1, "a 5-byte message was compressed, under the threshold");
					Assert.equals("small", frames[1].payload.toString());
				}
				peer.close();
				for (session in sessions) {
					try session.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	@:timeout(20000)
	public function testWithoutAgreementACompressedFrameIsAProtocolError(async:Async):Void {
		var server = new ServerWebSocket();
		var closes:Array<Int> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			session.addEventListener(Event.CLOSE, function(c:Event) {
				var closed = Std.downcast(c, crossbyte.events.WebSocketCloseEvent);
				closes.push(closed == null ? -1 : closed.code);
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			// Offered, and declined: this server was not told to agree.
			peer.upgrade("/", [OFFER]);
			NetPump.until(() -> {
				peer.poll();
				return peer.head() != null || peer.ended;
			}, 5.0, function(_) {
				var head:String = peer.head();
				Assert.isTrue(head != null && head.indexOf("Sec-WebSocket-Extensions") < 0, "a server that was not told to compress agreed to: " + head);
				peer.sendFrame(WirePeer.TEXT, __hex("f248cdc9c90700"), true);
				NetPump.until(() -> closes.length > 0, 5.0, function(_) {
					Assert.same([1002], closes, "a compressed frame nobody agreed to was not refused");
					peer.close();
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	@:timeout(20000)
	public function testRsv1OnlyMarksAMessagesFirstFrame(async:Async):Void {
		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		var closes:Array<Int> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			session.addEventListener(Event.CLOSE, function(c:Event) {
				var closed = Std.downcast(c, crossbyte.events.WebSocketCloseEvent);
				closes.push(closed == null ? -1 : closed.code);
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var first = new WirePeer(server.localPort);
			var second = new WirePeer(server.localPort);
			first.upgrade("/", [OFFER]);
			second.upgrade("/", [OFFER]);
			NetPump.until(() -> {
				first.poll();
				second.poll();
				return (first.head() != null || first.ended) && (second.head() != null || second.ended);
			}, 5.0, function(_) {
				// RSV1 on a continuation, and on a ping.
				first.sendFrame(WirePeer.TEXT, Bytes.ofString("par"), false, false);
				first.sendFrame(0x0, __hex("f248cdc9c90700"), true, true);
				second.sendFrame(WirePeer.PING, Bytes.ofString("p"), true);
				NetPump.until(() -> closes.length >= 2, 5.0, function(_) {
					Assert.same([1002, 1002], closes, "RSV1 was taken somewhere RFC 7692 forbids it");
					first.close();
					second.close();
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}

	/** A message marked compressed that is not DEFLATE: 1007, as for bad UTF-8. **/
	@:timeout(20000)
	public function testDataThatIsNotDeflateIsRefused(async:Async):Void {
		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		server.maxMessageSize = 64 * 1024;
		var closes:Array<Int> = [];
		var heard:Int = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			session.addEventListener(WebSocketMessageEvent.MESSAGE, _ -> heard++);
			session.addEventListener(Event.CLOSE, function(c:Event) {
				var closed = Std.downcast(c, crossbyte.events.WebSocketCloseEvent);
				closes.push(closed == null ? -1 : closed.code);
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/", [OFFER]);
			NetPump.until(() -> {
				peer.poll();
				return peer.head() != null || peer.ended;
			}, 5.0, function(_) {
				// A first block of type 3, which DEFLATE does not have.
				peer.sendFrame(WirePeer.TEXT, __hex("ffffff"), true);
				NetPump.until(() -> closes.length > 0, 5.0, function(_) {
					Assert.same([1007], closes, "a compressed message that does not inflate was not refused as bad data");
					Assert.equals(0, heard);
					peer.close();
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end

	#if (cpp || java || jvm || eval)
	/**
		A few hundred bytes that inflate past what a message may be: refused
		as too big, and refused while inflating rather than after.
	**/
	@:timeout(30000)
	public function testAMessageThatInflatesTooFarIsRefused(async:Async):Void {
		var zeros:ByteArray = new ByteArray();
		zeros.length = 256 * 1024;
		zeros.compress(crossbyte.utils.CompressionAlgorithm.DEFLATE);
		var bomb:Bytes = Bytes.alloc(zeros.length + 1);
		bomb.blit(0, zeros, 0, zeros.length);

		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		server.maxMessageSize = 64 * 1024;
		var closes:Array<Int> = [];
		var heard:Int = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			session.addEventListener(WebSocketMessageEvent.MESSAGE, _ -> heard++);
			session.addEventListener(Event.CLOSE, function(c:Event) {
				var closed = Std.downcast(c, crossbyte.events.WebSocketCloseEvent);
				closes.push(closed == null ? -1 : closed.code);
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/", [OFFER]);
			NetPump.until(() -> {
				peer.poll();
				return peer.head() != null || peer.ended;
			}, 5.0, function(_) {
				peer.sendFrame(WirePeer.BINARY, bomb, true);
				NetPump.until(() -> closes.length > 0, 10.0, function(_) {
					Assert.isTrue(bomb.length < 4096, "the test's bomb is not small: " + bomb.length);
					Assert.same([1009], closes, "a message inflating past the limit was not refused as too big");
					Assert.equals(0, heard);
					peer.close();
					try server.close() catch (_:Dynamic) {}
					async.done();
				});
			});
		});
	}
	#end

	#if (cpp || java || jvm || nodejs)
	@:timeout(20000)
	public function testAClientAndServerAgreeAndCompressBothWays(async:Async):Void {
		var server = new ServerWebSocket();
		server.perMessageDeflate = true;
		var large:String = __snapshot();
		var sessions:Array<WebSocket> = [];
		var serverHeard:String = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> {
				serverHeard = m.text;
				session.sendText(m.text);
			});
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		client.perMessageDeflate = true;
		var clientHeard:String = null;
		client.addEventListener(Event.CONNECT, _ -> client.sendText(large));
		client.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> clientHeard = m.text);

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> clientHeard != null, 10.0, function(_) {
				Assert.isTrue(client.compressed, "the client does not say compression was agreed");
				Assert.isTrue(sessions.length > 0 && sessions[0].compressed, "the server's session does not say compression was agreed");
				Assert.equals(large, serverHeard, "the server did not get the client's compressed message whole");
				Assert.equals(large, clientHeard, "the client did not get the server's compressed message whole");
				try client.close() catch (_:Dynamic) {}
				for (session in sessions) {
					try session.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	@:timeout(20000)
	public function testAClientWithoutAgreementSendsPlainly(async:Async):Void {
		// The client asks; this server was not told to agree.
		var server = new ServerWebSocket();
		var large:String = __snapshot();
		var sessions:Array<WebSocket> = [];
		var serverHeard:String = null;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
			var session:WebSocket = cast e.socket;
			sessions.push(session);
			session.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> serverHeard = m.text);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var client = new WebSocket();
		client.perMessageDeflate = true;
		client.addEventListener(Event.CONNECT, _ -> client.sendText(large));

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) {
			client.connect("127.0.0.1", server.localPort);
			NetPump.until(() -> serverHeard != null, 10.0, function(_) {
				Assert.isFalse(client.compressed, "a client says it compresses though the server declined");
				Assert.equals(large, serverHeard);
				try client.close() catch (_:Dynamic) {}
				for (session in sessions) {
					try session.close() catch (_:Dynamic) {}
				}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}
	#end

	#if (cpp || java || jvm)
	/**
		A server that answers the offer with context takeover kept on its
		side, which this client cannot inflate: refused, as RFC 7692 has it,
		rather than taken and then failed on the second message.
	**/
	@:timeout(20000)
	public function testAClientRefusesAnAnswerItCannotKeep(async:Async):Void {
		var server = new HandServer();
		var client = new WebSocket();
		client.perMessageDeflate = true;
		var opened:Bool = false;
		var ended:Bool = false;
		client.addEventListener(Event.CONNECT, _ -> opened = true);
		client.addEventListener(Event.CLOSE, _ -> ended = true);
		client.connect("127.0.0.1", server.port);

		NetPump.until(() -> {
			server.poll("permessage-deflate");
			return ended;
		}, 10.0, function(_) {
			Assert.isTrue(server.request.indexOf("Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover") >= 0,
				"the client did not offer: " + server.request);
			Assert.isTrue(server.answered, "the test's server never answered");
			Assert.isFalse(opened, "the client took an answer it cannot inflate");
			Assert.isTrue(ended, "the client never gave up on the session");
			try client.close() catch (_:Dynamic) {}
			server.close();
			async.done();
		});
	}

	/** A server inflating each of the client's messages on its own, as it says. **/
	@:timeout(20000)
	public function testAClientCompressesForAServerInflatingEachMessageAlone(async:Async):Void {
		__exchangeWith("permessage-deflate; server_no_context_takeover; client_no_context_takeover", true, async);
	}

	/**
		A server that agrees but leaves out `client_no_context_takeover`, so
		may inflate the client's messages as one stream, which a message
		compressed on its own ends, losing every message after it. The client
		sends to it uncompressed, and still inflates what it compresses.
	**/
	@:timeout(20000)
	public function testAClientSendsPlainlyToAServerThatMayKeepItsContext(async:Async):Void {
		__exchangeWith("permessage-deflate; server_no_context_takeover", false, async);
	}

	/**
		A client's session with a server answering its offer with `answer`:
		the server sends a compressed "Hello", the client an 18 KB snapshot,
		compressed or not as `compresses` says it should be.
	**/
	private function __exchangeWith(answer:String, compresses:Bool, async:Async):Void {
		var server = new HandServer();
		var large:String = __snapshot();
		var client = new WebSocket();
		client.perMessageDeflate = true;
		var heard:String = null;
		client.addEventListener(Event.CONNECT, _ -> client.sendText(large));
		client.addEventListener(WebSocketMessageEvent.MESSAGE, (m:WebSocketMessageEvent) -> heard = m.text);
		client.connect("127.0.0.1", server.port);

		var greeted:Bool = false;
		NetPump.until(() -> {
			server.poll(answer);
			if (server.answered && !greeted) {
				// "Hello", compressed (RFC 7692 7.2.3.1).
				server.sendFrame(WirePeer.TEXT, __hex("f248cdc9c90700"), true);
				greeted = true;
			}
			return (heard != null && server.message() != null) || server.ended;
		}, 10.0, function(_) {
			Assert.isTrue(client.compressed, "the client does not say compression was agreed");
			Assert.equals("Hello", heard, "the client did not inflate the server's compressed message");
			var sent = server.message();
			Assert.notNull(sent, "the client's message never arrived");
			if (sent != null) {
				Assert.equals(compresses, sent.rsv1, compresses ? "the client did not compress, though the server inflates each message on its own" : "the client compressed for a server that may inflate its messages as one stream");
				var text:String = sent.rsv1 ? __inflate(sent.payload) : sent.payload.toString();
				Assert.equals(large, text, "the client's message did not arrive as sent");
			}
			try client.close() catch (_:Dynamic) {}
			server.close();
			async.done();
		});
	}
	#end

	/** A game-state snapshot: JSON, about 18 KB, as repetitive as they are. **/
	private static function __snapshot():String {
		var out:StringBuf = new StringBuf();
		out.add("{\"tick\":4812,\"entities\":[");
		for (i in 0...220) {
			if (i > 0) {
				out.add(",");
			}
			out.add('{"id":$i,"kind":"player","name":"player-$i","x":${(i * 37) % 1000},"y":${(i * 91) % 1000},"hp":100,"state":"idle"}');
		}
		out.add("]}");
		return out.toString();
	}

	/** A compressed frame's payload, inflated as a receiver does. **/
	private static function __inflate(payload:Bytes):String {
		var stream:ByteArray = new ByteArray();
		stream.writeBytes(payload, 0, payload.length);
		for (octet in [0x00, 0x00, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0xFF, 0xFF]) {
			stream.writeByte(octet);
		}
		stream.uncompress(crossbyte.utils.CompressionAlgorithm.DEFLATE);
		return stream.readUTFBytes(stream.length);
	}

	private static function __hex(text:String):Bytes {
		var bytes:Bytes = Bytes.alloc(text.length >> 1);
		for (i in 0...bytes.length) {
			bytes.set(i, Std.parseInt("0x" + text.substr(i * 2, 2)));
		}
		return bytes;
	}
}

#if (cpp || java || jvm)
/**
	The server end of a session, by hand: the answer to the upgrade is the
	test's to write, and what the client sends is read back frame by frame,
	masked as a client's are.
**/
private class HandServer {
	public var port(default, null):Int;
	public var request(default, null):String = "";
	public var answered(default, null):Bool = false;
	public var ended(default, null):Bool = false;

	private var __listener:sys.net.Socket;
	private var __peer:sys.net.Socket;
	private var __scratch:Bytes = Bytes.alloc(64 * 1024);
	private var __held:Bytes = Bytes.alloc(64 * 1024);
	private var __heldLength:Int = 0;

	public function new() {
		__listener = new sys.net.Socket();
		__listener.bind(new sys.net.Host("127.0.0.1"), 0);
		__listener.listen(4);
		port = __listener.host().port;
	}

	/**
		Takes the connection and whatever has arrived on it, answering the
		upgrade, with `extensions` as its `Sec-WebSocket-Extensions`,
		once the request is whole.
	**/
	public function poll(extensions:String):Void {
		if (__peer == null) {
			if (sys.net.Socket.select([__listener], [], [], 0).read.length == 0) {
				return;
			}
			__peer = __listener.accept();
			__peer.setBlocking(false);
		}
		if (ended) {
			return;
		}

		try {
			while (sys.net.Socket.select([__peer], [], [], 0).read.length > 0) {
				var got:Int = __peer.input.readBytes(__scratch, 0, __scratch.length);
				if (got <= 0) {
					ended = true;
					break;
				}
				__hold(__scratch, got);
			}
		} catch (_:haxe.io.Eof) {
			ended = true;
		} catch (_:Dynamic) {}

		if (answered) {
			return;
		}
		var end:Int = __headEnd();
		if (end < 0) {
			return;
		}
		request = __held.getString(0, end);
		__held.blit(0, __held, end, __heldLength - end);
		__heldLength -= end;

		var key = ~/Sec-WebSocket-Key: *([^\r\n]+)/i;
		if (!key.match(request)) {
			ended = true;
			return;
		}
		var accept:String = haxe.crypto.Base64.encode(haxe.crypto.Sha1.make(Bytes.ofString(key.matched(1) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
		send(Bytes.ofString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
			+ 'Sec-WebSocket-Accept: $accept\r\nSec-WebSocket-Extensions: $extensions\r\n\r\n'));
		answered = true;
	}

	/** Sends one frame, unmasked as a server's are; `rsv1` marks it compressed. **/
	public function sendFrame(opcode:Int, payload:Bytes, rsv1:Bool = false):Void {
		var out = new haxe.io.BytesBuffer();
		out.addByte(0x80 | (rsv1 ? 0x40 : 0x00) | opcode);
		if (payload.length < 126) {
			out.addByte(payload.length);
		} else {
			out.addByte(126);
			out.addByte((payload.length >> 8) & 0xFF);
			out.addByte(payload.length & 0xFF);
		}
		out.add(payload);
		send(out.getBytes());
	}

	public function send(bytes:Bytes):Void {
		var sent:Int = 0;
		while (sent < bytes.length && !ended) {
			try {
				sent += __peer.output.writeBytes(bytes, sent, bytes.length - sent);
			} catch (e:Dynamic) {
				if (Std.string(e).indexOf("Block") < 0) {
					ended = true;
				}
			}
		}
	}

	/**
		The first whole data message the client sent, whether its first
		frame was marked compressed, and its payload unmasked and joined,
		or null while it is still arriving. Control frames are passed over.
	**/
	public function message():Null<{rsv1:Bool, payload:Bytes}> {
		var at:Int = 0;
		var first:Bool = true;
		var rsv1:Bool = false;
		var joined = new haxe.io.BytesBuffer();
		while (at + 2 <= __heldLength) {
			var head:Int = __held.get(at);
			var second:Int = __held.get(at + 1);
			var length:Int = second & 0x7F;
			var header:Int = 2;
			if (length == 126) {
				if (at + 4 > __heldLength) {
					return null;
				}
				length = (__held.get(at + 2) << 8) | __held.get(at + 3);
				header = 4;
			} else if (length == 127) {
				// Nothing sent here is that long.
				return null;
			}
			var masked:Bool = (second & 0x80) != 0;
			var start:Int = at + header + (masked ? 4 : 0);
			if (start + length > __heldLength) {
				return null;
			}
			if ((head & 0x0F) < 0x8) {
				if (first) {
					rsv1 = (head & 0x40) != 0;
					first = false;
				}
				for (i in 0...length) {
					var octet:Int = __held.get(start + i);
					joined.addByte(masked ? octet ^ __held.get(at + header + (i & 3)) : octet);
				}
				if ((head & 0x80) != 0) {
					return {rsv1: rsv1, payload: joined.getBytes()};
				}
			}
			at = start + length;
		}
		return null;
	}

	public function close():Void {
		if (__peer != null) {
			try __peer.close() catch (_:Dynamic) {}
		}
		try __listener.close() catch (_:Dynamic) {}
	}

	private function __hold(bytes:Bytes, length:Int):Void {
		if (__heldLength + length > __held.length) {
			var grown:Bytes = Bytes.alloc((__heldLength + length) * 2);
			grown.blit(0, __held, 0, __heldLength);
			__held = grown;
		}
		__held.blit(__heldLength, bytes, 0, length);
		__heldLength += length;
	}

	/** Where the request's head ends, past its blank line; -1 until it has. **/
	private function __headEnd():Int {
		var i:Int = 3;
		while (i < __heldLength) {
			if (__held.get(i) == 10 && __held.get(i - 1) == 13 && __held.get(i - 2) == 10 && __held.get(i - 3) == 13) {
				return i + 1;
			}
			i++;
		}
		return -1;
	}
}
#end
