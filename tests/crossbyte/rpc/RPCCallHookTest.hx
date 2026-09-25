package crossbyte.rpc;

import utest.Assert;

/**
	`RPCHandler.beforeCall` and `afterCall`: one place to decide on every
	call, and to see how each went.
**/
class RPCCallHookTest extends utest.Test {
	public function testBeforeCallSeesEachCallBeforeItRuns():Void {
		var link = LinkedConnection.pair();
		var commands = new HookCommands();
		var handler = new WatchedHandler();
		var clientSession = new RPCSession<HookCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		// An Int and two Floats: twenty bytes of arguments. One way, so no
		// request id; the request that follows has one.
		commands.move(7, 1.5, -2.5);
		var answer = commands.lookup(4);

		Assert.equals(2, handler.before.length);
		Assert.equals("move 0 20", handler.before[0]);
		Assert.equals('lookup ${answer.requestId} 4', handler.before[1]);
		Assert.same(["moved 7"], handler.ran.slice(0, 1));
		Assert.equals("item-4", answer.result);
	}

	public function testARefusedRequestIsAnsweredWithTheRefusal():Void {
		var link = LinkedConnection.pair();
		var commands = new HookCommands();
		var handler = new WatchedHandler();
		var clientSession = new RPCSession<HookCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var reported = reportsOf(serverSession);
		var ended = endingOf(link.server);

		handler.refuse = "lookup";
		var refused = commands.lookup(4);

		Assert.isFalse(refused.succeeded);
		Assert.equals("lookup is not allowed", refused.error);
		Assert.same([], handler.ran, "a refused call ran");
		Assert.same([], handler.after, "afterCall was told of a call that never ran");
		// It made the decision, so there is nothing to report.
		Assert.same([], reported);
		Assert.isFalse(ended.value);

		handler.refuse = null;
		Assert.equals("item-5", commands.lookup(5).result);
	}

	public function testARefusedOneWayCallIsDroppedQuietly():Void {
		var link = LinkedConnection.pair();
		var commands = new HookCommands();
		var handler = new WatchedHandler();
		var clientSession = new RPCSession<HookCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var reported = reportsOf(serverSession);
		var ended = endingOf(link.server);

		handler.refuse = "move";
		commands.move(1, 0, 0);
		handler.refuse = null;
		commands.move(2, 0, 0);

		Assert.same(["moved 2"], handler.ran);
		Assert.same([], reported);
		Assert.isFalse(ended.value);
	}

	public function testAfterCallSeesHowEachCallWentOnceItIsAnswered():Void {
		var link = LinkedConnection.pair();
		var commands = new HookCommands();
		var handler = new WatchedHandler();
		var clientSession = new RPCSession<HookCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		reportsOf(serverSession);

		// Whether the caller had its answer at the moment afterCall ran.
		var answeredFirst:Array<Bool> = [];
		handler.probe = () -> answeredFirst.push(@:privateAccess commands.__pendingResponse == null);

		var answered = commands.lookup(1);
		var failed = commands.lookup(0);

		Assert.same(["lookup ok", "lookup failed: no item 0"], handler.after);
		Assert.same([true, true], answeredFirst, "afterCall ran before the answer was sent");
		Assert.equals("item-1", answered.result);
		Assert.equals(RPCError.INTERNAL_MESSAGE, failed.error);
	}

	public function testAHookThatThrowsCountsAsTheCallFailing():Void {
		var link = LinkedConnection.pair();
		var commands = new HookCommands();
		var handler = new WatchedHandler();
		var clientSession = new RPCSession<HookCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var reported = reportsOf(serverSession);
		var ended = endingOf(link.server);

		handler.throwBefore = true;
		var failed = commands.lookup(3);
		Assert.equals(RPCError.INTERNAL_MESSAGE, failed.error);
		Assert.same([], handler.ran);
		Assert.same(["lookup: beforeCall broke"], reported);

		// After a call, throwing changes nothing but the report.
		handler.throwBefore = false;
		handler.throwAfter = true;
		var answered = commands.lookup(3);
		Assert.equals("item-3", answered.result);
		Assert.same(["lookup: beforeCall broke", "lookup: afterCall broke"], reported);
		Assert.isFalse(ended.value);
	}

	public function testHooksInABaseHandlerApplyToEveryHandlerBuiltOnIt():Void {
		var link = LinkedConnection.pair();
		var commands = new HookCommands();
		var handler = new GatedHandler();
		var clientSession = new RPCSession<HookCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		Assert.equals("sign in first", commands.lookup(1).error);
		handler.signedIn = true;
		Assert.equals("item-1", commands.lookup(1).result);
		Assert.same(["lookup"], handler.finished);
	}

	public function testHooksAlsoRunOnASessionThatHasRuntimeHandlers():Void {
		// Such a session reads frames on its own lane rather than the
		// handler's; the handler's calls go through the same generated code.
		var link = LinkedConnection.pair();
		var commands = new HookCommands();
		var handler = new WatchedHandler();
		var clientSession = new RPCSession<HookCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		serverSession.register(700, args -> null);

		handler.refuse = "lookup";
		Assert.equals("lookup is not allowed", commands.lookup(2).error);
	}

	static function reportsOf(session:RPCSession<Dynamic, Dynamic>):Array<String> {
		var reported:Array<String> = [];
		session.onHandlerError = (op, method, error) -> reported.push(method + ": " + Std.string(error));
		return reported;
	}

	static function endingOf(connection:LinkedConnection):{value:Bool} {
		var ended = {value: false};
		connection.onClose = _ -> ended.value = true;
		connection.onError = _ -> ended.value = true;
		return ended;
	}
}

private class HookCommands extends RPCCommands {
	public function new() {}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {}

	@:rpc public function lookup(id:Int):RPCResponse<String> {}
}

private class WatchedHandler extends RPCHandler {
	public var before:Array<String> = [];
	public var after:Array<String> = [];
	public var ran:Array<String> = [];
	public var refuse:Null<String> = null;
	public var throwBefore:Bool = false;
	public var throwAfter:Bool = false;
	public var probe:Null<Void->Void> = null;

	public function new() {}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		if (throwBefore) {
			throw "beforeCall broke";
		}
		before.push('$method $requestId $payloadSize');
		return method == refuse ? new RPCError('$method is not allowed') : null;
	}

	override public function afterCall(method:String, requestId:Int, error:Dynamic):Void {
		if (throwAfter) {
			throw "afterCall broke";
		}
		if (probe != null) {
			probe();
		}
		after.push(method + (error == null ? " ok" : " failed: " + Std.string(error)));
	}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {
		ran.push('moved $id');
	}

	@:rpc public function lookup(id:Int):String {
		if (id == 0) {
			throw "no item 0";
		}
		ran.push('looked up $id');
		return 'item-$id';
	}
}

/** Refuses everything until signed in, for whatever handler is built on it. **/
private class GateHandler extends RPCHandler {
	public var signedIn:Bool = false;
	public var finished:Array<String> = [];

	public function new() {}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		return signedIn ? null : new RPCError("sign in first");
	}

	override public function afterCall(method:String, requestId:Int, error:Dynamic):Void {
		finished.push(method);
	}
}

private class GatedHandler extends GateHandler {
	public function new() {
		super();
	}

	@:rpc public function move(id:Int, x:Float, y:Float):Void {}

	@:rpc public function lookup(id:Int):String {
		return 'item-$id';
	}
}
