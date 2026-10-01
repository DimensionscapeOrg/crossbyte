package crossbyte.net;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.OutputProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.events.TickEvent;
import crossbyte.events.WebSocketCloseEvent;
import crossbyte.events.WebSocketMessageEvent;
import crossbyte.io.ByteArray;
import haxe.io.Bytes;
import utest.Assert;
import utest.Async;

/**
	A WebSocket session end to end: how it is let in, how it knows its peer is
	still there, and how it ends.

	- The upgrade request was parsed and thrown away, so a server could not
	  authenticate a session, check where a page came from, or accept a
	  subprotocol -- and a browser that offered one could not connect at all.
	  Accepted sessions reported no address, every message was binary, and
	  messages ran together into one stream.
	- There was no heartbeat and no idle timeout, and every session was read
	  on every tick whether or not anything had arrived.
	- A close frame carried no code, and the connection closed straight after
	  queueing it, taking it and anything before it along.
**/
@:access(crossbyte.core.CrossByte)
@:access(crossbyte.events.EventDispatcher)
@:access(crossbyte.net.WebSocket)
@:access(crossbyte._internal.websocket.WebSocket)
class WebSocketSessionTest extends utest.Test {
	/**
		What one turn of Node's event loop sends a session goes to its socket
		in one write when the turn ends. Each frame was a `write` of its own,
		and a server relaying a chat room's messages to everyone in it made one
		for every message to every member.
	**/
	public function testWhatOneTurnSendsGoesToTheSocketInOneWrite():Void {
		#if nodejs
		var writes:Array<Bytes> = [];
		var socket:Dynamic = {
			write: function(buffer:js.node.Buffer):Bool {
				writes.push(Bytes.ofData(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.length)));
				return true;
			},
			writableLength: 0
		};
		var ws:crossbyte._internal.websocket.WebSocket = Type.createEmptyInstance(crossbyte._internal.websocket.WebSocket);
		ws.readyState = crossbyte._internal.websocket.WebSocket.OPEN;
		ws.__socket = socket;
		ws.__connected = true;
		ws.__isClient = false;
		// An empty instance has no field initialisers run, and on JavaScript an
		// Int left so is undefined rather than 0.
		ws.__pendingSent = 0;
		ws.__passFlushQueued = false;
		ws.maxOutputBufferSize = 0;
		ws.__output = new ByteArray();
		ws.__output.endian = BIG_ENDIAN;
		ws.__pendingOutput = new ByteArray();
		ws.__pendingOutput.endian = BIG_ENDIAN;
		ws.__outgoingMessageBuffer = new ByteArray();
		ws.__outgoingMessageBuffer.endian = BIG_ENDIAN;
		ws.__runtime = CrossByte.current();

		for (i in 0...10) {
			ws.sendString("message " + i);
		}
		CrossByte.current().__flushHeld();

		Assert.equals(1, writes.length, "ten messages sent in one turn went in " + writes.length + " writes");
		var sent:Bytes = writes.length > 0 ? writes[0] : Bytes.alloc(0);
		Assert.equals(110, sent.length, "ten frames of 11 bytes did not all go");
		if (sent.length == 110) {
			for (i in 0...10) {
				Assert.equals(0x81, sent.get(i * 11), "frame " + i + " is not a final text frame");
				Assert.equals(9, sent.get(i * 11 + 1), "frame " + i + " has the wrong length");
				Assert.equals("message " + i, sent.getString(i * 11 + 2, 9));
			}
		}
		#else
		Assert.pass();
		#end
	}

	#if (cpp || java || jvm || nodejs)
	// ---- The upgrade ----------------------------------------------------

	@:timeout(15000)
	public function testTheServerSeesTheUpgradeRequest(async:Async):Void {
		var seen:WebSocketRequest = null;

		__serve(function(server) {
			server.upgrade = function(request:WebSocketRequest):Bool {
				seen = request;
				return true;
			};
		}, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/rooms/42?token=abc&x=1", ["Origin: https://example.com", "Cookie: session=s3cret; theme=dark", "X-Trace: t-1"]);

			NetPump.until(() -> {
				peer.poll();
				return sessions.length > 0;
			}, 5.0, function(_) {
				if (seen == null) {
					Assert.fail("the upgrade hook was never asked");
				} else {
					Assert.equals("GET", seen.method);
					Assert.equals("/rooms/42", seen.path);
					Assert.equals("token=abc&x=1", seen.query);
					Assert.equals("https://example.com", seen.origin);
					Assert.equals("s3cret", seen.cookie("session"));
					Assert.equals("dark", seen.cookie("theme"));
					Assert.equals("t-1", seen.header("X-TRACE"));
					Assert.equals("127.0.0.1", seen.remoteAddress);
					Assert.isTrue(seen.remotePort > 0);
				}
				Assert.equals(1, sessions.length, "the accepted upgrade did not open a session");
				if (sessions.length > 0) {
					Assert.equals(seen, sessions[0].request, "the session does not carry the request it was opened by");
				}
				peer.close();
				finish();
			});
		}, async);
	}

	@:timeout(15000)
	public function testARefusedUpgradeIsAnsweredWithItsStatusAndNoSession(async:Async):Void {
		__serve(function(server) {
			server.upgrade = function(request:WebSocketRequest):Bool {
				request.status = 401;
				return request.header("authorization") == "Bearer good";
			};
		}, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/", ["Authorization: Bearer bad"]);

			NetPump.until(() -> {
				peer.poll();
				return peer.ended;
			}, 5.0, function(_) {
				var head:String = peer.head();
				Assert.notNull(head, "the refusal was never answered");
				if (head != null) {
					Assert.isTrue(StringTools.startsWith(head, "HTTP/1.1 401"), "refused with the wrong status: " + head);
				}
				Assert.isTrue(peer.ended, "the refused connection was left open");
				Assert.equals(0, sessions.length, "a refused upgrade opened a session");
				Assert.equals(0, server.clientCount);
				peer.close();
				finish();
			});
		}, async);
	}

	@:timeout(15000)
	public function testAHookThatThrowsRefusesWithAServerError(async:Async):Void {
		__serve(function(server) {
			server.upgrade = function(request:WebSocketRequest):Bool {
				throw "the hook broke";
			};
		}, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/");

			NetPump.until(() -> {
				peer.poll();
				return peer.ended;
			}, 5.0, function(_) {
				var head:String = peer.head();
				Assert.isTrue(head != null && StringTools.startsWith(head, "HTTP/1.1 500"), "a hook that threw was not a refusal: " + head);
				Assert.equals(0, sessions.length);
				peer.close();
				finish();
			});
		}, async);
	}

	@:timeout(15000)
	public function testTheFirstOfferedSubprotocolIsAcceptedAndEchoed(async:Async):Void {
		// What a browser offering a subprotocol needs: to hear one back, or it
		// fails the connection with 1006.
		__serve(null, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/", ["Sec-WebSocket-Protocol: chat.v2, chat.v1"]);

			NetPump.until(() -> {
				peer.poll();
				return peer.head() != null && sessions.length > 0;
			}, 5.0, function(_) {
				var head:String = peer.head();
				Assert.isTrue(head != null && head.indexOf("\r\nSec-WebSocket-Protocol: chat.v2") >= 0, "the subprotocol was not echoed: " + head);
				if (sessions.length > 0) {
					Assert.equals("chat.v2", sessions[0].protocol);
				}
				peer.close();
				finish();
			});
		}, async);
	}

	@:timeout(15000)
	public function testAClientGetsTheSubprotocolTheServerChose(async:Async):Void {
		var offered:Array<String> = null;

		__serve(function(server) {
			server.upgrade = function(request:WebSocketRequest):Bool {
				offered = request.protocols;
				request.protocol = "json.v1";
				return true;
			};
		}, function(server, sessions, finish) {
			var client = new WebSocket();
			client.protocols = ["msgpack.v1", "json.v1"];
			var opened:Bool = false;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				Assert.isTrue(opened, "the client never connected");
				Assert.same(["msgpack.v1", "json.v1"], offered, "the server was not shown what the client offered");
				Assert.equals("json.v1", client.protocol, "the client does not know which subprotocol it got");
				if (sessions.length > 0) {
					Assert.equals("json.v1", sessions[0].protocol);
				}
				try client.close() catch (_:Dynamic) {}
				finish();
			});
		}, async);
	}

	@:timeout(15000)
	public function testAnAcceptedSessionKnowsBothEnds(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var client = new WebSocket();
			var opened:Bool = false;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				if (sessions.length > 0) {
					var session = sessions[0];
					Assert.equals("127.0.0.1", session.remoteAddress, "an accepted session does not know its peer's address");
					Assert.equals(client.localPort, session.remotePort, "an accepted session does not know its peer's port");
					Assert.equals(server.localPort, session.localPort);
					Assert.equals("127.0.0.1", client.remoteAddress);
					Assert.equals(server.localPort, client.remotePort);
				} else {
					Assert.fail("no session");
				}
				try client.close() catch (_:Dynamic) {}
				finish();
			});
		}, async);
	}

	/**
		A number written into a new ByteArray reads back as itself from the
		message that carried it. A message came big-endian -- the byte order of
		the buffer the frame parser filled -- whatever the session's own
		`endian` said, and a ByteArray an application makes is little-endian.
	**/
	@:timeout(15000)
	public function testANumberSentIsTheNumberRead(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var client = new WebSocket();
			var number:Null<Int> = null;
			var fraction:Null<Float> = null;
			var opened:Bool = false;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent) {
				e.data.position = 0;
				number = e.data.readInt();
				fraction = e.data.readDouble();
			});
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}
				var message = new ByteArray();
				message.writeInt(0x01020304);
				message.writeDouble(-1.25);
				sessions[0].sendBinary(message);

				NetPump.until(() -> number != null, 5.0, function(_) {
					Assert.equals(0x01020304, number, "the int came back as " + StringTools.hex(number == null ? 0 : number, 8));
					Assert.equals(-1.25, fraction);
					try client.close() catch (_:Dynamic) {}
					finish();
				});
			});
		}, async);
	}

	/**
		A WebSocket tells its writer as what it sent reaches the network,
		down to nothing left waiting, as a Socket does: it is one, and the
		event was never dispatched for either.
	**/
	@:timeout(15000)
	public function testAWriterIsToldAsWhatItSentReachesTheNetwork(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var count:Int = 16;
			var size:Int = 60 * 1024;
			var client = new WebSocket();
			var opened:Bool = false;
			var received:Int = 0;
			var pending:Array<Float> = [];
			var total:Float = 0;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(OutputProgressEvent.OUTPUT_PROGRESS, function(e:OutputProgressEvent) {
				pending.push(e.bytesPending);
				total = e.bytesTotal;
			});
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}
				sessions[0].addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent) received += e.data.length);

				var message = new ByteArray();
				message.length = size;
				for (_ in 0...count) {
					client.writeBytes(message, 0, size);
					client.flush();
				}

				NetPump.until(() -> received >= count * size && pending.length > 0 && pending[pending.length - 1] == 0, 10.0, function(_) {
					Assert.equals(count * size, received, "not everything sent arrived");
					Assert.isTrue(pending.length > 0, "nothing said what was sent had gone");
					if (pending.length > 0) {
						Assert.equals(0., pending[pending.length - 1], "the last OUTPUT_PROGRESS left " + pending[pending.length - 1] + " bytes waiting");
					}
					// Each message's frame header and mask are sent too.
					Assert.isTrue(total >= count * size, "bytesTotal " + total + " is less than the " + (count * size) + " bytes of payload");
					try client.close() catch (_:Dynamic) {}
					finish();
				});
			});
		}, async);
	}

	@:timeout(15000)
	public function testMessagesArriveOneAtATimeAndTextAsText(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var client = new WebSocket();
			var messages:Array<WebSocketMessageEvent> = [];
			var opened:Bool = false;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent) messages.push(e));
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}

				var session = sessions[0];
				session.sendText('{"hello":"json"}');
				var binary = new ByteArray();
				binary.writeByte(1);
				binary.writeByte(2);
				session.sendBinary(binary);
				session.sendText("second");

				NetPump.until(() -> messages.length >= 3, 5.0, function(_) {
					Assert.equals(3, messages.length, "three messages did not arrive as three");
					if (messages.length >= 3) {
						Assert.isTrue(messages[0].isText);
						Assert.equals('{"hello":"json"}', messages[0].text);
						Assert.isFalse(messages[1].isText);
						Assert.equals(2, messages[1].data.length);
						Assert.equals("second", messages[2].text);
					}
					// Delivered as messages, and so not also into a stream
					// nobody is reading.
					Assert.equals(0, client.bytesAvailable);
					try client.close() catch (_:Dynamic) {}
					finish();
				});
			});
		}, async);
	}

	// ---- Liveness -------------------------------------------------------

	@:timeout(15000)
	public function testAQuietPeerIsPinged(async:Async):Void {
		__serve(function(server) {
			server.pingInterval = 0.2;
			server.idleTimeout = 0;
		}, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/");

			NetPump.until(() -> {
				peer.poll();
				return peer.framesOf(WirePeer.PING).length >= 2;
			}, 5.0, function(_) {
				Assert.isTrue(peer.framesOf(WirePeer.PING).length >= 2, "a quiet peer was never pinged");
				peer.close();
				finish();
			});
		}, async);
	}

	@:timeout(15000)
	public function testAPeerThatNeverAnswersIsClosedAfterTheIdleTimeout(async:Async):Void {
		var code:Int = -1;
		var reason:String = null;

		__serve(function(server) {
			server.pingInterval = 0.2;
			server.idleTimeout = 0.6;
			server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) {
				e.socket.addEventListener(Event.CLOSE, function(closed:Event) {
					var close = Std.downcast(closed, WebSocketCloseEvent);
					code = close == null ? 0 : close.code;
				});
				e.socket.addEventListener(IOErrorEvent.IO_ERROR, function(error:IOErrorEvent) reason = error.text);
			});
		}, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/");

			NetPump.until(() -> {
				peer.poll();
				return code != -1;
			}, 5.0, function(_) {
				Assert.equals(1006, code, "a peer that answered nothing was never given up");
				Assert.isTrue(reason != null && reason.indexOf("idle") >= 0, "the close did not say the peer was idle: " + reason);
				Assert.equals(0, server.clientCount, "the dead session is still counted");
				peer.close();
				finish();
			});
		}, async);
	}

	@:timeout(15000)
	public function testAPeerThatAnswersPingsStaysUp(async:Async):Void {
		__serve(function(server) {
			server.pingInterval = 0.2;
			server.idleTimeout = 0.6;
		}, function(server, sessions, finish) {
			var client = new WebSocket();
			client.pingInterval = 0;
			client.idleTimeout = 0;
			var opened:Bool = false;
			var closed:Bool = false;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(Event.CLOSE, function(_) closed = true);
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened, 5.0, function(_) {
				// Three idle timeouts, nothing sent either way but the pings.
				NetPump.wait(2.0, function() {
					Assert.isFalse(closed, "a peer answering every ping was closed as idle");
					Assert.equals(1, server.clientCount);
					try client.close() catch (_:Dynamic) {}
					finish();
				});
			});
		}, async);
	}

	@:timeout(15000)
	public function testSessionsAreNotVisitedEveryTick(async:Async):Void {
		var before:Int = __tickListeners();

		__serve(null, function(server, sessions, finish) {
			var clients:Array<WebSocket> = [];
			for (_ in 0...4) {
				var client = new WebSocket();
				client.connect("127.0.0.1", server.localPort);
				clients.push(client);
			}

			NetPump.until(() -> sessions.length == 4 && Lambda.count(clients, c -> c.connected) == 4, 5.0, function(_) {
				// Every open session, either end, used to add a tick listener
				// of its own and be read on every tick. What is left is the
				// server's accept loop.
				Assert.isTrue(__tickListeners() - before <= 1, 'eight open sessions add ${__tickListeners() - before} tick listeners');
				for (client in clients) {
					try client.close() catch (_:Dynamic) {}
				}
				finish();
			});
		}, async);
	}

	// ---- Closing --------------------------------------------------------

	@:timeout(15000)
	public function testACloseFrameCarriesItsCodeAndReason(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/");

			NetPump.until(() -> {
				peer.poll();
				return sessions.length > 0;
			}, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}

				sessions[0].closeWith(4001, "bye");

				NetPump.until(() -> {
					peer.poll();
					return peer.framesOf(WirePeer.CLOSE).length > 0;
				}, 5.0, function(_) {
					var closes = peer.framesOf(WirePeer.CLOSE);
					Assert.equals(1, closes.length, "no close frame arrived");
					if (closes.length > 0) {
						var payload:Bytes = closes[0].payload;
						Assert.isTrue(payload.length >= 2, "the close frame carried no code");
						if (payload.length >= 2) {
							Assert.equals(4001, (payload.get(0) << 8) | payload.get(1));
							Assert.equals("bye", payload.getString(2, payload.length - 2));
						}
					}
					peer.close();
					finish();
				});
			});
		}, async);
	}

	@:timeout(15000)
	public function testBothEndsReportTheCodeAndReasonTheirPeerSent(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var client = new WebSocket();
			var opened:Bool = false;
			var clientClose:WebSocketCloseEvent = null;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(Event.CLOSE, function(e:Event) clientClose = Std.downcast(e, WebSocketCloseEvent));
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}

				var serverClose:WebSocketCloseEvent = null;
				var session = sessions[0];
				session.addEventListener(Event.CLOSE, function(e:Event) serverClose = Std.downcast(e, WebSocketCloseEvent));
				session.closeWith(4001, "bye");

				NetPump.until(() -> clientClose != null && serverClose != null, 5.0, function(_) {
					Assert.notNull(clientClose, "the client never heard the close");
					if (clientClose != null) {
						Assert.equals(4001, clientClose.code);
						Assert.equals("bye", clientClose.reason);
					}
					Assert.notNull(serverClose, "the server's session never finished closing");
					if (serverClose != null) {
						// The client's answer, which echoes the code it was sent.
						Assert.equals(4001, serverClose.code);
					}
					finish();
				});
			});
		}, async);
	}

	@:timeout(30000)
	public function testWhatWasQueuedBeforeACloseStillArrives(async:Async):Void {
		// More than a loopback socket's buffers hold, so most of it is still
		// queued here when the close is asked for -- which is what the close
		// used to throw away, along with its own frame.
		var size:Int = 8 * 1024 * 1024;

		__serve(null, function(server, sessions, finish) {
			var client = new WebSocket();
			var opened:Bool = false;
			var received:Int = 0;
			var clientClose:WebSocketCloseEvent = null;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(WebSocketMessageEvent.MESSAGE, function(e:WebSocketMessageEvent) received += e.data.length);
			client.addEventListener(Event.CLOSE, function(e:Event) clientClose = Std.downcast(e, WebSocketCloseEvent));
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}

				var session = sessions[0];
				var chunk = new ByteArray();
				chunk.length = 64 * 1024;
				for (_ in 0...Std.int(size / chunk.length)) {
					session.sendBinary(chunk);
				}
				session.closeWith(1000, "done");

				NetPump.until(() -> clientClose != null, 20.0, function(_) {
					Assert.equals(size, received, "what was queued before the close did not all arrive");
					Assert.notNull(clientClose, "the close never arrived after what was queued");
					if (clientClose != null) {
						Assert.equals(1000, clientClose.code);
					}
					finish();
				});
			});
		}, async);
	}

	@:timeout(20000)
	public function testDrainingTellsClientsTheServerIsGoingAway(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var client = new WebSocket();
			var opened:Bool = false;
			var clientClose:WebSocketCloseEvent = null;
			client.addEventListener(Event.CONNECT, function(_) opened = true);
			client.addEventListener(Event.CLOSE, function(e:Event) clientClose = Std.downcast(e, WebSocketCloseEvent));
			client.connect("127.0.0.1", server.localPort);

			NetPump.until(() -> opened && sessions.length > 0, 5.0, function(_) {
				var drained:Bool = false;
				var started:Float = haxe.Timer.stamp();
				server.drain(10.0, () -> drained = true);

				NetPump.until(() -> drained && clientClose != null, 12.0, function(_) {
					Assert.notNull(clientClose, "the client was never told");
					if (clientClose != null) {
						Assert.equals(1001, clientClose.code, "the client was not told the server is going away");
					}
					// The client answers at once, so the drain ends then rather
					// than at its timeout.
					Assert.isTrue(drained && haxe.Timer.stamp() - started < 5.0, "draining waited for its timeout");
					finish();
				});
			});
		}, async, false);
	}

	@:timeout(15000)
	public function testAClosePeerNeverAnswersEndsAtTheDeadlineAs1006(async:Async):Void {
		var deadline:Float = crossbyte._internal.websocket.WebSocket.CLOSE_TIMEOUT;
		crossbyte._internal.websocket.WebSocket.CLOSE_TIMEOUT = 0.5;

		__serve(null, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade("/");

			NetPump.until(() -> {
				peer.poll();
				return sessions.length > 0;
			}, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}

				var code:Int = -1;
				sessions[0].addEventListener(Event.CLOSE, function(e:Event) {
					var close = Std.downcast(e, WebSocketCloseEvent);
					code = close == null ? 0 : close.code;
				});
				sessions[0].closeWith(4001, "bye");

				// The peer reads the close and never answers it.
				NetPump.until(() -> {
					peer.poll();
					return code != -1;
				}, 5.0, function(_) {
					crossbyte._internal.websocket.WebSocket.CLOSE_TIMEOUT = deadline;
					Assert.equals(1006, code, "a close the peer never answered did not end at the deadline");
					peer.close();
					finish();
				});
			});
		}, async);
	}

	// ---- Output -----------------------------------------------------------

	/**
		A session whose peer has stopped reading is closed at its output
		limit, and counts what is waiting on the way there.

		On Node what waits is in Node's own queue, which the session never
		looked at: its backlog read 0 however much was waiting, and the limit
		was checked after a return that path always took -- so a session to a
		peer that had stopped reading grew without bound.
	**/
	@:timeout(60000)
	public function testASessionPastItsOutputLimitIsClosed(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade();

			NetPump.until(() -> {
				peer.poll();
				return sessions.length > 0 && peer.head() != null;
			}, 5.0, function(_) {
				peer.pause();

				var session = sessions[0];
				var limit:Int = 256 * 1024;
				// Far past what the kernel holds for a stalled loopback peer.
				var ceiling:Int = 64 * 1024 * 1024;
				var code:Int = -1;
				var written:Int = 0;
				var largest:Int = 0;
				var chunk = new ByteArray();
				chunk.length = 64 * 1024;

				session.maxOutputBufferSize = limit;
				session.addEventListener(Event.CLOSE, function(e:Event) {
					var close = Std.downcast(e, WebSocketCloseEvent);
					code = close == null ? 0 : close.code;
				});

				NetPump.until(() -> {
					if (code == -1 && written < ceiling) {
						try {
							session.sendBinary(chunk);
							written += chunk.length;
							if (session.outputBufferLength > largest) {
								largest = session.outputBufferLength;
							}
						} catch (_:Dynamic) {
							// Sent after the limit closed it.
						}
					}
					return code != -1 || written >= ceiling;
				}, 40.0, function(_) {
					Assert.equals(1011, code, 'wrote $written bytes to a peer that reads nothing and the $limit byte limit never closed the session');
					Assert.isTrue(largest > 0, "outputBufferLength never counted anything waiting to be sent");
					peer.close();
					finish();
				});
			});
		}, async);
	}

	/**
		`writeBytes` refuses a range outside `bytes`, as its doc promises and
		as `DatagramSocket.send` does, where it wrote whatever part of the
		range fell inside and said nothing. `sendBinary` likewise.
	**/
	@:timeout(15000)
	public function testARangeOutsideTheBytesIsRefused(async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade();

			NetPump.until(() -> {
				peer.poll();
				return sessions.length > 0;
			}, 5.0, function(_) {
				if (sessions.length == 0) {
					Assert.fail("no session");
					finish();
					return;
				}

				var session = sessions[0];
				var bytes = new ByteArray();
				bytes.length = 4;

				Assert.raises(() -> session.writeBytes(bytes, 5), crossbyte.errors.RangeError);
				Assert.raises(() -> session.writeBytes(bytes, -1), crossbyte.errors.RangeError);
				Assert.raises(() -> session.writeBytes(bytes, 0, 5), crossbyte.errors.RangeError);
				Assert.raises(() -> session.writeBytes(bytes, 2, 3), crossbyte.errors.RangeError);
				Assert.raises(() -> session.writeBytes(null), crossbyte.errors.ArgumentError);
				Assert.raises(() -> session.sendBinary(bytes, 5), crossbyte.errors.RangeError);
				Assert.raises(() -> session.sendBinary(bytes, 2, 3), crossbyte.errors.RangeError);
				Assert.equals(0, session.__output.length, "a refused range wrote something");

				// In range, it is all taken; and an offset at the end is nothing.
				session.writeBytes(bytes, 1, 3);
				session.writeBytes(bytes, 4);
				Assert.equals(3, session.__output.length, "a range inside the bytes was not written whole");
				session.__output.clear();

				peer.close();
				finish();
			});
		}, async);
	}

	/**
		The output limit honours `outputOverflowPolicy`, as `Socket`'s does.
		`CLOSE`, the default, says why before it closes: an `ioError`, then
		`close` with 1011. The session closed without a word.
	**/
	@:timeout(60000)
	public function testAnOverflowIsReportedBeforeTheSessionCloses(async:Async):Void {
		__overflow(CLOSE, function(outcome) {
			Assert.same(["ioError", "close 1011"], outcome.events, 'wrote ${outcome.written} bytes, and the session did not report its overflow and then close');
			Assert.isFalse(outcome.threw, "the CLOSE policy threw from a send");
			Assert.isTrue(outcome.failure != null && outcome.failure.indexOf("limit") >= 0, "the ioError did not say why: " + outcome.failure);
		}, async);
	}

	/**
		`THROW` throws an `IOError` from the send that leaves the session past
		its limit, and keeps the session -- for a writer that would rather
		shed what it sends than lose the peer. It was ignored, and the session
		closed with 1011 regardless.
	**/
	@:timeout(60000)
	public function testTheThrowPolicyThrowsAndKeepsTheSession(async:Async):Void {
		__overflow(THROW, function(outcome) {
			Assert.isTrue(outcome.threw, 'wrote ${outcome.written} bytes past the limit and no send threw');
			Assert.same([], outcome.events, "the THROW policy closed the session");
			Assert.isTrue(outcome.connected, "the session was not kept");
		}, async);
	}

	/**
		A server session with a 256 KB output limit under `policy`, to a peer
		that has stopped reading, sent 64 KB at a time until it closes, a send
		throws, or far more than the kernel can hold has been sent.
	**/
	private function __overflow(policy:OutputOverflowPolicy, check:OverflowOutcome->Void, async:Async):Void {
		__serve(null, function(server, sessions, finish) {
			var peer = new WirePeer(server.localPort);
			peer.upgrade();

			NetPump.until(() -> {
				peer.poll();
				return sessions.length > 0 && peer.head() != null;
			}, 5.0, function(_) {
				peer.pause();

				var session = sessions[0];
				var outcome:OverflowOutcome = {events: [], failure: null, threw: false, connected: false, written: 0};
				var chunk = new ByteArray();
				chunk.length = 64 * 1024;
				// Far past what the kernel holds for a stalled loopback peer.
				var ceiling:Int = 64 * 1024 * 1024;

				session.maxOutputBufferSize = 256 * 1024;
				session.outputOverflowPolicy = policy;
				session.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) {
					outcome.events.push("ioError");
					outcome.failure = e.text;
				});
				session.addEventListener(Event.CLOSE, function(e:Event) {
					var close = Std.downcast(e, WebSocketCloseEvent);
					outcome.events.push("close " + (close == null ? "?" : Std.string(close.code)));
				});

				NetPump.until(() -> {
					// Nothing more once the session has said anything.
					if (outcome.events.length == 0 && !outcome.threw && outcome.written < ceiling) {
						try {
							session.sendBinary(chunk);
							outcome.written += chunk.length;
						} catch (e:crossbyte.errors.IOError) {
							outcome.threw = true;
						}
					}
					var closed:Bool = outcome.events.length > 0 && StringTools.startsWith(outcome.events[outcome.events.length - 1], "close");
					return outcome.threw || closed || outcome.written >= ceiling;
				}, 40.0, function(_) {
					// A moment, for anything dispatched after.
					NetPump.wait(0.2, function() {
						outcome.connected = session.connected;
						check(outcome);
						peer.close();
						finish();
					});
				});
			});
		}, async);
	}

	// ---- Scaffolding ----------------------------------------------------

	/**
		A server, configured by `configure`, bound to a port, with the
		sessions it opens collected; `body` runs once the port is known, and
		everything is closed when it calls `finish`.
	**/
	private function __serve(configure:Null<ServerWebSocket->Void>, body:(ServerWebSocket, Array<WebSocket>, Void->Void)->Void, async:Async,
			closeServer:Bool = true):Void {
		var server = new ServerWebSocket();
		var sessions:Array<WebSocket> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent) sessions.push(cast e.socket));
		if (configure != null) {
			configure(server);
		}
		server.bind(0, "127.0.0.1");
		server.listen();

		function finish():Void {
			for (session in sessions) {
				try session.close() catch (_:Dynamic) {}
			}
			if (closeServer) {
				try server.close() catch (_:Dynamic) {}
			}
			// Settle what closing started, so it does not surface in the next
			// case.
			NetPump.wait(0.1, () -> async.done());
		}

		NetPump.until(() -> server.localPort != 0, 5.0, function(_) body(server, sessions, finish));
	}

	private static function __tickListeners():Int {
		var runtime:CrossByte = CrossByte.current();
		var listeners:Array<Dynamic> = runtime.__eventMap == null ? null : runtime.__eventMap.get(TickEvent.TICK);
		return listeners == null ? 0 : listeners.length;
	}
	#end
}

private typedef OverflowOutcome = {
	/** `ioError` and `close <code>`, in the order they were dispatched. **/
	var events:Array<String>;
	var failure:String;
	var threw:Bool;
	var connected:Bool;
	var written:Int;
}
