package crossbyte.http;

import crossbyte.events.Event;
import crossbyte.events.OutputProgressEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
 * A request's body read as it arrives (`HTTPRequestHandler.streamRequestBody`)
 * under HTTP/1.1: the bytes, how the client is held back, and each way it can
 * end. `HTTPServerH2Test` has the same over HTTP/2.
 */
@:timeout(30000)
@:access(crossbyte.http.HTTPRequestHandler)
@:access(crossbyte.net.Socket)
class HTTPBodyReaderTest extends utest.Test {
	/** The chain runs at the head, with the body still to come, and each piece arrives as it was sent. **/
	public function testPiecesArriveAsTheyAreSentAndTheChainRunsAtTheHead(async:Async):Void {
		var got:String = "";
		var pieces:Int = 0;
		var ended:Int = 0;
		var bodyWhenRouted:Int = -1;
		var routedAt:Int = -1;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (data, offset, length) -> {
				got += __text(data, offset, length);
				pieces++;
				return true;
			};
			body.onEnd = () -> {
				ended++;
				handler.respond(200, "text/plain", "got " + got.length);
			};
			return true;
		}, handler -> {
			routedAt = pieces;
			bodyWhenRouted = handler.requestBody.length;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n");
		client.onConnected = function():Void {
			client.after(0.05, () -> client.send("hello"));
			client.after(0.15, () -> client.send("world"));
		};
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals("helloworld", got);
			Assert.isTrue(pieces >= 2, "the body came in one piece, so it was held: " + pieces);
			Assert.equals(1, ended, "onEnd was not called once");
			Assert.equals(0, routedAt, "the chain waited for the body");
			Assert.equals(0, bodyWhenRouted, "requestBody held something");
			Assert.isTrue(client.raw.indexOf("got 10") >= 0, client.raw);
			async.done();
		});
	}

	/** Chunked framing comes off, across reads that split it anywhere, and a trailer section is read and dropped. **/
	public function testChunkedFramingComesOffAcrossAnyReads(async:Async):Void {
		var got:String = "";
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (data, offset, length) -> {
				got += __text(data, offset, length);
				return true;
			};
			body.onEnd = () -> handler.respond(200, "text/plain", "ok");
			return true;
		});

		var wire:String = "5;ext=1\r\nhello\r\nA\r\n world and\r\n0\r\nX-Trailer: dropped\r\n\r\n";
		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n");
		client.onConnected = function():Void {
			for (i in 0...wire.length) {
				client.after(0.002 * i, () -> client.send(wire.charAt(i)));
			}
		};
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals("hello world and", got);
			Assert.equals(200, client.status());
			async.done();
		});
	}

	/** A chunk is not held until it has all come: its data goes on as it arrives. **/
	public function testAChunkGoesOnBeforeItHasAllArrived(async:Async):Void {
		var got:String = "";
		var server:HTTPServer = __serve(handler -> {
			handler.streamRequestBody().onData = (data, offset, length) -> {
				got += __text(data, offset, length);
				return true;
			};
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1000\r\nhello");
		client.run(() -> got == "hello", function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals("hello", got, "part of a chunk was held back");
			async.done();
		});
	}

	/** The bytes are as they were sent: a coding is not undone, and one this server could not undo is not refused. **/
	public function testAContentCodingIsLeftAsSent(async:Async):Void {
		var got:String = "";
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (data, offset, length) -> {
				got += __text(data, offset, length);
				return true;
			};
			body.onEnd = () -> handler.respond(200, "text/plain", handler.getHeader("content-encoding"));
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Encoding: zstd\r\nContent-Length: 4\r\n\r\nabcd");
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(200, client.status(), client.raw);
			Assert.equals("abcd", got);
			Assert.isTrue(client.raw.indexOf("zstd") >= 0, client.raw);
			async.done();
		});
	}

	/** Only the request that chose it: others are read whole, and a coding undone, on the same server. **/
	public function testTheChoiceIsPerRequest(async:Async):Void {
		var streamed:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			if (handler.requestPath == "/up") {
				var body:HTTPBodyReader = handler.streamRequestBody();
				body.onData = (_, _, length) -> {
					streamed += length;
					return true;
				};
				body.onEnd = () -> handler.respond(200, "text/plain", "streamed");
			}
			return true;
		}, handler -> {
			if (handler.requestPath != "/up") {
				handler.respond(200, "text/plain", "held " + handler.requestBody.length);
			}
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc" + "POST /form HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> HTTPTestSupport.countResponses(client.raw) >= 2, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(3, streamed);
			Assert.equals(2, HTTPTestSupport.countResponses(client.raw), "the connection did not carry on: " + client.raw);
			Assert.isTrue(client.raw.indexOf("held 2") >= 0, client.raw);
			async.done();
		});
	}

	/**
		A hook and a reader are a whole application: with no middleware at all,
		the request is theirs to answer, and is not turned away at its head by
		the server finding nothing to serve.
	**/
	public function testARequestWithAReaderIsTheApplicationsToAnswer(async:Async):Void {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.onRequestHead = handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> true;
			body.onEnd = () -> handler.respond(201, "text/plain", "stored");
			return true;
		};
		var server:HTTPServer = new HTTPServer(config);

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nhi");
		client.after(0.2, () -> client.send("ya"));
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(201, client.status(), client.raw);
			async.done();
		});
	}

	/** Passing the end of the chain changes nothing for a request with a reader, whenever it gets there. **/
	public function testPassingTheEndOfTheChainLeavesItToTheReader(async:Async):Void {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.onRequestHead = handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> true;
			body.onEnd = () -> handler.respond(201, "text/plain", "stored");
			return true;
		};
		config.middleware.push(function(_:HTTPRequestHandler, next:?Dynamic->Void):Void {
			next();
		});
		var server:HTTPServer = new HTTPServer(config);

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(201, client.status(), client.raw);
			async.done();
		});
	}

	/**
		With no callback set, nobody took the body: the server answers as it
		would any request, the body is given up, and the connection closes
		over what is left of it. A decision to come is `onEnd` set now and
		`onData` later, which the case after this shows.
	**/
	public function testARequestNobodyTookIsAnsweredAsAny(async:Async):Void {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.onRequestHead = handler -> {
			handler.streamRequestBody();
			return true;
		};
		var server:HTTPServer = new HTTPServer(config);

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhi");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(404, client.status(), client.raw);
			async.done();
		}, 8.0);
	}

	/** Hook only, deciding later: `onEnd` now holds the request, and the body waits for `onData`. **/
	public function testADecisionCanComeLaterWithNoMiddleware(async:Async):Void {
		var got:String = "";
		var reader:Null<HTTPBodyReader> = null;
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.onRequestHead = handler -> {
			reader = handler.streamRequestBody();
			reader.onEnd = () -> handler.respond(200, "text/plain", "got " + got);
			return true;
		};
		var server:HTTPServer = new HTTPServer(config);

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.after(0.2, function():Void {
			reader.onData = (data, offset, length) -> {
				got += __text(data, offset, length);
				return true;
			};
		});
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(200, client.status(), client.raw);
			Assert.isTrue(client.raw.indexOf("got hi") >= 0, client.raw);
			async.done();
		});
	}

	/** Refused past the hook, nothing was read: `onAbort` hears, and `onEnd`, which says the body arrived, does not. **/
	public function testARequestRefusedAfterTheHookAbortsItsReader(async:Async):Void {
		var ended:Int = 0;
		var aborted:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onEnd = () -> ended++;
			body.onAbort = () -> aborted++;
			if (handler.requestPath == "/refused") {
				handler.respond(403, "text/plain", "no");
				return false;
			}
			return true;
		}, null, config -> {
			config.maxRequestBodySize = 8;
			config.onExpectContinue = _ -> false;
		});

		var cases:Array<{request:String, status:Int}> = [
			{request: "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n", status: 413},
			{request: "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5000000000\r\n\r\n", status: 413},
			{request: "POST /up HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n", status: 417},
			{request: "POST /refused HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n", status: 403}
		];
		var at:Int = 0;

		function next():Void {
			if (at >= cases.length) {
				try server.close() catch (_:Dynamic) {}
				Assert.equals(0, ended, "a body that was never read ended");
				Assert.equals(cases.length, aborted, "a refusal was not heard");
				async.done();
				return;
			}
			var client:Client = new Client(server, cases[at].request);
			client.run(() -> client.closed, function():Void {
				Assert.equals(cases[at].status, client.status(), client.raw);
				at++;
				next();
			}, 8.0);
		}

		next();
	}

	/** What `onEnd` throws is answered as a route that failed, rather than leaving the request unanswered. **/
	public function testAnOnEndThatThrowsIs500(async:Async):Void {
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> true;
			body.onEnd = () -> throw "the end broke";
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(500, client.status(), client.raw);
			async.done();
		}, 8.0);
	}

	/** What `onAbort` throws is logged, not sent up into the socket's own close. **/
	public function testAnOnAbortThatThrowsHarmsNothing(async:Async):Void {
		var heard:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			if (handler.method == "GET") {
				handler.respond(200, "text/plain", "still here");
				return false;
			}
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, length) -> {
				heard += length;
				return true;
			};
			body.onAbort = () -> throw "the abort broke";
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhi");
		client.run(() -> heard == 2, function():Void {
			client.hangUp();
			HTTPTestSupport.pumpMoreAsync(20, function():Void {
				var next:Client = new Client(server, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
				next.run(() -> next.answered, function():Void {
					try server.close() catch (_:Dynamic) {}
					Assert.isTrue(next.answered, "the server did not go on");
					async.done();
				}, 8.0);
			});
		});
	}

	/** A request with no body ends once the chain has run, and a kept connection goes on. **/
	public function testABodilessRequestEnds(async:Async):Void {
		var ended:Int = 0;
		var data:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> {
				data++;
				return true;
			};
			body.onEnd = () -> {
				ended++;
				handler.respond(200, "text/plain", "ok");
			};
			return true;
		});

		var client:Client = new Client(server, "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n");
		client.run(() -> HTTPTestSupport.countResponses(client.raw) >= 2, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(2, ended);
			Assert.equals(0, data);
			Assert.equals(2, HTTPTestSupport.countResponses(client.raw), client.raw);
			async.done();
		});
	}

	/**
		`onData` answering `false` stops the connection reading. What the
		server holds stays near one pass's read however much the client has to
		send, the client is held back by TCP, and after `resume` every byte
		arrives, in order.
	**/
	public function testAPausedBodyHoldsTheClientBackAndLosesNothing(async:Async):Void {
		var total:Int = 48 * 1024 * 1024;
		var received:Int = 0;
		var sum:Int = 0;
		var reader:Null<HTTPBodyReader> = null;
		var holder:Null<HTTPRequestHandler> = null;
		var answered:Bool = false;
		var pausedOnce:Bool = false;
		var server:HTTPServer = __serve(handler -> {
			holder = handler;
			reader = handler.streamRequestBody();
			reader.onData = (data, offset, length) -> {
				for (i in 0...length) {
					sum = (sum + data[offset + i]) & 0xFFFFFF;
				}
				received += length;
				if (!pausedOnce && received > 256 * 1024) {
					pausedOnce = true;
					return false;
				}
				return true;
			};
			reader.onEnd = () -> {
				answered = true;
				handler.respond(200, "text/plain", "got " + received);
			};
			return true;
		}, null, config -> config.maxRequestBodySize = total);

		var piece:ByteArray = new ByteArray();
		var expected:Int = 0;
		for (i in 0...64 * 1024) {
			piece.writeByte(i & 0xFF);
		}
		for (i in 0...64 * 1024) {
			expected = (expected + (i & 0xFF)) & 0xFFFFFF;
		}
		var pieces:Int = Std.int(total / piece.length);
		for (_ in 0...pieces - 1) {
			var whole:Int = 0;
			for (i in 0...64 * 1024) {
				whole = (whole + (i & 0xFF)) & 0xFFFFFF;
			}
			expected = (expected + whole) & 0xFFFFFF;
		}

		var client:Client = new Client(server, 'POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: $total\r\n\r\n');
		client.feed(piece, pieces);

		var heldAtPause:Int = -1;
		var receivedAtPause:Int = -1;
		client.run(() -> pausedOnce && client.stalledFor() > 0.5, function():Void {
			receivedAtPause = received;
			heldAtPause = holder.__incomingBuffer.length + holder.__origin.bytesAvailable;
			Assert.isTrue(client.fed < total, "the client sent everything with the reader stopped");
			Assert.isTrue(heldAtPause <= 2 * 1024 * 1024, "a paused body held " + heldAtPause + " bytes");
			Assert.isTrue(reader.paused);

			client.after(0.3, function():Void {
				Assert.equals(receivedAtPause, received, "a paused reader was given more");
				reader.resume();
				Assert.isFalse(reader.paused);
			});
			client.run(() -> client.answered, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(answered, "the body never ended");
				Assert.equals(total, received);
				Assert.equals(expected, sum, "the bytes did not arrive as they were sent");
				Assert.equals(200, client.status());
				async.done();
			}, 25.0);
		}, 15.0);
	}

	/** `pause` and `resume` from outside the callback, and a resume from inside one, do what they say. **/
	public function testPauseAndResumeFromOutsideACallback(async:Async):Void {
		var got:String = "";
		var reader:Null<HTTPBodyReader> = null;
		var server:HTTPServer = __serve(handler -> {
			reader = handler.streamRequestBody();
			reader.onData = (data, offset, length) -> {
				got += __text(data, offset, length);
				return true;
			};
			reader.onEnd = () -> handler.respond(200, "text/plain", "ok");
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhello");
		client.run(() -> got == "hello", function():Void {
			reader.pause();
			Assert.isTrue(reader.paused);
			client.send("world");
			client.after(0.2, function():Void {
				Assert.equals("hello", got, "a paused body was delivered");
				reader.resume();
			});
			client.run(() -> client.answered, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals("helloworld", got);
				async.done();
			});
		});
	}

	/** A paused last piece holds its end back until `resume`, so `onEnd` says the reader has had it all and is ready. **/
	public function testAPausedLastPieceEndsOnResume(async:Async):Void {
		var ended:Int = 0;
		var reader:Null<HTTPBodyReader> = null;
		var server:HTTPServer = __serve(handler -> {
			reader = handler.streamRequestBody();
			reader.onData = (_, _, _) -> false;
			reader.onEnd = () -> {
				ended++;
				handler.respond(200, "text/plain", "ok");
			};
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> reader != null && reader.paused, function():Void {
			client.after(0.1, function():Void {
				Assert.equals(0, ended, "it ended while paused");
				reader.resume();
			});
			client.run(() -> client.answered, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals(1, ended);
				async.done();
			});
		});
	}

	/**
		A reader set late, after a lookup say, loses nothing: the body waits,
		and the connection stops reading meanwhile. `onData` is never called
		before setting it returns.
	**/
	public function testABodyWaitsForAReaderSetLater(async:Async):Void {
		var got:String = "";
		var reader:Null<HTTPBodyReader> = null;
		var holder:Null<HTTPRequestHandler> = null;
		var server:HTTPServer = __serve(handler -> {
			holder = handler;
			reader = handler.streamRequestBody();
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
		client.run(() -> reader != null, function():Void {
			client.after(0.2, function():Void {
				Assert.isTrue(holder.__bodyHolding, "the connection went on reading with no reader");
				var returned:Bool = false;
				reader.onData = (data, offset, length) -> {
					Assert.isTrue(returned, "onData was called before setting it returned");
					got += __text(data, offset, length);
					return true;
				};
				reader.onEnd = () -> holder.respond(200, "text/plain", "ok");
				returned = true;
			});
			client.run(() -> client.answered, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals("hello", got);
				async.done();
			});
		});
	}

	/** `onEnd` set once the body has ended is told in a later turn, rather than not at all. **/
	public function testOnEndSetLateIsStillCalled(async:Async):Void {
		var reader:Null<HTTPBodyReader> = null;
		var holder:Null<HTTPRequestHandler> = null;
		var read:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			holder = handler;
			reader = handler.streamRequestBody();
			reader.onData = (_, _, length) -> {
				read += length;
				return true;
			};
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> read == 2, function():Void {
			client.after(0.1, function():Void {
				var returned:Bool = false;
				reader.onEnd = () -> {
					Assert.isTrue(returned, "onEnd was called before setting it returned");
					holder.respond(200, "text/plain", "ok");
				};
				returned = true;
			});
			client.run(() -> client.answered, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals(200, client.status());
				async.done();
			});
		});
	}

	/** Echoed as it arrives: a response goes out beside the body it answers, and the connection closes after it. **/
	public function testAResponseGoesOutBesideTheBody(async:Async):Void {
		var server:HTTPServer = __serve(handler -> {
			var out:Null<HTTPResponseStream> = null;
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (data, offset, length) -> {
				if (out == null) {
					out = handler.beginResponse(200, "text/plain");
				}
				return out.write(data, offset, length);
			};
			body.onEnd = () -> out.end();
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhello");
		client.run(() -> client.raw.indexOf("hello") >= 0, function():Void {
			Assert.equals(-1, client.raw.indexOf("world"));
			client.send("world");
			client.run(() -> client.closed, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.isTrue(client.raw.indexOf("world") >= 0, client.raw);
				Assert.isTrue(client.raw.indexOf("Connection: close") >= 0, "a response begun before the body had all come kept the connection");
				async.done();
			});
		});
	}

	/**
		An answer before the body has all come reaches a client still sending
		it, the body is given up, and what is left is never read as a request.
		`onAbort` hears, as `onEnd` does not.
	**/
	public function testAnEarlyAnswerGivesTheBodyUp(async:Async):Void {
		var aborted:Int = 0;
		var ended:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> {
				handler.respond(200, "text/plain", "enough");
				return true;
			};
			body.onEnd = () -> ended++;
			body.onAbort = () -> aborted++;
			return true;
		});

		var smuggled:String = "GET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n";
		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhi");
		client.onConnected = () -> client.after(0.05, () -> client.send(smuggled));
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(200, client.status(), client.raw);
			Assert.equals(1, HTTPTestSupport.countResponses(client.raw), "what followed was read as a request: " + client.raw);
			Assert.isTrue(client.raw.indexOf("Connection: close") >= 0, client.raw);
			Assert.equals(1, aborted, "onAbort was not called once");
			Assert.equals(0, ended);
			async.done();
		}, 8.0);
	}

	/**
		An answer given while a client is still uploading is read by it: the
		connection lingers over what keeps arriving, rather than closing
		over it, which resets it and throws the answer away with whatever the
		client has not read.

		Given between reads, as a proxy's upstream answers: the reader has had
		all that has come, so the buffer is empty and says nothing of what is
		still on its way.
	**/
	public function testAnEarlyAnswerReachesAClientStillUploading(async:Async):Void {
		var total:Int = 64 * 1024 * 1024;
		var holder:Null<HTTPRequestHandler> = null;
		var read:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			holder = handler;
			handler.streamRequestBody().onData = (_, _, length) -> {
				read += length;
				return true;
			};
			return true;
		}, null, config -> config.maxRequestBodySize = total);

		var piece:ByteArray = new ByteArray();
		for (_ in 0...64 * 1024) {
			piece.writeByte("x".code);
		}
		var client:Client = new Client(server, 'POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: $total\r\n\r\n');
		client.feed(piece, Std.int(total / piece.length));
		var answered:Bool = false;
		client.run(() -> {
			if (!answered && read > 0 && holder.__incomingBuffer.length == 0) {
				answered = true;
				holder.respond(403, "text/plain", "not this upload");
			}
			return client.closed;
		}, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.isTrue(StringTools.startsWith(client.raw, "HTTP/1.1 403 "), "the client did not read its answer: " + client.raw);
			Assert.isTrue(client.raw.indexOf("not this upload") >= 0, client.raw);
			async.done();
		}, 10.0);
	}

	/**
		A request pipelined behind one answered from `onData` is parsed once
		that call has returned, as a pipelined request is, and its body is read
		though nothing more arrives. The first request's `onEnd` is told in
		between, so it cannot land on the second: whatever it does then is
		about a request already answered.
	**/
	public function testARequestBehindAnAnswerFromOnDataIsRead(async:Async):Void {
		var order:Array<String> = [];
		var server:HTTPServer = __serve(handler -> {
			var path:String = handler.requestPath;
			order.push("head " + path);
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> {
				order.push("data " + path);
				handler.respond(200, "text/plain", "ok " + path);
				return true;
			};
			body.onEnd = () -> {
				order.push("end " + path);
				handler.respond(500, "text/plain", "late");
			};
			return true;
		});

		// The first body in a read of its own, so the pump runs from the read
		// handler and not from inside a parse.
		var client:Client = new Client(server, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n");
		client.onConnected = () -> client.after(0.1, () -> client.send("hiPOST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nya"));
		client.run(() -> HTTPTestSupport.countResponses(client.raw) >= 2, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(2, HTTPTestSupport.countResponses(client.raw), "the request behind an answer was not read: " + client.raw);
			Assert.equals("head /a,data /a,end /a,head /b,data /b,end /b", order.join(","));
			Assert.isTrue(client.raw.indexOf("ok /b") >= 0, "the second request got the first's answer: " + client.raw);
			Assert.equals(-1, client.raw.indexOf("late"), "an answer went out from an onEnd with its request answered: " + client.raw);
			async.done();
		}, 3.0);
	}

	/** Many behind one another are parsed one after another, rather than each inside the last's call. **/
	public function testAFloodBehindAnAnswerFromOnDataIsFlat(async:Async):Void {
		var count:Int = 2000;
		var answered:Int = 0;
		var depth:Int = 0;
		var deepest:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> {
				depth++;
				if (depth > deepest) {
					deepest = depth;
				}
				handler.respond(200, "text/plain", "ok");
				answered++;
				depth--;
				return true;
			};
			return true;
		}, null, config -> {
			config.keepAliveMaxRequests = 0;
			config.rateLimiter = null;
		});

		var flood:StringBuf = new StringBuf();
		flood.add("hi");
		for (_ in 0...count - 1) {
			flood.add("POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		}
		var client:Client = new Client(server, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n");
		client.onConnected = () -> client.after(0.1, () -> client.send(flood.toString()));
		client.dropsWhatArrives = true;
		client.run(() -> answered >= count, function():Void {
			client.hangUp();
			try server.close() catch (_:Dynamic) {}
			Assert.equals(count, answered, "the requests behind one another were not all read");
			Assert.equals(1, deepest, "a request was parsed inside the last one's onData");
			async.done();
		}, 10.0);
	}

	/** Answered from `onAbort`, as its documentation allows, the answer goes out as any does, and the client has not left. **/
	public function testAnAnswerFromOnAbortGoesOut(async:Async):Void {
		var closes:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			handler.addEventListener(Event.CLOSE, _ -> closes++);
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> true;
			body.onAbort = () -> handler.respond(503, "text/plain", "gave up");
			return true;
		}, null, config -> {
			config.requestTimeout = 0;
			config.requestIdleTimeout = 0.3;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhi");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(503, client.status(), client.raw);
			Assert.isTrue(client.raw.indexOf("gave up") >= 0, client.raw);
			Assert.equals(0, closes, "a response given in full was treated as cut short");
			async.done();
		}, 8.0);
	}

	/** The last piece failing is the body failing: `onEnd`, which an application may commit on, does not hear. **/
	public function testAReaderThatThrowsOnTheLastPieceAborts(async:Async):Void {
		var ended:Int = 0;
		var aborted:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> throw "the reader broke";
			body.onEnd = () -> ended++;
			body.onAbort = () -> aborted++;
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(500, client.status(), client.raw);
			Assert.equals(0, ended, "a body that failed ended");
			Assert.equals(1, aborted);
			async.done();
		}, 8.0);
	}

	/** An answer given on the last piece, with nothing left to come, keeps the connection. **/
	public function testAnAnswerOnTheLastPieceKeepsTheConnection(async:Async):Void {
		var ended:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> {
				handler.respond(200, "text/plain", "ok");
				return true;
			};
			body.onEnd = () -> ended++;
			return true;
		});

		var client:Client = new Client(server, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhiPOST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> HTTPTestSupport.countResponses(client.raw) >= 2 && ended >= 2, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(2, HTTPTestSupport.countResponses(client.raw), client.raw);
			Assert.equals(2, ended);
			async.done();
		});
	}

	public function testAClientLeavingAbortsTheBody(async:Async):Void {
		var aborted:Int = 0;
		var heard:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, length) -> {
				heard += length;
				return true;
			};
			body.onAbort = () -> aborted++;
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhi");
		client.run(() -> heard == 2, function():Void {
			client.hangUp();
			HTTPTestSupport.pumpWallUntilAsync(() -> aborted > 0, 5.0, function(_):Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals(1, aborted, "a client leaving was not heard");
				async.done();
			});
		});
	}

	/** Past `maxRequestBodySize` on a chunk's size line: refused there, `413`, and the reader told. **/
	public function testAChunkPastTheLimitIs413(async:Async):Void {
		var aborted:Int = 0;
		var got:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, length) -> {
				got += length;
				return true;
			};
			body.onAbort = () -> aborted++;
			return true;
		}, null, config -> config.maxRequestBodySize = 8);

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n9\r\n");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(413, client.status(), client.raw);
			Assert.equals(1, aborted);
			Assert.equals(5, got, "more than the limit went to the reader");
			async.done();
		}, 8.0);
	}

	/** A declared length past the limit never reaches a reader: as for any request, `413` at the head. **/
	public function testALengthPastTheLimitIs413BeforeAnythingIsRead(async:Async):Void {
		var routed:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			handler.streamRequestBody().onData = (_, _, _) -> true;
			return true;
		}, _ -> routed++, config -> config.maxRequestBodySize = 8);

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n\r\n");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(413, client.status(), client.raw);
			Assert.equals(0, routed, "the request reached the chain");
			async.done();
		}, 8.0);
	}

	public function testMalformedChunkingIs400(async:Async):Void {
		var bodies:Array<String> = ["zz\r\n", "5\r\nhelloXX", "F000000000\r\n"];
		var at:Int = 0;

		function next():Void {
			if (at >= bodies.length) {
				async.done();
				return;
			}
			var aborted:Int = 0;
			var server:HTTPServer = __serve(handler -> {
				var body:HTTPBodyReader = handler.streamRequestBody();
				body.onData = (_, _, _) -> true;
				body.onAbort = () -> aborted++;
				return true;
			});
			var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" + bodies[at]);
			client.run(() -> client.closed, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals(400, client.status(), "chunk " + at + ": " + client.raw);
				Assert.equals(1, aborted, "chunk " + at + " did not abort");
				at++;
				next();
			}, 8.0);
		}

		next();
	}

	/** A line that never ends is held to a header block's limit, not the body's. **/
	public function testAChunkLineThatNeverEndsIsRefused(async:Async):Void {
		var server:HTTPServer = __serve(handler -> {
			handler.streamRequestBody().onData = (_, _, _) -> true;
			return true;
		}, null, config -> config.maxRequestBodySize = 64 * 1024 * 1024);

		var long:StringBuf = new StringBuf();
		for (_ in 0...70 * 1024) {
			long.add("1");
		}
		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" + long.toString());
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(413, client.status(), client.raw);
			async.done();
		}, 8.0);
	}

	/** A trailer section is held to a header block's limit, however short its lines. **/
	public function testATrailerSectionIsBounded(async:Async):Void {
		var server:HTTPServer = __serve(handler -> {
			handler.streamRequestBody().onData = (_, _, _) -> true;
			return true;
		});

		var trailers:StringBuf = new StringBuf();
		for (_ in 0...20 * 1024) {
			trailers.add("a:b\r\n");
		}
		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" + trailers.toString());
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(431, client.status(), client.raw);
			async.done();
		}, 8.0);
	}

	/** A body that stops arriving is `408`, and its reader told. **/
	public function testASilentBodyIs408(async:Async):Void {
		var aborted:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> true;
			body.onAbort = () -> aborted++;
			return true;
		}, null, config -> {
			config.requestTimeout = 0;
			config.requestIdleTimeout = 0.3;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhi");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(408, client.status(), client.raw);
			Assert.equals(1, aborted);
			async.done();
		}, 8.0);
	}

	/** The wait for a paused reader is the application's: neither deadline runs, and each goes on from where it was. **/
	public function testAPausedBodyIsNotTimedOut(async:Async):Void {
		var reader:Null<HTTPBodyReader> = null;
		var aborted:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			reader = handler.streamRequestBody();
			reader.onData = (_, _, _) -> false;
			reader.onEnd = () -> handler.respond(200, "text/plain", "ok");
			reader.onAbort = () -> aborted++;
			return true;
		}, null, config -> {
			config.requestTimeout = 1.0;
			config.requestIdleTimeout = 0.4;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nhi");
		client.run(() -> reader != null && reader.paused, function():Void {
			client.after(1.5, function():Void {
				Assert.equals(0, aborted, "a body was timed out while its reader had it stopped");
				client.send("ya");
				reader.onData = (_, _, _) -> true;
				reader.resume();
			});
			client.run(() -> client.answered, function():Void {
				try server.close() catch (_:Dynamic) {}
				Assert.equals(200, client.status(), client.raw);
				async.done();
			}, 8.0);
		}, 8.0);
	}

	/** A deadline passing with a response going out ends it, since no `408` can follow a head. **/
	public function testADeadlinePastAResponseBegunClosesTheConnection(async:Async):Void {
		var aborted:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> true;
			body.onAbort = () -> aborted++;
			return true;
		}, handler -> handler.beginResponse(200, "text/plain").writeText("begun"), config -> {
			config.requestTimeout = 0;
			config.requestIdleTimeout = 0.3;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nhi");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(200, client.status(), client.raw);
			Assert.equals(-1, client.raw.indexOf("408"), "a status went out inside a body: " + client.raw);
			Assert.equals(1, aborted);
			async.done();
		}, 8.0);
	}

	/** What `onData` throws fails the request, rather than reaching the runtime. **/
	public function testAReaderThatThrowsIs500(async:Async):Void {
		var aborted:Int = 0;
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (_, _, _) -> throw "the reader broke";
			body.onAbort = () -> aborted++;
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nhi");
		client.run(() -> client.closed, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(500, client.status(), client.raw);
			Assert.equals(1, aborted);
			async.done();
		}, 8.0);
	}

	/** A reader kept past its request reaches nothing: the connection's next request is not its to stop. **/
	public function testAFinishedReaderReachesNothing(async:Async):Void {
		var readers:Array<HTTPBodyReader> = [];
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			readers.push(body);
			body.onData = (_, _, _) -> {
				if (readers.length == 2) {
					readers[0].pause();
				}
				return true;
			};
			body.onEnd = () -> handler.respond(200, "text/plain", "ok");
			return true;
		});

		var client:Client = new Client(server, "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhiPOST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi");
		client.run(() -> HTTPTestSupport.countResponses(client.raw) >= 2, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals(2, HTTPTestSupport.countResponses(client.raw), "a finished reader stopped the next request: " + client.raw);
			Assert.isFalse(readers[0].paused);
			async.done();
		});
	}

	#if target.threaded
	/** `pause` and `resume` from a worker's thread, as `respond` may be called there. **/
	public function testResumeFromAnotherThread(async:Async):Void {
		var got:String = "";
		var server:HTTPServer = __serve(handler -> {
			var body:HTTPBodyReader = handler.streamRequestBody();
			body.onData = (data, offset, length) -> {
				got += __text(data, offset, length);
				sys.thread.Thread.create(() -> {
					crossbyte.sys.System.sleep(0.05);
					body.resume();
				});
				return false;
			};
			body.onEnd = () -> handler.respond(200, "text/plain", "ok");
			return true;
		});

		var client:Client = new Client(server, "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhello");
		client.onConnected = () -> client.after(0.1, () -> client.send("world"));
		client.run(() -> client.answered, function():Void {
			try server.close() catch (_:Dynamic) {}
			Assert.equals("helloworld", got);
			async.done();
		}, 8.0);
	}
	#end

	private function __serve(hook:HTTPRequestHandler->Bool, ?route:HTTPRequestHandler->Void, ?configure:HTTPServerConfig->Void):HTTPServer {
		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		config.onRequestHead = hook;
		if (configure != null) {
			configure(config);
		}
		if (route != null) {
			config.middleware.push(function(handler:HTTPRequestHandler, _:?Dynamic->Void):Void {
				route(handler);
			});
		} else {
			// The application answers from its reader: nothing falls through.
			config.middleware.push(function(_:HTTPRequestHandler, _:?Dynamic->Void):Void {});
		}
		return new HTTPServer(config);
	}

	private static function __text(data:ByteArray, offset:Int, length:Int):String {
		var text:StringBuf = new StringBuf();
		for (i in 0...length) {
			text.addChar(data[offset + i]);
		}
		return text.toString();
	}
}

/** One connection's client: a head, what follows it when told, and everything that came back. */
private class Client {
	public var raw(default, null):String = "";
	public var closed(default, null):Bool = false;
	public var fed(default, null):Float = 0;
	public var onConnected:Null<Void->Void> = null;
	public var answered(get, never):Bool;
	/** Reads and forgets, for a case with too much coming back to keep a byte at a time. */
	public var dropsWhatArrives:Bool = false;

	private final __server:HTTPServer;
	private final __socket:Socket = new Socket();
	private final __head:String;
	private final __later:Array<{at:Float, call:Void->Void}> = [];
	private var __started:Bool = false;
	private var __piece:Null<ByteArray> = null;
	private var __piecesLeft:Int = 0;
	private var __lastFedAt:Float = 0;

	public function new(server:HTTPServer, head:String) {
		__server = server;
		__head = head;
		__socket.addEventListener(Event.CONNECT, function(_):Void {
			__socket.writeUtfBytes(__head);
			__socket.flush();
			__lastFedAt = haxe.Timer.stamp();
			__feed();
			if (onConnected != null) {
				onConnected();
			}
		});
		__socket.addEventListener(OutputProgressEvent.OUTPUT_PROGRESS, _ -> __feed());
		__socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (dropsWhatArrives) {
				__socket.readBytes(new ByteArray());
				return;
			}
			while (__socket.bytesAvailable > 0) {
				raw += String.fromCharCode(__socket.readUnsignedByte());
			}
		});
		__socket.addEventListener(Event.CLOSE, _ -> closed = true);
	}

	private function get_answered():Bool {
		return HTTPTestSupport.countResponses(raw) > 0;
	}

	public function status():Int {
		return HTTPTestSupport.parseResponse(raw).status;
	}

	/** Writes `text` now. */
	public function send(text:String):Void {
		if (__socket.connected) {
			__socket.writeUtfBytes(text);
			__socket.flush();
		}
	}

	/** Calls `call` in `seconds`, while `run` pumps. */
	public function after(seconds:Float, call:Void->Void):Void {
		__later.push({at: haxe.Timer.stamp() + seconds, call: call});
	}

	/** Sends `piece`, `count` times, as fast as the connection takes it. */
	public function feed(piece:ByteArray, count:Int):Void {
		__piece = piece;
		__piecesLeft = count;
	}

	/** Seconds since the connection last took more of what `feed` was given. */
	public function stalledFor():Float {
		return haxe.Timer.stamp() - __lastFedAt;
	}

	public function hangUp():Void {
		__socket.close();
	}

	private function __feed():Void {
		var moved:Bool = false;
		while (__piecesLeft > 0 && __socket.connected && __socket.bytesPending < 256 * 1024) {
			__socket.writeBytes(__piece, 0, __piece.length);
			__piecesLeft--;
			fed += __piece.length;
			moved = true;
		}
		if (moved) {
			__lastFedAt = haxe.Timer.stamp();
			__socket.flush();
		}
	}

	/** Connects if it has not, and pumps until `done` says so or `timeout` passes, then calls `then`, whichever it was. */
	public function run(done:Void->Bool, then:Void->Void, timeout:Float = 5.0):Void {
		function step():Bool {
			var now:Float = haxe.Timer.stamp();
			var i:Int = 0;
			while (i < __later.length) {
				if (__later[i].at <= now) {
					__later.splice(i, 1)[0].call();
				} else {
					i++;
				}
			}
			__feed();
			return done();
		}

		function pump():Void {
			HTTPTestSupport.pumpWallUntilAsync(step, timeout, function(_):Void {
				then();
				if (closed) {
					return;
				}
			});
		}

		if (__started) {
			pump();
			return;
		}
		__started = true;
		HTTPTestSupport.connectThen(__socket, __server, pump);
	}
}
