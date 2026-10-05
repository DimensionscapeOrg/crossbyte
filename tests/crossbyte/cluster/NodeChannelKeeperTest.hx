package crossbyte.cluster;

import crossbyte.core.CrossByte;
import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net.ServerSocket;
import utest.Assert;

/**
	What `NodeChannel.send` sends is the bytes it was handed when it was
	called, wherever the message waits before it goes.

	A message waits in two places: queued while the link is down, and held
	until the pass ends while it is up, to be taken back if the link fails
	first. Both held the caller's `ByteArray` and sent what its bytes were by
	then: a buffer the caller reused went as its later contents, and a
	listener forwarding what arrived, `channel.send(event.data)`, a payload
	valid only during the listener's call, forwarded nothing under
	`-D crossbyte_check_events`, and the next datagram once a socket reuses
	its payload.
**/
class NodeChannelKeeperTest extends utest.Test {
	/** Forwarded from a datagram listener while the link is down: what arrives at the far end later. **/
	public function testAForwardedDatagramIsWhatArrived():Void {
		// A port with nothing on it yet: the link is down when the datagram is forwarded.
		var probe = new ServerSocket();
		probe.bind(0, "127.0.0.1");
		var port:Int = probe.localPort;
		try probe.close() catch (_:Dynamic) {}

		var link = NodeChannel.dial("127.0.0.1", port);
		var udpIn = new DatagramSocket();
		var udpOut = new DatagramSocket();
		udpIn.bind(0, "127.0.0.1");
		udpIn.receive();
		udpOut.bind(0, "127.0.0.1");

		var forwarded:Int = 0;
		udpIn.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			// Forwarded as it arrived, from inside the listener: the commonest
			// thing a relay or a cluster front does.
			link.send(e.data);
			forwarded++;
		});

		var message = new ByteArray();
		message.writeUTFBytes("forwarded while the link was down");
		udpOut.send(message, 0, 0, "127.0.0.1", udpIn.localPort);
		pumpUntil(() -> forwarded >= 1, 5.0);
		Assert.equals(1, forwarded, "the datagram never arrived");

		// Another datagram, through the same socket, before the link is up.
		var other = new ByteArray();
		other.writeUTFBytes("the next datagram, which is not what was forwarded");
		udpOut.send(other, 0, 0, "127.0.0.1", udpIn.localPort);
		pumpUntil(() -> forwarded >= 2, 5.0);

		// The far end comes up, and the link carries what it queued.
		var server = new ServerSocket();
		var everyAccepted:Array<NodeChannel> = [];
		var received:Array<String> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event):Void {
			var accepted = NodeChannel.adopt(cast event.socket);
			everyAccepted.push(accepted);
			accepted.onMessage = payload -> received.push(payload.readUTFBytes(payload.length));
		});
		server.bind(port, "127.0.0.1");
		server.listen();

		pumpUntil(() -> {
			link.poll();
			return received.length >= 2;
		}, 10.0);

		Assert.equals(2, received.length, "the forwarded datagrams never arrived");
		Assert.equals("forwarded while the link was down", received[0], "a datagram forwarded while the link was down arrived as other bytes");
		Assert.equals("the next datagram, which is not what was forwarded", received[1]);

		link.close();
		for (channel in everyAccepted) {
			channel.close();
		}
		try server.close() catch (_:Dynamic) {}
		try udpIn.close() catch (_:Dynamic) {}
		try udpOut.close() catch (_:Dynamic) {}
	}

	/** Queued while the link is down: a buffer changed after `send` returns does not change what is sent. **/
	public function testABufferChangedAfterSendDoesNotChangeWhatIsSent():Void {
		var probe = new ServerSocket();
		probe.bind(0, "127.0.0.1");
		var port:Int = probe.localPort;
		try probe.close() catch (_:Dynamic) {}

		var link = NodeChannel.dial("127.0.0.1", port);
		var buffer = new ByteArray();
		buffer.writeUTFBytes("as sent");
		link.send(buffer);
		// The caller's to reuse once send has returned, as every other send's is.
		buffer.position = 0;
		buffer.writeUTFBytes("CHANGED");

		var server = new ServerSocket();
		var everyAccepted:Array<NodeChannel> = [];
		var received:Array<String> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event):Void {
			var accepted = NodeChannel.adopt(cast event.socket);
			everyAccepted.push(accepted);
			accepted.onMessage = payload -> received.push(payload.readUTFBytes(payload.length));
		});
		server.bind(port, "127.0.0.1");
		server.listen();

		pumpUntil(() -> {
			link.poll();
			return received.length >= 1;
		}, 10.0);

		Assert.same(["as sent"], received, "the bytes sent were changed after send returned");
		link.close();
		for (channel in everyAccepted) {
			channel.close();
		}
		try server.close() catch (_:Dynamic) {}
	}

	/**
		Written in a pass that the link fails before the end of: what the pass
		takes back and sends after the repair is what each `send` was handed,
		though the caller reused one buffer for all of them.
	**/
	public function testWhatAFailedPassTakesBackIsWhatWasSent():Void {
		var server = new ServerSocket();
		var everyAccepted:Array<NodeChannel> = [];
		var received:Array<String> = [];
		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event):Void {
			var accepted = NodeChannel.adopt(cast event.socket);
			everyAccepted.push(accepted);
			accepted.onMessage = payload -> received.push(payload.readUTFBytes(payload.length));
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var link = NodeChannel.dial("127.0.0.1", server.localPort);
		pumpUntil(() -> link.up && everyAccepted.length > 0, 5.0);
		Assert.isTrue(link.up, "the link never came up");

		var buffer = new ByteArray();
		buffer.writeUTFBytes("first");
		link.send(buffer);
		buffer.clear();
		buffer.writeUTFBytes("second, longer");
		link.send(buffer);
		buffer.clear();
		Assert.equals(2, @:privateAccess link.__inPassCount, "the pass's messages were not held for its end");

		// Reused once more, and then the link fails before the pass ends.
		buffer.writeUTFBytes("CHANGED");
		@:privateAccess link.__scheduleRetry("failed in the pass");
		Assert.equals(19, link.bufferedAmount, "what the pass wrote was not taken back whole");

		pumpUntil(() -> {
			link.poll();
			return received.length >= 2;
		}, 5.0);
		Assert.same(["first", "second, longer"], received, "a failed pass took back other bytes than were sent");

		link.close();
		for (channel in everyAccepted) {
			channel.close();
		}
		try server.close() catch (_:Dynamic) {}
	}

	static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = haxe.Timer.stamp() + timeout;
		while (!done() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			crossbyte.sys.System.sleep(0.001);
		}
	}
}
