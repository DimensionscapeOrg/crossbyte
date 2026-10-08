package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayOutput;
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
	process with it, and the whole suite with it on jvm.
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

	/**
		`respond()` binds or replaces the responder, as it says: the one bound
		last hears the outcome, and only it, so a responder replaced (the one
		passed to the constructor included) is not told as well. Handlers added
		with `then` all run beside it.
	**/
	public function testRespondReplacesTheResponder():Void {
		var heard:Array<String> = [];
		var response = new RPCResponse<Int>(1, 7, new Responder<Int>(v -> heard.push("constructed " + v)));
		response.respond(new Responder<Int>(v -> heard.push("first " + v)));
		response.respond(new Responder<Int>(v -> heard.push("replacement " + v), m -> heard.push("replacement error " + m)));
		response.then(v -> heard.push("then " + v));
		@:privateAccess response.__resolve(42);
		Assert.same(["replacement 42", "then 42"], heard);

		// One bound after the answer hears it at once, as `then` does.
		response.respond(new Responder<Int>(v -> heard.push("late " + v)));
		Assert.same(["replacement 42", "then 42", "late 42"], heard);

		// A failure goes to the responder bound last the same way.
		var failed:Array<String> = [];
		var failing = new RPCResponse<Int>(2, 7);
		failing.respond(new Responder<Int>(null, m -> failed.push("first " + m)));
		failing.respond(new Responder<Int>(null, m -> failed.push("second " + m)));
		@:privateAccess failing.__fail("refused");
		Assert.same(["second refused"], failed);
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
		// A one-way call for an op the handler has not got runs nothing, and
		// is passed over with the session told; the connection stays.
		var link = LinkedConnection.pair();
		var handler = new TestHandler();
		var serverSession = new RPCSession(link.server, null, handler);
		var closed:Bool = false;
		var errored:Bool = false;
		link.server.onClose = _ -> closed = true;
		link.server.onError = _ -> errored = true;
		var passed = passedOverBy(serverSession);

		var payload = new ByteArrayOutput(5);
		payload.writeByte(0);
		payload.writeInt(0x1234567);
		payload.flush();

		var frame = new ByteArrayOutput(payload.length + 4);
		frame.writeInt(payload.length);
		frame.writeBytes(payload);

		link.client.send(frame);
		Assert.equals(0, handler.calls);
		Assert.isFalse(closed || errored, "a one-way call for an unknown op ended the connection");
		Assert.same(["op 1234567, call 0: no method answers op 0x01234567"], passed);
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

	/**
		A `ByteArray` goes on the runtime lane as the bytes it holds, as the
		guide says `haxe.io.Bytes` does, and a `ByteArray` is one: at run time
		it is a subclass of `Bytes`, so a codec matching the `Bytes` class
		exactly would refuse it ("Unsupported runtime RPC value") in an argument
		and in an answer alike.
	**/
	public function testTheRuntimeLaneCarriesAByteArray():Void {
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var captured:Array<Dynamic> = null;
		serverSession.register(104, args -> {
			captured = args;
			var answer = new ByteArray();
			answer.writeUTFBytes("got " + (cast args[0] : Bytes).toString());
			return answer;
		});
		var clientSession = new RPCSession(link.client);

		// Written over what it held before, which must not go with it.
		var bytes = new ByteArray();
		bytes.writeUTFBytes("written first and then cleared away");
		bytes.clear();
		bytes.writeUTFBytes("abc");

		var response:RPCResponse<Bytes> = null;
		try {
			response = clientSession.request(104, [bytes]);
		} catch (error:Dynamic) {
			Assert.fail("a ByteArray was refused: " + Std.string(error));
			return;
		}
		Require.notNull(captured);
		Assert.equals("abc", (cast captured[0] : Bytes).toString());
		Assert.isTrue(response.succeeded, response.error);
		Assert.equals("got abc", response.result == null ? null : response.result.toString());
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

	public function testAMethodTakesAsManyArgumentsAsItDeclares():Void {
		// A handler's @:rpc method is not held to eight arguments, which nothing
		// else is: a commands stub or a contract with more builds, so a handler
		// written without a contract must be able to answer it. Nothing in the
		// encoding needs a limit. Ten here, the last optional, so their order
		// and the optional's flag are both checked past eight.
		var link = LinkedConnection.pair();
		var commands = new ManyArgumentCommands();
		var clientSession = new RPCSession<ManyArgumentCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new ManyArgumentHandler());

		Assert.equals("sum:36:9", commands.describe(1, 2, 3, 4, 5, 6, 7, 8, "sum", 9).result);
		Assert.equals("sum:36:none", commands.describe(1, 2, 3, 4, 5, 6, 7, 8, "sum").result);
	}

	public function testRuntimeMessagesDoNotHitCompileTimeHandlerWhenOpcodeCollides():Void {
		var link = LinkedConnection.pair();
		var compileHandler = new TestHandler();
		var serverSession = new RPCSession(link.server, null, compileHandler);
		var runtimeCalls:Int = 0;
		final collidingOp:Int = opOf("sendData(i32,bool,f64,utf8,bytes,?utf8)");

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

		// A handler throwing is not taken for the peer sending something
		// unreadable: the connection stays, and the caller is told what failed.
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

	public function testAListenerThatThrowsLeavesTheConnectionAndTheOtherCallsAlone():Void {
		// `then` callbacks, RESULT and ERROR listeners are all contained: a
		// listener's throw reaching the session reading the answers would be
		// taken for a frame it could not read, closing the connection and
		// failing every call still waiting, including the next answer in the
		// same read.
		var link = LinkedConnection.pair();
		var commands = new FailingCommands();
		var clientSession = new RPCSession<FailingCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new FailingHandler());
		reportsOf(serverSession);
		var ended = endingOf(link.client);
		var logged = [];
		var sink = crossbyte.utils.Logger.sink;
		crossbyte.utils.Logger.sink = line -> logged.push(line);

		link.client.bufferInbound = true;
		var answered = commands.lookup(1);
		answered.addEventListener(RPCResponse.RESULT, _ -> throw "a bug in a result listener");
		var refused = commands.lookup(-1);
		refused.addEventListener(RPCResponse.ERROR, _ -> throw "a bug in an error listener");
		var after = commands.lookup(2);
		link.client.bufferInbound = false;
		link.client.deliverBufferedAsOneRead();
		crossbyte.utils.Logger.sink = sink;

		Assert.equals("player-1", answered.result);
		Assert.equals("no player -1", refused.error);
		Assert.equals("player-2", after.result, "the call answered after a throwing listener's was failed");
		Assert.isFalse(ended.value, "a listener throwing ended the connection");
		Assert.equals(2, logged.length, "the listeners' throws were not reported: " + logged.join(" | "));
	}

	public function testCallsWaitingOnThisSideSurviveAHandlerThatThrows():Void {
		// Each side both calls and answers. The server has a call out to the
		// client when a call from the client fails on the server: ending the
		// connection would fail the server's own call too.
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

		// The caller is not sent `Std.string(error)`, whatever that held.
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

		// Not rethrown, and the connection does not close.
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

	public function testAFrameWhoseArgumentsDoNotDecodeIsAnsweredAndTheConnectionStays():Void {
		// A request for `lookup` with a byte where its Int should be. The frame
		// carries its length, so the next is read where it begins, and neither
		// the connection nor the calls waiting on it end.
		var link = LinkedConnection.pair();
		var handler = new FailingHandler();
		var serverSession = new RPCSession(link.server, null, handler);
		var ended = endingOf(link.server);
		var passed = passedOverBy(serverSession);
		var answers = errorAnswersAt(link.client);

		var payload = new ByteArrayOutput(8);
		payload.writeByte(crossbyte.rpc._internal.RPCWire.FLAG_REQUEST);
		payload.writeInt(opOf("lookup(i32):utf8"));
		payload.writeVarUInt(1);
		payload.writeByte(0);
		payload.flush();
		// `bytesWritten`, not `length`: that is the buffer's capacity, and a
		// frame claiming it waits for a byte that never comes.
		var frame = new ByteArrayOutput(payload.bytesWritten + 4);
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		link.client.send(frame);

		Assert.isFalse(ended.value, "a call whose arguments did not read ended the connection");
		Assert.same([], handler.looked);
		Assert.same(["1: " + RPCError.UNREADABLE_MESSAGE], answers);
		Assert.equals(1, passed.length);
		Assert.stringContains("arguments could not be read", passed[0]);
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
			var answers = errorAnswersAt(link.client);

			// A request for `lookup` one Int short, and a sound one after it,
			// in one read. The Int must not be read from the next frame's length,
			// with the handler run on it: the short one is answered as unreadable
			// and the sound one runs on its own.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_REQUEST);
				out.writeInt(opOf("lookup(i32):utf8"));
				out.writeVarUInt(1);
			});
			var sound = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_REQUEST);
				out.writeInt(opOf("lookup(i32):utf8"));
				out.writeVarUInt(2);
				out.writeInt(9);
			});
			link.client.send(joined([short, sound]));

			Assert.same([9], handler.looked, 'on the $lane lane, a handler ran on arguments from the frame after its own');
			Assert.same(["1: " + RPCError.UNREADABLE_MESSAGE], answers, 'on the $lane lane, the short call was not answered as unreadable');
			Assert.isFalse(ended.value, 'on the $lane lane, a frame that ran past its end ended the connection');
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

			// An answer with no String in it, which read from what followed
			// would take the length of the next frame, beginning with a zero, for
			// an empty name.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RESPONSE);
				out.writeInt(opOf("getName(i32):utf8"));
				out.writeVarUInt(pending.requestId);
			});
			link.server.send(joined([short, soundFrame()]));

			Assert.isTrue(pending.completed, 'on the $lane lane, the call was never settled');
			Assert.isFalse(pending.succeeded, 'on the $lane lane, a call was answered from the frame after its answer');
			Assert.stringContains("could not be read", pending.error);
			Assert.isFalse(ended.value, 'on the $lane lane, an answer that ran past its end ended the connection');
		}
	}

	public function testAnErrorAnswerIsNotTakenFromTheFrameAfterIts():Void {
		// For a method the commands know, and for one they do not, which is
		// read on a path of its own.
		for (method in ["getName(i32):utf8", "noSuchMethod()"]) {
			var link = LinkedConnection.pair();
			var commands = new TestCommands();
			var clientSession = new RPCSession<TestCommands>(link.client, commands);
			var ended = endingOf(link.client);
			var pending = commands.getName(1);

			// An error with no message, which must not be failed with an empty
			// one read from the next frame, the connection going on as if sound.
			var short = frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RESPONSE | RPCWire.FLAG_ERROR);
				out.writeInt(opOf(method));
				out.writeVarUInt(pending.requestId);
			});
			link.server.send(joined([short, soundFrame()]));

			Assert.isFalse(ended.value, 'an error answer for $method that ran past its frame ended the connection');
			Assert.isTrue(pending.completed && !pending.succeeded, 'an error answer for $method that did not read left its call waiting');
			Assert.stringContains("could not be read", pending.error);
			Assert.isFalse(Std.isOfType(pending.cause, RPCError), "an answer that did not read became the other side's refusal");
		}
	}

	public function testARuntimeAnswerIsNotTakenFromTheFrameAfterIts():Void {
		for (failed in [false, true]) {
			var link = LinkedConnection.pair();
			var clientSession = new RPCSession(link.client);
			var ended = endingOf(link.client);
			var pending:RPCResponse<Dynamic> = clientSession.request(600, []);

			// An Int answer whose tag is in the frame and whose Int is not, or
			// an error with no message: not read from the next frame, as a number
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
			Assert.isFalse(ended.value, 'a runtime answer missing $what ended the connection');
			Assert.isFalse(pending.succeeded, 'a runtime call was answered from the frame after its answer');
			Assert.stringContains("could not be read", pending.error);
		}
	}

	public function testARuntimeCallDoesNotTakeItsArgumentsFromTheNextFrame():Void {
		for (request in [true, false]) {
			var link = LinkedConnection.pair();
			var serverSession = new RPCSession(link.server);
			var ended = endingOf(link.server);
			var answers = errorAnswersAt(link.client);
			var calls = 0;
			var after = 0;
			serverSession.register(500, args -> {
				calls++;
				return null;
			});
			serverSession.register(501, args -> {
				after++;
				return null;
			});

			// One Int argument, its tag in the frame and the Int itself not, which
			// must not be read from the length of the next frame.
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
			Assert.equals(1, after, 'the frame after a runtime $kind that did not read was not taken');
			Assert.same(request ? ["1: " + RPCError.UNREADABLE_MESSAGE] : [], answers);
			Assert.isFalse(ended.value);
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
			out.writeInt(opOf("blob(i32):bytes"));
			out.writeVarUInt(pending.requestId);
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.isFalse(pending.succeeded);
		Assert.isFalse(ended.value);
		Assert.stringContains("names more than it holds", pending.error);
	}

	public function testALengthLargerThanItsFrameIsRefusedBeforeAnythingIsMade():Void {
		var link = LinkedConnection.pair();
		var handler = new TestHandler();
		var serverSession = new RPCSession(link.server, null, handler);
		var ended = endingOf(link.server);
		var passed = passedOverBy(serverSession);

		// `sendData` with a Bytes argument claiming two gigabytes, in a frame
		// of a couple of dozen bytes: nothing is allocated for it before a byte
		// of it is read.
		link.client.send(frameOf(out -> {
			out.writeByte(0);
			out.writeInt(opOf("sendData(i32,bool,f64,utf8,bytes,?utf8)"));
			out.writeInt(7);
			out.writeByte(1);
			out.writeDouble(1.25);
			out.writeVarUTF("a");
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.equals(0, handler.calls);
		Assert.isFalse(ended.value);
		Assert.equals(1, passed.length);
		Assert.stringContains("names more than it holds", passed[0]);
	}

	public function testARuntimeCountLargerThanItsFrameIsRefusedBeforeAnythingIsMade():Void {
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var ended = endingOf(link.server);
		var passed = passedOverBy(serverSession);
		serverSession.register(502, args -> null);

		// Two billion arguments, in a frame of ten bytes: no array that size
		// is made before any of them is read.
		link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RUNTIME);
			out.writeInt(502);
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.isFalse(ended.value);
		Assert.equals(1, passed.length);
		Assert.stringContains("names more than it holds", passed[0]);
	}

	public function testARuntimeBytesLongerThanItsFrameIsRefusedBeforeAnythingIsMade():Void {
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var ended = endingOf(link.server);
		var passed = passedOverBy(serverSession);
		serverSession.register(503, args -> null);

		link.client.send(frameOf(out -> {
			out.writeByte(RPCWire.FLAG_RUNTIME);
			out.writeInt(503);
			out.writeVarUInt(1);
			out.writeByte(crossbyte.rpc._internal.RPCRuntimeCodec.TAG_BYTES);
			out.writeVarUInt(0x7FFFFFFF);
		}));

		Assert.isFalse(ended.value);
		Assert.equals(1, passed.length);
		Assert.stringContains("names more than it holds", passed[0]);
	}

	public function testARuntimeValueOfAKindNotKnownIsACallNotTaken():Void {
		// A tag a later release may add: the call it is in cannot be read, and
		// is answered so, rather than the connection ended.
		var link = LinkedConnection.pair();
		var serverSession = new RPCSession(link.server);
		var ended = endingOf(link.server);
		var answers = errorAnswersAt(link.client);
		var calls = 0;
		serverSession.register(504, args -> {
			calls++;
			return null;
		});

		link.client.send(joined([
			frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RUNTIME | RPCWire.FLAG_REQUEST);
				out.writeInt(504);
				out.writeVarUInt(3);
				out.writeVarUInt(1);
				out.writeByte(42);
			}),
			frameOf(out -> {
				out.writeByte(RPCWire.FLAG_RUNTIME);
				out.writeInt(504);
				out.writeVarUInt(0);
			})
		]));

		Assert.isFalse(ended.value);
		Assert.same(["3: " + RPCError.UNREADABLE_MESSAGE], answers);
		Assert.equals(1, calls, "the call after a value of an unknown kind was not taken");
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
			out.writeInt(opOf("getName(i32):utf8"));
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

	/** The op of a method's signature; see `RPCOps`. **/
	private static inline function opOf(signature:String):Int {
		return crossbyte.rpc._internal.RPCOps.opOf(signature);
	}

	/** What `onUnreadableFrame` is told, as `op <hex>, call <id>: <reason>`. **/
	private static function passedOverBy(session:RPCSession<Dynamic, Dynamic>):Array<String> {
		var passed:Array<String> = [];
		session.onUnreadableFrame = (op, requestId, reason) -> passed.push('op ${StringTools.hex(op)}, call $requestId: $reason');
		return passed;
	}

	/** Each error answer `connection` is sent from now on, as `<id>: <message>`; nothing reads it otherwise. **/
	private static function errorAnswersAt(connection:LinkedConnection):Array<String> {
		var answers:Array<String> = [];
		connection.readEnabled = true;
		connection.onData = input -> {
			while (input.bytesAvailable >= 4) {
				final end:Int = input.position + 4 + input.readInt();
				final flags:Int = input.readByte();
				input.readInt();
				if ((flags & RPCWire.FLAG_ERROR) != 0) {
					final id:Int = input.readVarUInt();
					answers.push(id + ": " + input.readVarUTF());
				}
				input.position = end;
			}
		};
		return answers;
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

private class ManyArgumentCommands extends RPCCommands {
	public function new() {}

	@:rpc public function describe(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, h:Int, label:String, ?extra:Int):RPCResponse<String> {}
}

private class ManyArgumentHandler extends RPCHandler {
	public function new() {}

	@:rpc public function describe(a:Int, b:Int, c:Int, d:Int, e:Int, f:Int, g:Int, h:Int, label:String, ?extra:Int):String {
		return label + ":" + (a + b + c + d + e + f + g + h) + ":" + (extra == null ? "none" : Std.string(extra));
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
// generated perfect hash above eight. It builds its tables at compile time
// on the eval interpreter and emits the same arithmetic to run on the
// target, so the two have to agree about what an opcode hashes to; on js,
// if they did not, every index would differ, and every dispatch would throw
// "Unknown RPC op".
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
