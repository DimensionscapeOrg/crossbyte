package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import crossbyte.core.CrossByte;
import crossbyte.io.ByteArray;
import utest.Assert;

/**
	Handlers that answer later: a method returning `Future<T>` -- and a
	runtime handler returning one -- is answered once the future completes.

	A handler had to answer in the call it was made in, so one whose answer
	depended on something slow -- a hub asking an instance host for a match --
	had nothing to send back by the time it returned. The wire, the calling
	side and handlers that answer at once are as they were.
**/
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.core.CrossByte)
class RPCAsyncTest extends utest.Test {
	// ---- Completer ----

	public function testACompleterCompletesItsFutureOnce():Void {
		var completer = new Completer<Int>();
		Assert.isFalse(completer.completed);
		Assert.isTrue(completer.complete(1));
		Assert.isFalse(completer.complete(2), "a second completion was taken");
		Assert.isFalse(completer.fail("late"), "a failure after completion was taken");
		Assert.isTrue(completer.future.succeeded);
		Assert.equals(1, completer.future.result);
	}

	public function testACompleterFailsAsAThrowWould():Void {
		var refused = new Completer<Int>();
		var error = new RPCError("No room.");
		refused.fail(error);
		Assert.equals("No room.", refused.future.error);
		Assert.equals(error, refused.future.cause);

		var plain = new Completer<Int>();
		plain.future.catchError(_ -> {});
		plain.fail("database unavailable");
		Assert.equals("database unavailable", plain.future.error);
	}

	// ---- the compiled lane ----

	public function testAFutureCompleteAlreadyIsAnsweredAtOnce():Void {
		var fixture = new LaterFixture();
		var response = fixture.commands.cached(21);
		Assert.isTrue(response.completed);
		Assert.equals(42, response.result);
		Assert.equals(0, fixture.server.callsWaiting);
	}

	public function testAnAnswerIsSentWhenItsFutureCompletes():Void {
		var fixture = new LaterFixture();
		var response = fixture.commands.lookup("ada");
		Assert.isFalse(response.completed, "answered before the future completed");
		Assert.equals(1, fixture.server.callsWaiting);

		fixture.handler.waiting.get("ada").complete("Ada Lovelace");

		Assert.isTrue(response.completed);
		Assert.equals("Ada Lovelace", response.result);
		Assert.equals(0, fixture.server.callsWaiting);
	}

	public function testAFutureFailingWithAnRPCErrorIsTheCallersAnswer():Void {
		var fixture = new LaterFixture();
		var response = fixture.commands.lookup("nobody");
		fixture.handler.waiting.get("nobody").fail(new RPCError("No such user."));

		Assert.isTrue(response.completed);
		Assert.equals("No such user.", response.error);
		Assert.same([], fixture.reported, "a failure meant for the caller was reported");
	}

	public function testAFutureFailingWithAnythingElseIsAnInternalError():Void {
		var fixture = new LaterFixture();
		var response = fixture.commands.lookup("ada");
		fixture.handler.waiting.get("ada").fail("database unavailable at 10.0.0.7");

		Assert.equals(RPCError.INTERNAL_MESSAGE, response.error, "the caller was told what it should not see");
		Assert.same(["lookup: database unavailable at 10.0.0.7"], fixture.reported);
	}

	public function testAThrowBeforeTheFutureIsAnsweredAsAThrowIs():Void {
		var fixture = new LaterFixture();
		var response = fixture.commands.lookup("");
		Assert.equals("A name is needed.", response.error);
		Assert.equals(0, fixture.server.callsWaiting);
	}

	public function testAfterCallIsToldWhenTheFutureCompletes():Void {
		var fixture = new LaterFixture();
		fixture.commands.lookup("ada");
		Assert.same([], fixture.handler.afterCalls, "afterCall ran when the method returned");

		fixture.handler.waiting.get("ada").complete("Ada");
		fixture.commands.lookup("bob");
		fixture.handler.waiting.get("bob").fail(new RPCError("gone"));

		Assert.same(["lookup ok", "lookup gone"], fixture.handler.afterCalls);
	}

	public function testCallsWaitingAreLimited():Void {
		var fixture = new LaterFixture();
		fixture.server.maxCallsWaiting = 2;
		var first = fixture.commands.lookup("a");
		var second = fixture.commands.lookup("b");
		var third = fixture.commands.lookup("c");

		Assert.isTrue(third.completed, "a call past the limit was left waiting");
		Assert.equals(RPCError.BUSY_MESSAGE, third.error);
		Assert.isFalse(fixture.handler.waiting.exists("c"), "the method ran for a call past the limit");
		Assert.same([], fixture.reported);

		fixture.handler.waiting.get("a").complete("A");
		var fourth = fixture.commands.lookup("d");
		Assert.isFalse(fourth.completed, "a call was refused after one had finished");
		Assert.equals(2, fixture.server.callsWaiting);
	}

	public function testAnAnswerCompletingAfterItsConnectionWentIsDropped():Void {
		var fixture = new LaterFixture();
		var response = fixture.commands.lookup("ada");
		fixture.link.server.close();

		fixture.handler.waiting.get("ada").complete("Ada");

		Assert.isFalse(response.completed, "an answer was sent on a connection that had gone");
		Assert.equals(0, fixture.server.callsWaiting);
		Assert.same(["lookup ok"], fixture.handler.afterCalls);
	}

	public function testAOneWayCallsLaterFailureIsReported():Void {
		var fixture = new LaterFixture();
		fixture.commands.fire(3);
		fixture.handler.fired.fail("boom");
		Assert.same(["fire: boom"], fixture.reported);
	}

	public function testForwardingAnotherCallPassesItsRefusalOn():Void {
		// The hub answers its client with what it asks an instance host: the
		// host's refusal is an RPCError it meant its caller to see, and the
		// hub's client sees it too.
		var hostLink = LinkedConnection.pair();
		var hostCommands = new InstanceCommands();
		var session1 = new RPCSession<InstanceCommands>(hostLink.client, hostCommands);
		var session2 = new RPCSession(hostLink.server, null, new InstanceHandler());

		var clientLink = LinkedConnection.pair();
		var hub = new HubHandler(hostCommands);
		var hubSession = new RPCSession(clientLink.server, null, hub);
		var hubReported:Array<String> = [];
		hubSession.onHandlerError = (op, method, error) -> hubReported.push(Std.string(error));
		var client = new HubCommands();
		var session3 = new RPCSession<HubCommands>(clientLink.client, client);

		Assert.equals(7, client.join("eu").result);
		Assert.equals("No instance has room.", client.join("full").error);
		Assert.same([], hubReported);
	}

	public function testAContractCanAnswerLater():Void {
		var link = LinkedConnection.pair();
		var handler = new LaterContractHandler();
		var session4 = new RPCSession(link.server, null, handler);
		var commands = new LaterContractCommands();
		var session5 = new RPCSession<LaterContractCommands>(link.client, commands);

		// RPCResponse<String>, as for a method that answers at once.
		var response:RPCResponse<String> = commands.find(3);
		Assert.isFalse(response.completed);
		handler.finding.complete("three");
		Assert.equals("three", response.result);
	}

	// ---- the runtime lane ----

	public function testARuntimeHandlerCanAnswerLater():Void {
		var link = LinkedConnection.pair();
		var server = new RPCSession(link.server);
		var client = new RPCSession(link.client);
		var completer:Completer<Dynamic> = null;
		server.register(40, args -> {
			completer = new Completer<Dynamic>();
			return completer.future;
		});

		var answered:RPCResponse<Dynamic> = client.request(40, [1]);
		Assert.isFalse(answered.completed);
		Assert.equals(1, server.callsWaiting);
		completer.complete("later");
		Assert.equals("later", answered.result);

		var refused:RPCResponse<Dynamic> = client.request(40, [2]);
		completer.fail(new RPCError("Not now."));
		Assert.equals("Not now.", refused.error);
		Assert.equals(0, server.callsWaiting);
	}

	// ---- threads ----

	public function testAFutureCompletedOnAnotherThreadIsAnsweredOnTheSessionsThread():Void {
		// A connection is not thread-safe. Completed on a worker, the answer is
		// handed to the session's runtime and sent at its next tick, from its
		// own thread.
		#if (cpp || jvm || hl || neko || eval)
		var client = new ThreadNotingConnection();
		var server = new ThreadNotingConnection();
		client.peer = server;
		server.peer = client;
		var handler = new LaterHandler();
		var commands = new LaterCommands();
		var serverSession = new RPCSession(server, null, handler);
		var clientSession = new RPCSession<LaterCommands>(client, commands);
		ThreadNotingConnection.markThisThread();

		var response = commands.lookup("ada");
		var completer = handler.waiting.get("ada");
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			completer.complete("Ada");
			done.release();
		});
		Assert.isTrue(done.wait(5.0), "the worker never completed the future");
		Assert.isFalse(response.completed, "answered from the worker's thread");

		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + 2.0;
		while (!response.completed && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
		}
		Assert.equals("Ada", response.result);
		Assert.equals(0, server.sentFromOtherThreads, "a frame was sent from another thread");
		#else
		Assert.pass();
		#end
	}
}

private class LaterFixture {
	public final link:{client:LinkedConnection, server:LinkedConnection};
	public final handler:LaterHandler = new LaterHandler();
	public final commands:LaterCommands = new LaterCommands();
	public final server:RPCSession<Dynamic, Dynamic>;
	public final reported:Array<String> = [];

	public function new() {
		link = LinkedConnection.pair();
		server = new RPCSession(link.server, null, handler);
		server.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));
		var session6 = new RPCSession<LaterCommands>(link.client, commands);
	}
}

private class LaterCommands extends RPCCommands {
	public function new() {}

	@:rpc public function cached(value:Int):RPCResponse<Int> {}

	@:rpc public function lookup(name:String):RPCResponse<String> {}

	@:rpc public function fire(value:Int):Void {}
}

private class LaterHandler extends RPCHandler {
	public final waiting = new Map<String, Completer<String>>();
	public final afterCalls:Array<String> = [];
	public var fired:Completer<Int>;

	public function new() {}

	@:rpc public function cached(value:Int):Future<Int> {
		return Future.resolved(value * 2);
	}

	@:rpc public function lookup(name:String):Future<String> {
		if (name == "") {
			throw new RPCError("A name is needed.");
		}
		var completer = new Completer<String>();
		waiting.set(name, completer);
		return completer.future;
	}

	@:rpc public function fire(value:Int):Future<Int> {
		fired = new Completer<Int>();
		return fired.future;
	}

	override public function afterCall(method:String, requestId:Int, error:Dynamic):Void {
		afterCalls.push(method + " " + (error == null ? "ok" : Std.string(error.message != null ? error.message : error)));
	}
}

private class InstanceCommands extends RPCCommands {
	public function new() {}

	@:rpc public function allocate(region:String):RPCResponse<Int> {}
}

private class InstanceHandler extends RPCHandler {
	public function new() {}

	@:rpc public function allocate(region:String):Int {
		if (region == "full") {
			throw new RPCError("No instance has room.");
		}
		return 7;
	}
}

private class HubCommands extends RPCCommands {
	public function new() {}

	@:rpc public function join(region:String):RPCResponse<Int> {}
}

private class HubHandler extends RPCHandler {
	final host:InstanceCommands;

	public function new(host:InstanceCommands) {
		this.host = host;
	}

	@:rpc public function join(region:String):Future<Int> {
		return host.allocate(region);
	}
}

private interface LaterContract {
	function find(id:Int):Future<String>;
}

@:rpcContract(LaterContract)
private class LaterContractCommands extends RPCCommands {
	public function new() {}
}

private class LaterContractHandler extends RPCHandler implements LaterContract {
	public var finding:Completer<String>;

	public function new() {}

	public function find(id:Int):Future<String> {
		finding = new Completer<String>();
		return finding.future;
	}
}

#if (cpp || jvm || hl || neko || eval)
private class ThreadNotingConnection extends LinkedConnection {
	static final onTestThread = new sys.thread.Tls<Null<Bool>>();

	public var sentFromOtherThreads:Int = 0;

	public static function markThisThread():Void {
		onTestThread.value = true;
	}

	public function new() {
		super();
	}

	override public function send(data:ByteArray):Void {
		if (onTestThread.value != true) {
			sentFromOtherThreads++;
		}
		super.send(data);
	}
}
#end
