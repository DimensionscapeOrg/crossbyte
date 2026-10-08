package crossbyte.rpc;

import crossbyte.io.ByteArray;
import crossbyte.io.ByteArrayInput;
import crossbyte.io.ByteArrayOutput;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.rpc._internal.RPCWire;
import utest.Assert;

/**
	The hello: one frame each session sends as its connection starts, with
	its protocol version, its capabilities (none in 1.0) and fingerprints
	of the methods it calls and answers. Sent and never waited for, and
	shaped as a pong is, a response under request id 0, which a session
	from before 1.0 passes over. From then on a feature beyond 1.0 goes only
	to a peer whose hello declared it.
**/
@:access(crossbyte.rpc.RPCSession)
class RPCHelloTest extends utest.Test {
	public function testEachSideSaysHelloAsItsConnectionStarts():Void {
		// Held until both are made, as a socket holds what arrives before
		// anyone reads it.
		var link = LinkedConnection.pair();
		link.client.bufferInbound = true;
		link.server.bufferInbound = true;
		var server = new RPCSession(link.server, null, new HelloHandler());
		var client = new RPCSession<HelloCommands>(link.client, new HelloCommands());
		var heard = [];
		server.onHello = () -> heard.push("server heard " + server.peerVersion);
		client.onHello = () -> heard.push("client heard " + client.peerVersion);
		Assert.equals(0, client.peerVersion, "a version before any hello arrived");

		link.server.flushBufferedReads();
		link.client.flushBufferedReads();

		Assert.same(["server heard 1", "client heard 1"], heard);
		Assert.equals(RPCSession.PROTOCOL_VERSION, client.peerVersion);
		Assert.equals(0, client.peerCapabilities, "a capability declared in 1.0, which defines none");
	}

	public function testAConnectionThatBecomesReadyIsGreetedThen():Void {
		var link = LinkedConnection.pair();
		link.client.isConnected = false;
		link.server.isConnected = false;
		var server = new RPCSession(link.server, null, new HelloHandler());
		var client = new RPCSession<HelloCommands>(link.client, new HelloCommands());
		Assert.equals(0, link.client.sent + link.server.sent, "a hello was sent on a connection that was not up");

		link.server.becomeReady();
		link.client.becomeReady();

		Assert.equals(1, client.peerVersion);
		Assert.equals(1, server.peerVersion);
		// And a call made at once goes right behind it, waiting for nothing.
		Assert.equals(5, (cast client.commands : HelloCommands).add(2, 3).result);
	}

	public function testOneContractsFingerprintsAgreeAndAnotherVersionsDoNot():Void {
		var same = pairOf(new HelloCommands(), new HelloHandler());
		Assert.notEquals(0, same.client.callsFingerprint);
		Assert.equals(same.client.callsFingerprint, same.server.answersFingerprint, "one contract, two fingerprints");
		Assert.equals(same.client.callsFingerprint, same.client.peerAnswersFingerprint, "the hello did not carry what the server answers");
		Assert.equals(same.server.answersFingerprint, same.server.peerCallsFingerprint, "the hello did not carry what the client calls");
		Assert.equals(0, same.client.answersFingerprint, "commands alone answer nothing");
		Assert.equals(0, same.server.peerAnswersFingerprint);

		// A client built from another version: `add` answers a Float there.
		var other = pairOf(new OtherVersionCommands(), new HelloHandler());
		Assert.notEquals(other.client.callsFingerprint, other.client.peerAnswersFingerprint, "two versions of a method, one fingerprint");
		// Told, never refused: what both have still works.
		other.client.commands.say("still");
		Assert.same(["still"], (cast other.server.handler : HelloHandler).said);
	}

	public function testAHelloIsShapedAsAPongIs():Void {
		// A response under request id 0, which answers no call: a session from
		// before 1.0 passes over it. And a call waiting here under id 1 is not
		// answered by one.
		var link = LinkedConnection.pair();
		var frames = framesArrivingAt(link.client);
		var server = new RPCSession(link.server, null, new HelloHandler());

		Assert.equals(1, frames.length, "no hello, or more than one");
		if (frames.length == 1) {
			var hello = frames[0];
			hello.readInt();
			Assert.equals(RPCWire.FLAG_RESPONSE, hello.readByte(), "not a response");
			Assert.equals(RPCWire.HELLO_OP, hello.readInt());
			Assert.equals(0, hello.readVarUInt(), "answers a call");
			Assert.equals(1, hello.readVarUInt(), "not version 1");
			Assert.equals(0, hello.readVarUInt(), "declares a capability");
			Assert.equals(0, hello.readInt(), "a server calls nothing");
			Assert.equals(server.answersFingerprint, hello.readInt());
		}
		Assert.equals(RPCOps.opOf("rpc:hello"), RPCWire.HELLO_OP);

		var waiting = new RPCSession<HelloCommands>(LinkedConnection.pair().client, new HelloCommands());
		var call = (cast waiting.commands : HelloCommands).add(1, 1);
		Assert.equals(1, call.requestId);
		waiting.connection.onData(helloFrame(2, 0, []));
		Assert.isFalse(call.completed, "a hello answered a call");
	}

	public function testALaterVersionsHelloIsReadForWhatThisOneKnows():Void {
		// A later version appends to its hello; this one reads what it knows,
		// passes over the rest, and reads the next frame where it begins.
		var link = LinkedConnection.pair();
		var server = new RPCSession(link.server, null, new HelloHandler());
		var passed = [];
		server.onUnreadableFrame = (op, requestId, reason) -> passed.push(reason);
		var answers = [];
		link.client.readEnabled = true;
		link.client.onData = input -> answers.push(input.bytesAvailable);

		var later = helloFrame(2, 5, [9, 9, 9, 9, 9]);
		var ping = new ByteArray();
		ping.writeInt(RPCWire.MIN_PAYLOAD_LEN);
		ping.writeByte(0);
		ping.writeInt(RPCWire.PING_OP);
		later.position = later.length;
		later.writeBytes(ping, 0, ping.length);
		later.position = 0;
		link.client.send(later);

		Assert.equals(2, server.peerVersion);
		Assert.equals(5, server.peerCapabilities);
		Assert.same([], passed, "a later hello was taken for a frame that could not be read");
		Assert.equals(1, answers.length, "the ping after a later hello was not answered");
	}

	public function testThePeersHelloIsForgottenAsItsConnectionEnds():Void {
		var link = LinkedConnection.pair();
		var server = new RPCSession(link.server, null, new HelloHandler());
		var client = new RPCSession<HelloCommands>(link.client, new HelloCommands());
		Assert.equals(1, server.peerVersion);

		link.server.peerLeft();
		Assert.equals(0, server.peerVersion, "a peer that has gone still said hello");
		Assert.equals(0, server.peerCallsFingerprint);

		// The next peer of a connection that takes one after another says its
		// own, as its connection to the listener becomes ready.
		var next = new LinkedConnection();
		next.isConnected = false;
		var nextClient = new RPCSession<HelloCommands>(next, new HelloCommands());
		link.server.takePeer(next);
		Assert.equals(0, server.peerVersion, "a hello arrived from a peer made before it was taken");
		next.becomeReady();
		Assert.equals(1, server.peerVersion, "the next peer was not heard to say hello");
	}

	// ------------------------------------------------------------------

	private static function pairOf<C:RPCCommands>(commands:C, handler:RPCHandler):{client:RPCSession<C, Dynamic>, server:RPCSession<Dynamic, Dynamic>} {
		var link = LinkedConnection.pair();
		link.client.bufferInbound = true;
		link.server.bufferInbound = true;
		var server:RPCSession<Dynamic, Dynamic> = new RPCSession(link.server, null, handler);
		var client = new RPCSession<C, Dynamic>(link.client, commands);
		link.client.bufferInbound = false;
		link.server.bufferInbound = false;
		link.server.flushBufferedReads();
		link.client.flushBufferedReads();
		return {client: client, server: server};
	}

	/** A hello as a peer of `version` would send it, `extra` bytes appended. **/
	private static function helloFrame(version:Int, capabilities:Int, extra:Array<Int>):ByteArray {
		var payload = new ByteArrayOutput(64);
		payload.writeByte(RPCWire.FLAG_RESPONSE);
		payload.writeInt(RPCWire.HELLO_OP);
		payload.writeVarUInt(0);
		payload.writeVarUInt(version);
		payload.writeVarUInt(capabilities);
		payload.writeInt(0x1234);
		payload.writeInt(0x5678);
		for (byte in extra) {
			payload.writeByte(byte);
		}
		var frame = new ByteArray();
		frame.writeInt(payload.bytesWritten);
		frame.writeBytes(payload, 0, payload.bytesWritten);
		frame.position = 0;
		return frame;
	}

	/** Each frame `connection` is sent from now on, whole. **/
	private static function framesArrivingAt(connection:LinkedConnection):Array<ByteArrayInput> {
		var frames:Array<ByteArrayInput> = [];
		connection.readEnabled = true;
		connection.onData = input -> {
			var copy = new ByteArray();
			copy.writeBytes(cast input, input.position, input.bytesAvailable);
			copy.position = 0;
			frames.push(copy);
		};
		return frames;
	}
}

private class HelloCommands extends RPCCommands {
	public function new() {}

	@:rpc public function add(a:Int, b:Int):RPCResponse<Int> {}

	@:rpc public function say(text:String):Void {}
}

/** Another version of the client: `add` answered with a Float. **/
private class OtherVersionCommands extends RPCCommands {
	public function new() {}

	@:rpc public function add(a:Int, b:Int):RPCResponse<Float> {}

	@:rpc public function say(text:String):Void {}
}

private class HelloHandler extends RPCHandler {
	public final said:Array<String> = [];

	public function new() {}

	@:rpc public function add(a:Int, b:Int):Int {
		return a + b;
	}

	@:rpc public function say(text:String):Void {
		said.push(text);
	}
}
