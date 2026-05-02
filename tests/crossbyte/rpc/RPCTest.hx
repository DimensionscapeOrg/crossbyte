package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;
import crossbyte.utils.Hash;
import haxe.io.Bytes;
import utest.Assert;

class RPCTest extends utest.Test {
	public function testOneWayCallDecodesScalarsBytesAndOptionals():Void {
		var link = LinkedConnection.pair();
		var commands = new TestCommands();
		var handler = new TestHandler();

		new RPCSession<TestCommands>(link.client, commands);
		new RPCSession(link.server, null, handler);

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

		new RPCSession<TestCommands>(link.client, commands);
		new RPCSession(link.server, null, serverHandler);

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

		new RPCSession<TestCommands>(link.client, commands);
		new RPCSession(link.server, null, serverHandler);

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

		new RPCSession<TestCommands>(link.client, commands);
		new RPCSession(link.server, null, serverHandler);

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
		new RPCSession(link.server, null, handler);
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

		new RPCSession<ContractCommands>(link.client, commands);
		new RPCSession(link.server, null, handler);

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

		new RPCSession<ContractCommands>(link.client, commands);
		new RPCSession(link.server, null, handler);

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

		Assert.notNull(captured);
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
}

private class TestCommands extends RPCCommands {
	public function new() {}

	@:rpc public function sendData(id:Int, enabled:Bool, ratio:Float, name:String, bytes:Bytes, ?tag:String):Void {}

	@:rpc public function getName(id:Int):RPCResponse<String> {}
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
