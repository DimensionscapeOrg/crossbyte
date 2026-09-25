package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.net.INetConnection;
import crossbyte.net.Protocol;
import crossbyte.net.Reason;
import crossbyte.net.Transport;
import haxe.ds.IntMap;
import utest.Assert;

/**
 * Robustness coverage for RPC request-id generation and pending-response cleanup.
 *
 * These tests guard two regressions:
 *  - the request-id generator must never hand back the reserved single-slot id nor
 *    an id already tracked in the overflow map;
 *  - outstanding `RPCResponse` objects must be rejected (not orphaned) when the
 *    owning session/commands surface is torn down.
 */
@:access(crossbyte.rpc.RPCCommands)
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.RPCResponse)
@:access(crossbyte.core.CrossByte)
class RPCRobustnessTest extends utest.Test {
	// ---- request-id generation (RPCCommands) ----

	public function testNextRequestIdSkipsReservedSingleSlotId():Void {
		var commands = new RobustCommands();
		// Reserve the id that the seed is about to land on.
		commands.__requestIdSeed = 4;
		commands.__pendingResponseId = 5;

		var id = commands.__nextRequestId();

		Assert.notEquals(5, id);
		Assert.equals(6, id);
	}

	public function testNextRequestIdSkipsIdsAlreadyInPendingMap():Void {
		var commands = new RobustCommands();
		commands.__requestIdSeed = 9;
		commands.__pendingResponseId = 0;
		commands.__pendingResponses = new IntMap();
		commands.__pendingResponses.set(10, new RPCResponse<Dynamic>(10, 1));
		commands.__pendingResponses.set(11, new RPCResponse<Dynamic>(11, 1));

		var id = commands.__nextRequestId();

		Assert.isFalse(commands.__pendingResponses.exists(id));
		Assert.equals(12, id);
	}

	public function testNextRequestIdWrapsPastZeroOnOverflow():Void {
		var commands = new RobustCommands();
		// Force the seed to overflow into the negative range on the next increment.
		commands.__requestIdSeed = 0x7FFFFFFF;
		commands.__pendingResponseId = 0;

		var id = commands.__nextRequestId();

		Assert.isTrue(id > 0);
		Assert.equals(1, id);
	}

	public function testNextRequestIdNeverReturnsReservedAcrossManyDraws():Void {
		var commands = new RobustCommands();
		commands.__requestIdSeed = 0;
		commands.__pendingResponseId = 3;

		for (i in 0...10) {
			var id = commands.__nextRequestId();
			Assert.notEquals(3, id);
			Assert.isTrue(id > 0);
		}
	}

	// ---- pending-response cleanup (RPCCommands) ----

	public function testCommandsFailAllRejectsSingleSlotPending():Void {
		var commands = new RobustCommands();
		var response = new RPCResponse<Dynamic>(1, 1);
		commands.__pendingResponseId = 1;
		commands.__pendingResponse = response;

		commands.__failAllPending("gone");

		Assert.isTrue(response.completed);
		Assert.isFalse(response.succeeded);
		Assert.equals("gone", response.error);
		Assert.isNull(commands.__pendingResponse);
		Assert.equals(0, commands.__pendingResponseId);
	}

	public function testCommandsFailAllRejectsOverflowMapPending():Void {
		var commands = new RobustCommands();
		var slot = new RPCResponse<Dynamic>(1, 1);
		var extraA = new RPCResponse<Dynamic>(2, 1);
		var extraB = new RPCResponse<Dynamic>(3, 1);
		commands.__pendingResponseId = 1;
		commands.__pendingResponse = slot;
		commands.__pendingResponses = new IntMap();
		commands.__pendingResponses.set(2, extraA);
		commands.__pendingResponses.set(3, extraB);

		commands.__failAllPending("session stopped");

		Assert.isTrue(slot.completed);
		Assert.isTrue(extraA.completed);
		Assert.isTrue(extraB.completed);
		Assert.isFalse(extraA.succeeded);
		Assert.isFalse(extraB.succeeded);
		Assert.equals("session stopped", extraA.error);
		Assert.isNull(commands.__pendingResponses);
	}

	public function testCommandsFailAllWithNothingPendingIsNoOp():Void {
		var commands = new RobustCommands();

		// Should not throw with no pending responses.
		commands.__failAllPending("nothing");

		Assert.isNull(commands.__pendingResponse);
		Assert.isNull(commands.__pendingResponses);
	}

	// ---- runtime request-id generation (RPCSession) ----

	public function testRuntimeNextRequestIdSkipsReservedSingleSlotId():Void {
		var session = new RPCSession(new StubConnection());
		session.__runtimeRequestIdSeed = 7;
		session.__runtimePendingResponseId = 8;

		var id = session.__nextRuntimeRequestId();

		Assert.notEquals(8, id);
		Assert.equals(9, id);
	}

	public function testRuntimeNextRequestIdSkipsIdsAlreadyInPendingMap():Void {
		var session = new RPCSession(new StubConnection());
		session.__runtimeRequestIdSeed = 20;
		session.__runtimePendingResponseId = 0;
		session.__runtimePendingResponses = new IntMap();
		session.__runtimePendingResponses.set(21, new RPCResponse<Dynamic>(21, 1));

		var id = session.__nextRuntimeRequestId();

		Assert.isFalse(session.__runtimePendingResponses.exists(id));
		Assert.equals(22, id);
	}

	// ---- pending-response cleanup (RPCSession) ----

	public function testSessionFailAllRejectsRuntimePending():Void {
		var session = new RPCSession(new StubConnection());
		var response = new RPCResponse<Dynamic>(1, 1);
		session.__runtimePendingResponseId = 1;
		session.__runtimePendingResponse = response;

		session.__failAllPending("connection closed");

		Assert.isTrue(response.completed);
		Assert.isFalse(response.succeeded);
		Assert.equals("connection closed", response.error);
		Assert.isNull(session.__runtimePendingResponse);
	}

	public function testSessionFailAllRejectsBothLanes():Void {
		var commands = new RobustCommands();
		var session = new RPCSession<RobustCommands>(new StubConnection(), commands);

		var compiled = new RPCResponse<Dynamic>(1, 1);
		commands.__pendingResponseId = 1;
		commands.__pendingResponse = compiled;

		var runtime = new RPCResponse<Dynamic>(2, 1);
		session.__runtimePendingResponseId = 2;
		session.__runtimePendingResponse = runtime;

		session.__failAllPending("teardown");

		Assert.isTrue(compiled.completed);
		Assert.isTrue(runtime.completed);
		Assert.isFalse(compiled.succeeded);
		Assert.isFalse(runtime.succeeded);
	}

	public function testStopRejectsPendingRuntimeResponse():Void {
		var session = new RPCSession(new StubConnection());
		var response = new RPCResponse<Dynamic>(1, 1);
		session.__runtimePendingResponseId = 1;
		session.__runtimePendingResponse = response;

		session.stop();

		Assert.isTrue(response.completed);
		Assert.isFalse(response.succeeded);
		Assert.notNull(response.error);
		Assert.isNull(session.__runtimePendingResponse);
	}

	// ---- heartbeat teardown ----

	public function testAHeartbeatThatWasTheFirstTimerStillStops():Void {
		// A fresh runtime hands out timer handle 0 first. The session took 0 to
		// mean "no heartbeat", so stop() left that one running, and it went on
		// pinging a connection that had closed.
		var runtime = new crossbyte.core.CrossByte(false, DEFAULT, true);
		var session = new RPCSession(LinkedConnection.pair().client, new RobustCommands());
		session.start();
		Assert.equals(0, session.__heartbeatTimerHandle);

		session.stop();

		Assert.isFalse(session.__hasHeartbeat);
		Assert.isFalse(crossbyte.Timer.clear(0));
		runtime.exit();
	}
}

@:access(crossbyte.rpc.RPCCommands)
private class RobustCommands extends RPCCommands {
	public function new() {}

	@:rpc public function getName(id:Int):RPCResponse<String> {}
}

/**
 * Minimal in-memory `INetConnection` used only to satisfy `RPCSession` construction.
 * No real traffic is exchanged; these tests poke session internals directly.
 */
private class StubConnection implements INetConnection {
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

	@:noCompletion private var __readEnabled:Bool = false;
	@:noCompletion private var __onData:ByteArrayInput->Void = input -> {};
	@:noCompletion private var __onClose:Reason->Void = reason -> {};
	@:noCompletion private var __onError:Reason->Void = reason -> {};
	@:noCompletion private var __onReady:Void->Void = () -> {};

	public function new() {}

	public function expose():Transport {
		return null;
	}

	public function send(data:ByteArray):Void {}

	public function close():Void {
		__readEnabled = false;
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
