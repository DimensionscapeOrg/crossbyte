package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.utils.Hash;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

/**
	Every `RPCSession` here is bound to a local, including the ones constructed
	purely to wire themselves onto a connection.

	Not style. Discarding the result of `new` leaves Haxe 4.3.7's `--jvm`
	backend with an uninitialised reference live across a branch, and the
	verifier rejects the whole class: "Inconsistent stackmap frames". That is
	not a failing test, it is a `VerifyError` at class-load that takes the
	process with it, which is why this suite was skipped on jvm entirely.

	`crossbyte.rpc` itself was never the problem and works there unchanged. It
	simply had nothing running to say so.
**/
class RPCTest extends utest.Test {
	public function testOneWayCallDecodesScalarsBytesAndOptionals():Void {
		var link = LinkedConnection.pair();
		var commands = new TestCommands();
		var handler = new TestHandler();

		var clientSession = new RPCSession<TestCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		commands.sendData(7, true, 1.25, "alpha", Bytes.ofString("abc"), "tagged");

		Assert.equals(1, handler.calls);
		Assert.equals(7, handler.lastId);
		Assert.isTrue(handler.lastEnabled);
		Assert.equals(1.25, handler.lastRatio);
		Assert.equals("alpha", handler.lastName);
		Assert.equals("abc", handler.lastBytes.toString());
		Assert.equals("tagged", handler.lastTag);

		commands.sendData(8, false, 2.5, "beta", Bytes.ofString("z"), null);

		Assert.equals(2, handler.calls);
		Assert.equals(8, handler.lastId);
		Assert.isFalse(handler.lastEnabled);
		Assert.equals(2.5, handler.lastRatio);
		Assert.equals("beta", handler.lastName);
		Assert.equals("z", handler.lastBytes.toString());
		Assert.isNull(handler.lastTag);
	}

	public function testResponseCompletesTypedResponder():Void {
		var link = LinkedConnection.pair();
		var commands = new TestCommands();
		var serverHandler = new TestHandler();
		var result:String = null;
		var error:String = null;

		var clientSession = new RPCSession<TestCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, serverHandler);

		var response = commands.getName(42).then(value -> result = value, message -> error = message);

		Assert.isTrue(response.completed);
		Assert.isTrue(response.succeeded);
		Assert.equals("player-42", response.result);
		Assert.equals("player-42", result);
		Assert.isNull(error);
	}

	public function testConcurrentResponsesCompleteWhenMultipleArePending():Void {
		var link = LinkedConnection.pair();
		var commands = new TestCommands();
		var serverHandler = new TestHandler();
		link.client.bufferInbound = true;

		var clientSession = new RPCSession<TestCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, serverHandler);

		var first = commands.getName(1);
		var second = commands.getName(2);

		Assert.isFalse(first.completed);
		Assert.isFalse(second.completed);

		link.client.flushBufferedReads();

		Assert.isTrue(first.completed);
		Assert.isTrue(second.completed);
		Assert.equals("player-1", first.result);
		Assert.equals("player-2", second.result);
	}

	public function testCommandsOnlySessionHandlesResponsesWithoutClientHandler():Void {
		var link = LinkedConnection.pair();
		var commands = new TestCommands();
		var serverHandler = new TestHandler();

		var clientSession = new RPCSession<TestCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, serverHandler);

		var response = commands.getName(9);

		Assert.isTrue(response.completed);
		Assert.isTrue(response.succeeded);
		Assert.equals("player-9", response.result);
	}

	public function testResponseDispatchesResultEventWhenObserved():Void {
		var response = new RPCResponse<String>(7, 11);
		var resultEvents = 0;

		response.addEventListener(RPCResponse.RESULT, _ -> resultEvents++);
		@:privateAccess response.__resolve("player-7");

		Assert.isTrue(response.completed);
		Assert.equals("player-7", response.result);
		Assert.equals(1, resultEvents);
	}

	public function testHandlerCanBeCleared():Void {
		var link = LinkedConnection.pair();
		var handler = new TestHandler();
		var session = new RPCSession(link.server, null, handler);

		session.handler = null;

		Assert.isNull(session.handler);
	}

	public function testUnknownOpDoesNotCollideIntoHandler():Void {
		var link = LinkedConnection.pair();
		var handler = new TestHandler();
		var serverSession = new RPCSession(link.server, null, handler);
		var closed:Bool = false;
		var errored:Bool = false;
		link.server.onClose = _ -> closed = true;
		link.server.onError = _ -> errored = true;

		var payload = new ByteArrayOutput(5);
		payload.writeByte(0);
		payload.writeInt(0x1234567);
		payload.flush();

		var frame = new ByteArrayOutput(payload.length + 4);
		frame.writeInt(payload.length);
		frame.writeBytes(payload);

		link.client.send(frame);
		Assert.equals(0, handler.calls);
		Assert.isTrue(closed || errored);
	}

	public function testContractDrivenCommandsAndHandlerGenerateFromSharedInterface():Void {
		var link = LinkedConnection.pair();
		var commands = new ContractCommands();
		var handler = new ContractHandler();
		var label:String = null;

		var clientSession = new RPCSession<ContractCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		commands.announce(7, "hello");
		commands.getLabel(7).then(value -> label = value);

		Assert.equals(1, handler.announceCalls);
		Assert.equals(7, handler.lastAnnounceId);
		Assert.equals("hello", handler.lastAnnounceMessage);
		Assert.equals("label-7", label);
	}

	public function testContractDrivenCommandsRetainBuiltInPingOutsideSharedContract():Void {
		var link = LinkedConnection.pair();
		var commands = new ContractCommands();
		var handler = new ContractHandler();

		var clientSession = new RPCSession<ContractCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		commands.ping();
		commands.announce(12, "still-fine");

		Assert.equals(1, handler.announceCalls);
		Assert.equals(12, handler.lastAnnounceId);
		Assert.equals("still-fine", handler.lastAnnounceMessage);
	}

	public function testRuntimeOneWayCallDecodesDynamicValues():Void {
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var captured:Array<Dynamic> = null;

		serverSession.register(101, args -> {
			captured = args;
			return null;
		});

		var clientSession = new RPCSession(link.client);
		clientSession.call(101, [7, true, 1.25, "alpha", Bytes.ofString("abc"), null]);

		Require.notNull(captured);
		Assert.equals(6, captured.length);
		Assert.equals(7, captured[0]);
		Assert.isTrue(captured[1]);
		Assert.equals(1.25, captured[2]);
		Assert.equals("alpha", captured[3]);
		Assert.equals("abc", (cast captured[4] : Bytes).toString());
		Assert.isNull(captured[5]);
	}

	public function testRuntimeRequestCompletesTypedResponse():Void {
		var link = LinkedConnection.pair();
		var clientSession = new RPCSession(link.client);
		var serverSession = new RPCSession(link.server);

		serverSession.register(202, args -> "player-" + args[0]);

		var response:RPCResponse<String> = clientSession.request(202, [42]);

		Assert.isTrue(response.completed);
		Assert.isTrue(response.succeeded);
		Assert.equals("player-42", response.result);
	}

	public function testPerfectHashDispatchReachesEveryMethod():Void {
		var link = LinkedConnection.pair();
		var handler = new WideHandler();
		var commands = new WideCommands();
		var serverSession = new RPCSession(link.server, null, handler);
		var clientSession = new RPCSession<WideCommands>(link.client, commands);

		// Through the typed surface, which is the lane the macro generates:
		// `call` would take the runtime lane and never reach the perfect hash.
		commands.m01(1);
		commands.m02(2);
		commands.m03(3);
		commands.m04(4);
		commands.m05(5);
		commands.m06(6);
		commands.m07(7);
		commands.m08(8);
		commands.m09(9);
		commands.m10(10);

		Assert.equals(10, handler.seen.length);
		Assert.equals("m01:1", handler.seen[0]);
		Assert.equals("m10:10", handler.seen[9]);
	}

	public function testRuntimeMessagesDoNotHitCompileTimeHandlerWhenOpcodeCollides():Void {
		var link = LinkedConnection.pair();
		var compileHandler = new TestHandler();
		var serverSession = new RPCSession(link.server, null, compileHandler);
		var runtimeCalls:Int = 0;
		final collidingOp:Int = Hash.fnv1a32(Bytes.ofString("sendData"));

		serverSession.register(collidingOp, args -> {
			runtimeCalls++;
			return null;
		});

		var clientSession = new RPCSession(link.client);
		clientSession.call(collidingOp, [99, false]);

		Assert.equals(1, runtimeCalls);
		Assert.equals(0, compileHandler.calls);
	}

	public function testCompiledAndRuntimeLanesCanShareOneSession():Void {
		var link = LinkedConnection.pair();
		var commands = new TestCommands();
		var handler = new TestHandler();
		var clientSession = new RPCSession<TestCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var runtimeAnnounce:String = null;

		serverSession.register(303, args -> {
			runtimeAnnounce = cast args[0];
			return "seen:" + runtimeAnnounce;
		});

		commands.sendData(7, true, 1.25, "alpha", Bytes.ofString("abc"), "tagged");
		var response:RPCResponse<String> = clientSession.request(303, ["runtime"]);

		Assert.equals(1, handler.calls);
		Assert.equals("runtime", runtimeAnnounce);
		Assert.isTrue(response.completed);
		Assert.equals("seen:runtime", response.result);
	}

	// ----------------------------------------------------- handlers failing

	public function testAHandlerThatThrowsAnswersWithAnErrorAndTheConnectionStays():Void {
		var link = LinkedConnection.pair();
		var commands = new FailingCommands();
		var clientSession = new RPCSession<FailingCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new FailingHandler());
		var reported = reportsOf(serverSession);
		var ended = endingOf(link.server);

		// The session took a handler throwing for the peer sending something
		// unreadable: the connection closed, and the caller was told nothing
		// but that it had.
		var failed = commands.lookup(0);
		Assert.isTrue(failed.completed, "the caller was never answered");
		Assert.isFalse(failed.succeeded);
		Assert.equals(RPCError.INTERNAL_MESSAGE, failed.error, "the caller was told what the handler failed on");
		Assert.isFalse(ended.value, "a handler throwing ended the connection");
		Assert.same(["lookup: database at /var/lib/players refused"], reported);

		Assert.equals("player-5", commands.lookup(5).result, "the connection did not answer again");
	}

	public function testAnRPCErrorIsTheCallersAnswerWordForWord():Void {
		var link = LinkedConnection.pair();
		var commands = new FailingCommands();
		var clientSession = new RPCSession<FailingCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new FailingHandler());
		var reported = reportsOf(serverSession);

		var refused = commands.lookup(-3);
		Assert.isFalse(refused.succeeded);
		Assert.equals("no player -3", refused.error);
		// The caller was told; there is nothing to report.
		Assert.same([], reported);
	}

	public function testAOneWayCallThatThrowsIsReportedAndTheConnectionStays():Void {
		var link = LinkedConnection.pair();
		var commands = new FailingCommands();
		var handler = new FailingHandler();
		var clientSession = new RPCSession<FailingCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var reported = reportsOf(serverSession);
		var ended = endingOf(link.server);

		// Nobody is waiting on a one-way call, so an RPCError is reported too:
		// nothing else would ever hear of it.
		commands.notify(0);
		commands.notify(-1);
		commands.notify(7);

		Assert.isFalse(ended.value, "a one-way call throwing ended the connection");
		Assert.equals(2, reported.length);
		Assert.equals("notify: queue full", reported[0]);
		Assert.isTrue(reported[1].indexOf("refused -1") >= 0, "a refused one-way call was not reported: " + reported[1]);
		Assert.same([7], handler.notified);
	}

	public function testFramesAfterAFailingCallInTheSameReadAreStillTaken():Void {
		var link = LinkedConnection.pair();
		var commands = new FailingCommands();
		var clientSession = new RPCSession<FailingCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new FailingHandler());
		reportsOf(serverSession);

		// Two calls arriving in one read, the first failing.
		link.server.bufferInbound = true;
		var failed = commands.lookup(0);
		var after = commands.lookup(9);
		link.server.bufferInbound = false;
		link.server.deliverBufferedAsOneRead();

		Assert.equals(RPCError.INTERNAL_MESSAGE, failed.error);
		Assert.equals("player-9", after.result, "the frame after a failing call was dropped");
	}

	public function testCallsWaitingOnThisSideSurviveAHandlerThatThrows():Void {
		// Each side both calls and answers. The server has a call out to the
		// client when a call from the client fails on the server: ending the
		// connection failed the server's own call too.
		var link = LinkedConnection.pair();
		var clientCommands = new FailingCommands();
		var serverCommands = new TestCommands();
		var clientSession = new RPCSession<FailingCommands>(link.client, clientCommands, new TestHandler());
		var serverSession = new RPCSession<TestCommands>(link.server, serverCommands, new FailingHandler());
		reportsOf(serverSession);

		link.client.bufferInbound = true;
		var outstanding = serverCommands.getName(1);
		clientCommands.lookup(0);
		Assert.isFalse(outstanding.completed, "the server's own call was failed");

		link.client.bufferInbound = false;
		link.client.flushBufferedReads();
		Assert.equals("player-1", outstanding.result);
	}

	public function testARuntimeHandlerThatThrowsTellsTheCallerNothingOfIt():Void {
		var link = LinkedConnection.pair();
		var clientSession = new RPCSession(link.client);
		var serverSession = new RPCSession(link.server);
		var reported = reportsOf(serverSession);
		var ended = endingOf(link.server);

		// It sent the caller `Std.string(error)`, whatever that held.
		serverSession.register(404, args -> throw "stack at /home/app/secret.hx:12");
		var failed:RPCResponse<String> = clientSession.request(404, [1]);
		Assert.equals(RPCError.INTERNAL_MESSAGE, failed.error);
		Assert.same(["op 404: stack at /home/app/secret.hx:12"], reported);

		serverSession.register(405, args -> throw new RPCError("quota exceeded"));
		var refused:RPCResponse<String> = clientSession.request(405, []);
		Assert.equals("quota exceeded", refused.error);
		Assert.equals(1, reported.length, "an answer the caller was given was reported");
		Assert.isFalse(ended.value);
	}

	public function testARuntimeOneWayCallThatThrowsIsReportedNotFatal():Void {
		var link = LinkedConnection.pair();
		var clientSession = new RPCSession(link.client);
		var serverSession = new RPCSession(link.server);
		var reported = reportsOf(serverSession);
		var ended = endingOf(link.server);

		// It rethrew, and the connection closed.
		serverSession.register(406, args -> throw "boom");
		serverSession.register(202, args -> "player-" + args[0]);
		clientSession.call(406, []);

		Assert.isFalse(ended.value, "a one-way runtime call throwing ended the connection");
		Assert.same(["op 406: boom"], reported);
		var after:RPCResponse<String> = clientSession.request(202, [3]);
		Assert.equals("player-3", after.result);
	}

	public function testAReportThatThrowsLeavesTheConnectionUp():Void {
		var link = LinkedConnection.pair();
		var commands = new FailingCommands();
		var clientSession = new RPCSession<FailingCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new FailingHandler());
		var ended = endingOf(link.server);
		serverSession.onHandlerError = (op, method, error) -> throw "the report failed";

		commands.notify(0);
		var failed = commands.lookup(0);

		Assert.isFalse(ended.value, "a report throwing ended the connection");
		Assert.equals(RPCError.INTERNAL_MESSAGE, failed.error);
		Assert.equals("player-2", commands.lookup(2).result);
	}

	public function testAFrameWhoseArgumentsDoNotDecodeStillEndsTheConnection():Void {
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server, null, new FailingHandler());
		var ended = endingOf(link.server);

		// A request for `lookup` with a byte where its Int should be: the
		// frame is not sound, so nothing after it can be trusted to line up.
		var payload = new ByteArrayOutput(8);
		payload.writeByte(crossbyte.rpc._internal.RPCWire.FLAG_REQUEST);
		payload.writeInt(Hash.fnv1a32(Bytes.ofString("lookup")));
		payload.writeVarUInt(1);
		payload.writeByte(0);
		payload.flush();
		// `bytesWritten`, not `length`: that is the buffer's capacity, and a
		// frame claiming it waits for a byte that never comes.
		var frame = new ByteArrayOutput(payload.bytesWritten + 4);
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		link.client.send(frame);

		Assert.isTrue(ended.value, "a frame that could not be read left the connection up");
	}

	// ---------------------------------------------------- frames and bounds

	public function testArgumentsAreNotTakenFromTheFrameAfterTheirs():Void {
		// A session with only a handler reads frames on the handler's lane;
		// one with runtime handlers too reads them on its own. Both.
		for (lane in ["handler", "session"]) {
			var link = LinkedConnection.pair();
			var handler = new FailingHandler();
			var serverSession = new RPCSession(link.server, null, handler);
			if (lane == "session") {
				serverSession.register(999, args -> null);
			}
			var ended = endingOf(link.server);

			// A request for `lookup` one Int short, and a sound one after it,
			// in one read. The Int was read from the next frame's length, and
			// the handler ran on it.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_REQUEST);
				out.writeInt(opOf("lookup"));
				out.writeVarUInt(1);
			});
			var sound = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_REQUEST);
				out.writeInt(opOf("lookup"));
				out.writeVarUInt(2);
				out.writeInt(9);
			});
			link.client.send(joined([short, sound]));

			Assert.same([], handler.looked, 'on the $lane lane, a handler ran on arguments from the frame after its own');
			Assert.isTrue(ended.value, 'on the $lane lane, a frame that ran past its end left the connection up');
		}
	}

	public function testAResponseIsNotTakenFromTheFrameAfterIts():Void {
		// A session with only commands, one with a handler as well, and one
		// with runtime handlers too each read responses on a lane of their own.
		for (lane in ["commands", "handler", "session"]) {
			var link = LinkedConnection.pair();
			var commands = new TestCommands();
			var clientSession = new RPCSession<TestCommands>(link.client, commands, lane == "commands" ? null : new TestHandler());
			if (lane == "session") {
				clientSession.register(999, args -> null);
			}
			var ended = endingOf(link.client);
			var pending = commands.getName(1);

			// An answer with no String in it, read from what followed: the
			// length of the next frame begins with a zero, which read as an
			// empty name.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RESPONSE);
				out.writeInt(opOf("getName"));
				out.writeVarUInt(pending.requestId);
			});
			link.server.send(joined([short, soundFrame()]));

			Assert.isTrue(pending.completed, 'on the $lane lane, the call was never settled');
			Assert.isFalse(pending.succeeded, 'on the $lane lane, a call was answered from the frame after its answer');
			Assert.isTrue(ended.value, 'on the $lane lane, a frame that ran past its end left the connection up');
		}
	}

	public function testAnErrorAnswerIsNotTakenFromTheFrameAfterIts():Void {
		// For a method the commands know, and for one they do not, which is
		// read on a path of its own.
		for (method in ["getName", "noSuchMethod"]) {
			var link = LinkedConnection.pair();
			var commands = new TestCommands();
			var clientSession = new RPCSession<TestCommands>(link.client, commands);
			var ended = endingOf(link.client);
			var pending = commands.getName(1);

			// An error with no message: it was failed with the empty one read
			// from the next frame, and the connection went on as if sound.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR);
				out.writeInt(opOf(method));
				out.writeVarUInt(pending.requestId);
			});
			link.server.send(joined([short, soundFrame()]));

			Assert.isTrue(ended.value, 'an error answer for $method that ran past its frame left the connection up');
			Assert.notEquals("", pending.error);
		}
	}

	public function testARuntimeAnswerIsNotTakenFromTheFrameAfterIts():Void {
		for (failed in [false, true]) {
			var link = LinkedConnection.pair();
			var clientSession = new RPCSession(link.client);
			var ended = endingOf(link.client);
			var pending:RPCResponse<Dynamic> = clientSession.request(600, []);

			// An Int answer whose tag is in the frame and whose Int is not, or
			// an error with no message: read from the next frame, as a number
			// or an empty message.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_RESPONSE | (failed ? RPCWire.FLAG_ERROR : 0));
				out.writeInt(600);
				out.writeVarUInt(pending.requestId);
				if (!failed) {
					out.writeByte(crossbyte.rpc._internal.RPCRuntimeCodec.TAG_INT);
				}
			});
			link.server.send(joined([short, soundFrame()]));

			var what = failed ? "an error" : "a value";
			Assert.isTrue(ended.value, 'a runtime answer missing $what left the connection up');
			Assert.isFalse(pending.succeeded, 'a runtime call was answered from the frame after its answer');
			Assert.notEquals("", pending.error);
		}
	}

	public function testARuntimeCallDoesNotTakeItsArgumentsFromTheNextFrame():Void {
		for (request in [true, false]) {
			var link = LinkedConnection.pair();
			var serverSession = new RPCSession(link.server);
			var ended = endingOf(link.server);
			var calls = 0;
			serverSession.register(500, args -> {
				calls++;
				return null;
			});
			serverSession.register(501, args -> null);

			// One Int argument, its tag in the frame and the Int itself not:
			// it was read from the length of the next frame.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RUNTIME | (request ? RPCWire.FLAG_REQUEST : 0));
				out.writeInt(500);
				if (request) {
					out.writeVarUInt(1);
				}
				out.writeVarUInt(1);
				out.writeByte(crossbyte.rpc._internal.RPCRuntimeCodec.TAG_INT);
			});
			var next = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RUNTIME);
				out.writeInt(501);
				out.writeVarUInt(0);
			});
			link.client.send(joined([short, next]));

			var kind = request ? "request" : "one-way call";
			Assert.equals(0, calls, 'a runtime $kind ran on arguments from the frame after its own');
			Assert.isTrue(ended.value);
		}
	}

	public function testAnAnswerLongerThanItsFrameIsRefusedBeforeAnythingIsMade():Void {
		var link = LinkedConnection.pair();
		var commands = new FailingCommands();
		var clientSession = new RPCSession<FailingCommands>(link.client, commands);
		var ended = endingOf(link.client);
		var pending = commands.blob(1);

		link.server.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RESPONSE);
			out.writeInt(opOf("blob"));
			out.writeVarUInt(pending.requestId);
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.isFalse(pending.succeeded);
		Assert.isTrue(ended.value);
		Assert.isTrue(ended.reason.indexOf("names more than it holds") >= 0, "refused for another reason: " + ended.reason);
	}

	public function testALengthLargerThanItsFrameIsRefusedBeforeAnythingIsMade():Void {
		var link = LinkedConnection.pair();
		var handler = new TestHandler();
		var serverSession = new RPCSession(link.server, null, handler);
		var ended = endingOf(link.server);

		// `sendData` with a Bytes argument claiming two gigabytes, in a frame
		// of a couple of dozen bytes. It was allocated before a byte of it
		// was read.
		link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(opOf("sendData"));
			out.writeInt(7);
			out.writeByte(1);
			out.writeDouble(1.25);
			out.writeVarUTF("a");
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.equals(0, handler.calls);
		Assert.isTrue(ended.value);
		Assert.isTrue(ended.reason.indexOf("names more than it holds") >= 0, "refused for another reason: " + ended.reason);
	}

	public function testARuntimeCountLargerThanItsFrameIsRefusedBeforeAnythingIsMade():Void {
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var ended = endingOf(link.server);
		serverSession.register(502, args -> null);

		// Two billion arguments, in a frame of ten bytes: an array that size
		// was made before any of them was read.
		link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RUNTIME);
			out.writeInt(502);
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.isTrue(ended.value);
		Assert.isTrue(ended.reason.indexOf("names more than it holds") >= 0, "refused for another reason: " + ended.reason);
	}

	public function testARuntimeBytesLongerThanItsFrameIsRefusedBeforeAnythingIsMade():Void {
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var ended = endingOf(link.server);
		serverSession.register(503, args -> null);

		link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RUNTIME);
			out.writeInt(503);
			out.writeVarUInt(1);
			out.writeByte(crossbyte.rpc._internal.RPCRuntimeCodec.TAG_BYTES);
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.isTrue(ended.value);
		Assert.isTrue(ended.reason.indexOf("names more than it holds") >= 0, "refused for another reason: " + ended.reason);
	}

	/** One frame: its length, then what `write` puts in it. **/
	private static function frameOf(write:ByteArrayOutput->Void):ByteArray {
		var payload = new ByteArrayOutput(64);
		write(payload);
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		return frame;
	}

	/** A well-formed frame to follow a short one: a response nobody asked for. **/
	private static function soundFrame():ByteArray {
		return frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RESPONSE);
			out.writeInt(opOf("getName"));
			out.writeVarUInt(999);
			out.writeVarUTF("x");
		});
	}

	/** Frames end to end, as one read delivers them. **/
	private static function joined(frames:Array<ByteArray>):ByteArray {
		var all = new ByteArray();
		for (frame in frames) {
			all.writeBytes(frame, 0, frame.length);
		}
		all.position = 0;
		return all;
	}

	private static inline function opOf(method:String):Int {
		return Hash.fnv1a32(Bytes.ofString(method));
	}

	/** What the session reports, as `method: error`, or `op N: error` for a runtime handler. **/
	private static function reportsOf(session:RPCSession<Dynamic, Dynamic>):Array<String> {
		var reported:Array<String> = [];
		session.onHandlerError = (op, method, error) -> reported.push((method != null ? method : 'op $op') + ": " + Std.string(error));
		return reported;
	}

	/** Whether the connection has been closed or has failed, and why it failed. **/
	private static function endingOf(connection:LinkedConnection):{value:Bool, reason:String} {
		var ended = {value: false, reason: ""};
		connection.onClose = _ -> ended.value = true;
		connection.onError = reason -> {
			ended.value = true;
			ended.reason = Std.string(reason);
		};
		return ended;
	}
}

private class TestCommands extends RPCCommands {
	public function new() {}

	@:rpc public function sendData(id:Int, enabled:Bool, ratio:Float, name:String, bytes:Bytes, ?tag:String):Void {}

	@:rpc public function getName(id:Int):RPCResponse<String> {}
}

private class FailingCommands extends RPCCommands {
	public function new() {}

	@:rpc public function lookup(id:Int):RPCResponse<String> {}

	@:rpc public function notify(id:Int):Void {}

	@:rpc public function blob(size:Int):RPCResponse<Bytes> {}
}

private class FailingHandler extends RPCHandler {
	public var notified:Array<Int> = [];
	public var looked:Array<Int> = [];

	public function new() {}

	@:rpc public function lookup(id:Int):String {
		looked.push(id);
		if (id < 0) {
			throw new RPCError('no player $id');
		}
		if (id == 0) {
			throw "database at /var/lib/players refused";
		}
		return 'player-$id';
	}

	@:rpc public function blob(size:Int):Bytes {
		return Bytes.alloc(size);
	}

	@:rpc public function notify(id:Int):Void {
		if (id < 0) {
			throw new RPCError('refused $id');
		}
		if (id == 0) {
			throw "queue full";
		}
		notified.push(id);
	}
}

private class WideCommands extends RPCCommands {
	public function new() {}

	@:rpc public function m01(v:Int):Void {}

	@:rpc public function m02(v:Int):Void {}

	@:rpc public function m03(v:Int):Void {}

	@:rpc public function m04(v:Int):Void {}

	@:rpc public function m05(v:Int):Void {}

	@:rpc public function m06(v:Int):Void {}

	@:rpc public function m07(v:Int):Void {}

	@:rpc public function m08(v:Int):Void {}

	@:rpc public function m09(v:Int):Void {}

	@:rpc public function m10(v:Int):Void {}
}

// Ten methods, because the handler macro switches from a direct switch to a
// generated perfect hash above eight -- and that path had no test on any
// target. It builds its tables at compile time on the eval interpreter and
// emits the same arithmetic to run on the target, so the two have to agree
// about what an opcode hashes to. They did not on js: every index differed,
// and every dispatch would have thrown "Unknown RPC op".
private class WideHandler extends RPCHandler {
	public var seen:Array<String> = [];

	public function new() {}

	@:rpc public function m01(v:Int):Void {
		seen.push("m01:" + v);
	}

	@:rpc public function m02(v:Int):Void {
		seen.push("m02:" + v);
	}

	@:rpc public function m03(v:Int):Void {
		seen.push("m03:" + v);
	}

	@:rpc public function m04(v:Int):Void {
		seen.push("m04:" + v);
	}

	@:rpc public function m05(v:Int):Void {
		seen.push("m05:" + v);
	}

	@:rpc public function m06(v:Int):Void {
		seen.push("m06:" + v);
	}

	@:rpc public function m07(v:Int):Void {
		seen.push("m07:" + v);
	}

	@:rpc public function m08(v:Int):Void {
		seen.push("m08:" + v);
	}

	@:rpc public function m09(v:Int):Void {
		seen.push("m09:" + v);
	}

	@:rpc public function m10(v:Int):Void {
		seen.push("m10:" + v);
	}
}

private class TestHandler extends RPCHandler {
	public var calls:Int = 0;
	public var lastId:Int = 0;
	public var lastEnabled:Bool = false;
	public var lastRatio:Float = 0;
	public var lastName:String;
	public var lastBytes:Bytes;
	public var lastTag:String;

	public function new() {}

	@:rpc public function sendData(id:Int, enabled:Bool, ratio:Float, name:String, bytes:Bytes, ?tag:String):Void {
		calls++;
		lastId = id;
		lastEnabled = enabled;
		lastRatio = ratio;
		lastName = name;
		lastBytes = bytes;
		lastTag = tag;
	}

	@:rpc public function getName(id:Int):String {
		return 'player-$id';
	}
}

private interface ContractShape {
	function announce(id:Int, message:String):Void;
	function getLabel(id:Int):String;
}

@:rpcContract(ContractShape)
private class ContractCommands extends RPCCommands {
	public function new() {}
}

private class ContractHandler extends RPCHandler implements ContractShape {
	public var announceCalls:Int = 0;
	public var lastAnnounceId:Int = 0;
	public var lastAnnounceMessage:String = null;

	public function new() {}

	public function announce(id:Int, message:String):Void {
		announceCalls++;
		lastAnnounceId = id;
		lastAnnounceMessage = message;
	}

	public function getLabel(id:Int):String {
		return 'label-$id';
	}
}

private class LinkedConnection implements INetConnection {
	public var remoteAddress(get, never):String;
	public var remotePort(get, never):Int;
	public var localAddress(get, never):String;
	public var localPort(get, never):Int;
	public var connected(get, never):Bool;
	public var readEnabled(get, set):Bool;
	public var onData(get, set):ByteArrayInput->Void;
	public var onClose(get, set):Reason->Void;
	public var onError(get, set):Reason->Void;
	public var onReady(get, set):Void->Void;
	public var protocol:Protocol = TCP;
	public var inTimestamp(default, null):Float = 0;
	public var outTimestamp(default, null):Float = 0;
	public var bufferInbound:Bool = false;

	public var peer:LinkedConnection;
	@:noCompletion private var __pendingInputs:Array<ByteArray> = [];

	@:noCompletion private var __readEnabled:Bool = false;
	@:noCompletion private var __onData:ByteArrayInput->Void = input -> {};
	@:noCompletion private var __onClose:Reason->Void = reason -> {};
	@:noCompletion private var __onError:Reason->Void = reason -> {};
	@:noCompletion private var __onReady:Void->Void = () -> {};

	public static function pair():{client:LinkedConnection, server:LinkedConnection} {
		var client = new LinkedConnection();
		var server = new LinkedConnection();
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	public function new() {}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {
		outTimestamp = Timer.getTime();
		if (peer != null) {
			peer.receive(data);
		}
	}

	public function close():Void {
		__readEnabled = false;
		__onClose(Closed);
	}

	@:noCompletion private function receive(data:ByteArray):Void {
		inTimestamp = Timer.getTime();
		var copy = new ByteArray();
		copy.writeBytes(data, 0, data.length);
		copy.position = 0;
		if (bufferInbound) {
			__pendingInputs.push(copy);
			return;
		}
		if (!__readEnabled) {
			return;
		}
		__onData(copy);
	}

	/** Hands everything buffered to the session in one read, as a socket would. **/
	public function deliverBufferedAsOneRead():Void {
		var joined = new ByteArray();
		for (input in __pendingInputs) {
			joined.writeBytes(input, 0, input.length);
		}
		__pendingInputs = [];
		joined.position = 0;
		__onData(joined);
	}

	public function flushBufferedReads():Void {
		if (!__readEnabled) {
			__pendingInputs = [];
			return;
		}
		var pending = __pendingInputs;
		__pendingInputs = [];
		for (input in pending) {
			input.position = 0;
			__onData(input);
		}
	}

	@:noCompletion private inline function get_remoteAddress():String {
		return "127.0.0.1";
	}

	@:noCompletion private inline function get_remotePort():Int {
		return 1;
	}

	@:noCompletion private inline function get_localAddress():String {
		return "127.0.0.1";
	}

	@:noCompletion private inline function get_localPort():Int {
		return 1;
	}

	@:noCompletion private inline function get_connected():Bool {
		return true;
	}

	@:noCompletion private inline function get_readEnabled():Bool {
		return __readEnabled;
	}

	@:noCompletion private inline function set_readEnabled(value:Bool):Bool {
		return __readEnabled = value;
	}

	@:noCompletion private inline function get_onData():ByteArrayInput->Void {
		return __onData;
	}

	@:noCompletion private inline function set_onData(value:ByteArrayInput->Void):ByteArrayInput->Void {
		return __onData = value != null ? value : input -> {};
	}

	@:noCompletion private inline function get_onClose():Reason->Void {
		return __onClose;
	}

	@:noCompletion private inline function set_onClose(value:Reason->Void):Reason->Void {
		return __onClose = value != null ? value : reason -> {};
	}

	@:noCompletion private inline function get_onError():Reason->Void {
		return __onError;
	}

	@:noCompletion private inline function set_onError(value:Reason->Void):Reason->Void {
		return __onError = value != null ? value : reason -> {};
	}

	@:noCompletion private inline function get_onReady():Void->Void {
		return __onReady;
	}

	@:noCompletion private inline function set_onReady(value:Void->Void):Void->Void {
		return __onReady = value != null ? value : () -> {};
	}
}
