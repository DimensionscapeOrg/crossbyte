package crossbyte.cluster;

import crossbyte.core.CrossByte;
import crossbyte.errors.IOError;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import utest.Assert;

/**
	A link between two nodes.

	Needs real sockets, so this runs where `Socket` does rather than
	everywhere. The framing underneath it is `FrameCodec`, which is tested on
	its own and on every target; what is left to show here is that two ends
	wired to real sockets exchange whole messages, and that a link with
	nowhere to send holds a bounded amount.
**/
class NodeChannelTest extends utest.Test {
	/**
		Whole messages cross, in both directions, however TCP splits them.

		The large payload is the point: it will not arrive in one read, so a
		link that handed bytes up as they came would deliver it in pieces.
	**/
	public function testWholeMessagesCrossInBothDirections():Void {
		var server = new ServerSocket();
		var accepted:NodeChannel = null;
		var atServer:Array<Int> = [];

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(event):Void {
			accepted = NodeChannel.adopt(cast event.socket);
			accepted.onMessage = function(payload:ByteArray):Void {
				atServer.push(payload.length);
				// Straight back, so one exchange shows both directions.
				accepted.send(payload);
			};
		});

		server.bind(0, "127.0.0.1");
		server.listen();

		var link = NodeChannel.dial("127.0.0.1", server.localPort);
		var atClient:Array<Int> = [];
		link.onMessage = payload -> atClient.push(payload.length);

		pumpUntil(() -> link.up, 5.0);
		Assert.isTrue(link.up, "the link never came up");

		// One small, one far larger than a single read.
		link.send(filled(24));
		link.send(filled(200000));

		pumpUntil(() -> atClient.length >= 2, 10.0);

		Assert.equals("24,200000", atServer.join(","), "the server saw " + atServer.join(","));
		Assert.equals("24,200000", atClient.join(","), "the client saw back " + atClient.join(","));

		link.close();

		if (accepted != null) {
			accepted.close();
		}

		closeQuietly(server);
	}

	/**
		What is held for a peer that is not there is bounded.

		An outage has no length, so a link that queued everything until the
		far end returned would hold the whole of it. Nothing is listening on
		this port, so the link is down and everything written waits.
	**/
	public function testWhatIsHeldForAnAbsentPeerIsBounded():Void {
		// A port nothing is on: bound one, read it, and let it go.
		var vacant = new ServerSocket();
		vacant.bind(0, "127.0.0.1");
		vacant.listen();
		var deadPort:Int = vacant.localPort;
		closeQuietly(vacant);

		var link = NodeChannel.dial("127.0.0.1", deadPort);
		link.maxQueuedBytes = 64 * 1024;
		link.overflowPolicy = THROW;

		var refused:Bool = false;

		try {
			for (_ in 0...400) {
				link.send(filled(1024));
			}
		} catch (e:IOError) {
			refused = true;
		}

		Assert.isTrue(refused, "the link queued past " + link.maxQueuedBytes + " bytes without a word");
		Assert.isTrue(link.bufferedAmount <= link.maxQueuedBytes + 1024,
			"the link held " + link.bufferedAmount + " against a bound of " + link.maxQueuedBytes);
		Assert.isFalse(link.up, "a link to a port nothing is on reported itself up");

		link.close();
	}

	/** A closed link refuses to take more rather than holding it. **/
	public function testAClosedLinkTakesNothingMore():Void {
		var vacant = new ServerSocket();
		vacant.bind(0, "127.0.0.1");
		vacant.listen();
		var port:Int = vacant.localPort;
		closeQuietly(vacant);

		var link = NodeChannel.dial("127.0.0.1", port);
		link.close();

		Assert.raises(function():Void {
			link.send(filled(8));
		}, IOError);
	}

	// ------------------------------------------------------------------

	static function filled(size:Int):ByteArray {
		var bytes = new ByteArray();

		for (i in 0...size) {
			bytes.writeByte(i & 0xFF);
		}

		bytes.position = 0;
		return bytes;
	}

	static function pumpUntil(done:Void->Bool, timeout:Float):Void {
		var runtime = CrossByte.current();
		var deadline = Sys.time() + timeout;

		while (!done() && Sys.time() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.001);
		}
	}

	static function closeQuietly(server:ServerSocket):Void {
		try {
			server.close();
		} catch (_:Dynamic) {}
	}
}
