package crossbyte.rpc;

import crossbyte.core.CrossByte;
import crossbyte.errors.ArgumentError;
import crossbyte.io.ByteArray;
import crossbyte.net.INetConnection;
import crossbyte.net.NetConnection;
import crossbyte.net.NetHost;
import crossbyte.rpc.RPCFailure;
import haxe.io.Bytes;
import utest.Assert;

/**
	A call larger than its other side can take fails at once, typed, and the
	connection carries on, over every transport: nothing waits for good.

	Over TCP a call larger than the receiving socket's `maxInputBufferSize`
	waited for good: the socket stopped reading, and the session waited for
	the whole frame. Over a WebSocket one larger than its peer's 1 MiB
	`maxMessageSize` closed the connection; over reliable UDP one larger
	than the session's 256 KB `maxOutputBufferSize` ended the session; over
	local IPC one larger than its 8 MiB message went nowhere, and its caller
	waited. And a frame past the reader's `maxFrameLength` ended the
	connection.

	Not in the portable suite: these pump real sockets until something has
	happened, and on Node nothing happens until the pump returns.
**/
class RPCOversizeTest extends utest.Test {
	public function setup():Void {
		CrossByte.current().pump(0, 0);
	}

	public function testACallPastTheReadersFrameLimitIsRefusedAndTheConnectionGoesOn():Void {
		final link = LinkedConnection.pair();
		final commands = new SizeCommands();
		final handler = new SizeHandler();
		final client = new RPCSession<SizeCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, handler);
		final passed:Array<String> = [];
		server.onUnreadableFrame = (op, id, why) -> passed.push(why);
		server.maxFrameLength = 1000;
		final told = new SizeReceiver();
		final big = commands.echo(Bytes.alloc(5000));
		commands.echoThen(Bytes.alloc(5000), told);
		commands.drop(Bytes.alloc(5000));
		Assert.isTrue(Type.enumEq(TooLarge, big.failure), "a call past the reader's limit failed as " + big.failure);
		Assert.stringContains("1000-byte maxFrameLength", big.error);
		Assert.isTrue(Type.enumEq(TooLarge, told.failures[0]));
		Assert.equals(0, handler.dropped, "a one-way call past the limit ran");
		Assert.equals(3, passed.length, "onUnreadableFrame was not told of each");
		Assert.isTrue(link.client.open && link.server.open, "the connection ended");
		Assert.equals(7, commands.size(7).result, "the session did not answer after it");
	}

	public function testAnAnswerPastTheCallersFrameLimitFailsItsCall():Void {
		final link = LinkedConnection.pair();
		final commands = new SizeCommands();
		final client = new RPCSession<SizeCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, new SizeHandler());
		client.maxFrameLength = 1000;
		final big = commands.make(5000);
		Assert.isTrue(Type.enumEq(TooLarge, big.failure), "an answer past the caller's limit failed as " + big.failure);
		Assert.equals(7, commands.size(7).result, "the session did not answer after it");
	}

	public function testARefusedFrameIsPassedOverAcrossReads():Void {
		// The refused frame, then one that is not, read a few bytes at a time,
		// as a stream: the refused one read past, the next read whole.
		final link = PacedConnection.pair();
		final commands = new SizeCommands();
		final handler = new SizeHandler();
		final client = new RPCSession<SizeCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, handler);
		link.client.deliver();
		link.server.deliver();
		server.maxFrameLength = 1000;
		final big = commands.echo(Bytes.alloc(3000));
		commands.drop(Bytes.alloc(10));
		final bytes = new ByteArray();
		for (sent in link.client.held) {
			bytes.writeBytes(sent, 0, sent.length);
		}
		link.client.held.resize(0);
		var at:Int = 0;
		while (at < bytes.length) {
			final count:Int = bytes.length - at > 7 ? 7 : bytes.length - at;
			final piece = new ByteArray();
			piece.writeBytes(bytes, at, count);
			piece.position = 0;
			@:privateAccess link.server.receive(piece);
			at += count;
		}
		link.server.deliver();
		Assert.isTrue(Type.enumEq(TooLarge, big.failure), "a call past the limit failed as " + big.failure);
		Assert.equals(1, handler.dropped, "the call after the refused one was not read");
		final small = commands.size(7);
		link.client.deliver();
		link.server.deliver();
		Assert.equals(7, small.result);
	}

	public function testACallPastWhatATcpSocketHoldsIsRefusedNotWaitedFor():Void {
		final pair = Pair.over("tcp", connection -> NetConnection.toSocket(connection).maxInputBufferSize = 64 * 1024);
		final told = new SizeReceiver();
		final big = pair.commands.echo(Bytes.alloc(200 * 1024));
		pair.commands.echoThen(Bytes.alloc(200 * 1024), told);
		pair.pumpUntil(() -> big.completed && told.failures.length > 0, 5.0);
		Assert.isTrue(Type.enumEq(TooLarge, big.failure), "a call past the socket's input limit failed as " + big.failure);
		Assert.stringContains("maxInputBufferSize", big.error);
		Assert.isTrue(told.failures.length == 1 && Type.enumEq(TooLarge, told.failures[0]));
		pair.stillAnswers();
		pair.close();
	}

	public function testACallPastAWebSocketsMessageSizeIsAnswered():Void {
		#if (cpp || jvm || java)
		final pair = Pair.over("ws", null);
		final size:Int = 3 * 1024 * 1024;
		final big = pair.commands.echo(Bytes.alloc(size));
		pair.pumpUntil(() -> big.completed, 10.0);
		Assert.isTrue(big.succeeded && big.result.length == size, "a 3 MB call over a WebSocket failed as " + big.failure);
		pair.stillAnswers();
		pair.close();
		#else
		Assert.pass();
		#end
	}

	public function testACallPastAReliableUdpSessionsQueueFailsAsItIsMade():Void {
		if (!crossbyte.net.DatagramSocket.isSupported) {
			Assert.pass();
			return;
		}
		final pair = Pair.over("rudp", null);
		final big = pair.commands.echo(Bytes.alloc(400 * 1024));
		Assert.isTrue(big.completed, "a call past the session's output limit was sent");
		switch (big.failure) {
			case Unsent(why):
				Assert.stringContains("carries in one send", why);
			case other:
				Assert.fail("a call past the session's output limit failed as " + other);
		}
		Assert.raises(() -> pair.commands.drop(Bytes.alloc(400 * 1024)), ArgumentError);
		pair.stillAnswers();
		pair.close();
	}

	public function testACallAndAnAnswerPastALocalMessageFailNotWaitedFor():Void {
		#if (cpp && (windows || linux || mac || macos))
		final name = '__crossbyte_rpc_oversize_${Std.int(haxe.Timer.stamp() * 1000)}_${Std.random(1000000)}';
		final listener = new crossbyte.ipc.LocalConnection();
		listener.listen(name);
		final server = new RPCSession(NetConnection.fromLocalConnection(listener), null, new SizeHandler());
		server.maxFrameLength = 32 * 1024 * 1024;
		final commands = new SizeCommands();
		final client = RPCSession.dial('local://$name', commands);
		client.maxFrameLength = 32 * 1024 * 1024;
		Pair.pump(() -> client.up && client.peerVersion > 0, 5.0);
		try {
			final call = commands.echo(Bytes.alloc(9 * 1024 * 1024));
			Assert.isTrue(call.completed, "a call past local IPC's message was left waiting");
			Assert.isTrue(call.failure != null && call.failure.match(Unsent(_)), "it failed as " + call.failure);
			final answer = commands.make(9 * 1024 * 1024);
			Pair.pump(() -> answer.completed, 5.0);
			Assert.isTrue(Type.enumEq(TooLarge, answer.failure), "an answer past local IPC's message failed as " + answer.failure);
			final small = commands.size(3);
			Pair.pump(() -> small.completed, 5.0);
			Assert.equals(3, small.result, "the connection did not go on");
		} catch (e:Dynamic) {
			client.close();
			listener.close();
			throw e;
		}
		client.close();
		listener.close();
		#else
		Assert.pass();
		#end
	}

}

/** A client and a server over a real transport. **/
private class Pair {
	public final commands = new SizeCommands();
	public var client:RPCSession<SizeCommands> = null;
	public var host:NetHost = null;

	function new() {}

	public static function over(scheme:String, ?configure:INetConnection->Void):Pair {
		final pair = new Pair();
		final handler = new SizeHandler();
		var accepted:Int = 0;
		pair.host = new NetHost(scheme + "://127.0.0.1:0", (connection:INetConnection) -> {
			if (configure != null) {
				configure(connection);
			}
			final server = new RPCSession(connection, null, handler);
			accepted++;
		});
		pair.host.listen();
		pump(() -> pair.host.localPort != 0, 2.0);
		final connection = new NetConnection(scheme + "://127.0.0.1:" + pair.host.localPort + (scheme == "ws" ? "/" : ""));
		pair.client = new RPCSession<SizeCommands>(connection, pair.commands);
		pump(() -> pair.client.up && accepted > 0 && pair.client.peerVersion > 0, 5.0);
		return pair;
	}

	public function pumpUntil(done:Void->Bool, timeout:Float):Void {
		pump(done, timeout);
	}

	public static function pump(done:Void->Bool, timeout:Float):Void {
		final runtime = CrossByte.current();
		final deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}

	public function stillAnswers(?pos:haxe.PosInfos):Void {
		final small = commands.size(5);
		pumpUntil(() -> small.completed, 5.0);
		Assert.equals(5, small.result, "the connection did not go on after it", pos);
	}

	public function close():Void {
		try {
			client.close();
		} catch (_:Dynamic) {}
		try {
			host.close();
		} catch (_:Dynamic) {}
	}
}

private class SizeCommands extends RPCCommands {
	public function new() {}

	@:rpc public function echo(blob:Bytes):RPCResponse<Bytes> {}

	@:rpc public function make(size:Int):RPCResponse<Bytes> {}

	@:rpc public function drop(blob:Bytes):Void {}

	@:rpc public function size(value:Int):RPCResponse<Int> {}
}

private class SizeHandler extends RPCHandler {
	public var dropped:Int = 0;

	public function new() {}

	@:rpc public function echo(blob:Bytes):Bytes {
		return blob;
	}

	@:rpc public function make(size:Int):Bytes {
		return Bytes.alloc(size);
	}

	@:rpc public function drop(blob:Bytes):Void {
		dropped++;
	}

	@:rpc public function size(value:Int):Int {
		return value;
	}
}

private class SizeReceiver implements RPCValueReceiver<Bytes> {
	public final failures:Array<RPCFailure> = [];

	public function new() {}

	public function onValue(call:Int, value:Bytes):Void {}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		failures.push(failure);
	}
}
