package crossbyte.rpc;

import crossbyte.Completer;
import crossbyte.Future;
import utest.Assert;

/**
	`RPCCall.data`: state kept for one call, which stays with it when it
	answers later. Kept on the handler instead, as an application's own
	context was, it held the last call's by the time an earlier one answered.
**/
class RPCCallDataTest extends utest.Test {
	public function testACallsDataStaysWithItWhenItAnswersLater():Void {
		// Four players queue; the fourth's call completes all four futures,
		// inside its own dispatch, and each afterCall sees its own call.
		final link = LinkedConnection.pair();
		final commands = new QueueCommands();
		final handler = new QueueHandler();
		final client = new RPCSession<QueueCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, handler);
		Assert.notNull(client);
		final answers = [for (name in ["ann", "bob", "cy", "di"]) commands.queue(name)];
		for (answer in answers) {
			Assert.equals(1, answer.result, "a queued player was not answered");
		}
		Assert.same(["ann", "bob", "cy", "di"], handler.afterData, "afterCall saw another call's data");
		Assert.same([true, true, true, true], handler.afterSessions.map(s -> s == server), "afterCall saw another session");
		Assert.same(["ann", "bob", "cy", "di"], handler.methodData, "the method read another call's data");
	}

	public function testACallsDataStaysWithItAnsweredOnAnotherTick():Void {
		final link = LinkedConnection.pair();
		final commands = new QueueCommands();
		final handler = new QueueHandler();
		final client = new RPCSession<QueueCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, handler);
		Assert.notNull(client);
		Assert.notNull(server);
		final first = commands.hold("first");
		final second = commands.hold("second");
		// Completed from outside any call, the last first.
		handler.held.pop().complete(2);
		handler.held.pop().complete(1);
		Assert.equals(1, first.result);
		Assert.equals(2, second.result);
		Assert.same(["second", "first"], handler.afterData);
		Assert.isNull(handler.between, "currentCall was a call between calls");
	}

	public function testARuntimeCallsDataStaysWithIt():Void {
		final link = LinkedConnection.pair();
		final client = new RPCSession(link.client);
		final server = new RPCSession(link.server);
		final waiting:Array<Completer<Dynamic>> = [];
		server.registerArgs(910, args -> {
			server.currentCall.data = args.string(0);
			final completer = new Completer<Dynamic>();
			waiting.push(completer);
			return completer.future;
		});
		final seen:Array<String> = [];
		server.afterRuntimeCall = (op, requestId, error) -> seen.push(server.currentCall.data);
		final a:RPCResponse<Dynamic> = client.request(910, ["a"]);
		final b:RPCResponse<Dynamic> = client.request(910, ["b"]);
		waiting[1].complete(2);
		waiting[0].complete(1);
		Assert.equals(1, a.result);
		Assert.equals(2, b.result);
		Assert.same(["b", "a"], seen);
	}

	public function testACallThatNeverReadItsCallSeesNoneLater():Void {
		// Untracked, as a call answered later costs nothing more when its
		// handler never reads currentCall: its afterCall reads none, not the
		// call the session is on.
		final link = LinkedConnection.pair();
		final commands = new QueueCommands();
		final handler = new QueueHandler();
		final client = new RPCSession<QueueCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, handler);
		Assert.notNull(client);
		Assert.notNull(server);
		final untracked = commands.plain();
		final queued = commands.queue("ann");
		Assert.isFalse(queued.completed);
		handler.plainWaiting.complete(3);
		Assert.equals(3, untracked.result);
		Assert.same(["(none)"], handler.afterData, "an untracked call's afterCall saw a call");
	}
}

private class QueueCommands extends RPCCommands {
	public function new() {}

	@:rpc public function queue(player:String):RPCResponse<Int> {}

	@:rpc public function hold(name:String):RPCResponse<Int> {}

	@:rpc public function plain():RPCResponse<Int> {}
}

private class QueueHandler extends RPCHandler {
	public final afterData:Array<String> = [];
	public final afterSessions:Array<RPCSession<Dynamic, Dynamic>> = [];
	public final methodData:Array<String> = [];
	public final held:Array<Completer<Int>> = [];
	public var between:Null<RPCCall> = null;
	public var plainWaiting:Null<Completer<Int>> = null;

	var queued:Array<Completer<Int>> = [];

	public function new() {}

	override public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		return null;
	}

	override public function afterCall(method:String, requestId:Int, error:Null<haxe.Exception>):Void {
		final call:Null<RPCCall> = currentCall;
		afterData.push(call != null && call.data != null ? (call.data : String) : "(none)");
		afterSessions.push(session);
	}

	@:rpc public function queue(player:String):Future<Int> {
		currentCall.data = player;
		final place = new Completer<Int>();
		queued.push(place);
		methodData.push(currentCall.data);
		if (queued.length == 4) {
			final all = queued;
			queued = [];
			for (waiting in all) {
				waiting.complete(1);
			}
		}
		return place.future;
	}

	@:rpc public function hold(name:String):Future<Int> {
		currentCall.data = name;
		final completer = new Completer<Int>();
		held.push(completer);
		return completer.future;
	}

	@:rpc public function plain():Future<Int> {
		plainWaiting = new Completer<Int>();
		return plainWaiting.future;
	}
}
