package crossbyte.net;

import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import utest.Assert;
import utest.Async;

/**
	A `NetHost` made from a URI that names port 0 listens on a port the
	system chooses, as `ServerSocket.bind(0)` does, and `localPort` says
	which.

	The URI is not read the way a URI to dial is read, where port 0 names
	nothing and is refused: otherwise a host made from a URI could only be
	given a port someone had found free a moment before, which is assuming
	a port is free, and how a server and a test trip over whatever took it
	since.
**/
class NetHostUriTest extends utest.Test {
	private static inline var DEADLINE:Float = 10.0;

	@:timeout(20000)
	public function testATcpHostOnPortZeroListensWherePeersCanReachIt(async:Async):Void {
		__acceptOne("tcp://127.0.0.1:0", function(port:Int, failed:String->Void):Void->Void {
			var client = new Socket();
			client.addEventListener(IOErrorEvent.IO_ERROR, e -> failed(e.text));
			client.connect("127.0.0.1", port);
			return () -> client.close();
		}, async);
	}

	@:timeout(20000)
	public function testAWebSocketHostOnPortZeroListensWherePeersCanReachIt(async:Async):Void {
		__acceptOne("ws://127.0.0.1:0", function(port:Int, failed:String->Void):Void->Void {
			// The upgrade asked for by hand over a plain socket: a WebSocket
			// client draws its key from a secure random source, which the
			// interpreter, neko and hl have not got.
			var client = new Socket();
			client.addEventListener(IOErrorEvent.IO_ERROR, e -> failed(e.text));
			client.addEventListener(Event.CONNECT, function(_) {
				client.writeUTFBytes("GET / HTTP/1.1\r\nHost: 127.0.0.1:" + port + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
					+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
				client.flush();
			});
			client.connect("127.0.0.1", port);
			return () -> client.close();
		}, async);
	}

	@:timeout(20000)
	public function testAReliableDatagramHostOnPortZeroListensWherePeersCanReachIt(async:Async):Void {
		if (!ReliableDatagramSocket.isSupported) {
			Assert.isFalse(ReliableDatagramSocket.isSupported);
			async.done();
			return;
		}

		__acceptOne("rudp://127.0.0.1:0", function(port:Int, failed:String->Void):Void->Void {
			var client = new ReliableDatagramSocket();
			client.addEventListener(IOErrorEvent.IO_ERROR, e -> failed(e.text));
			client.connect("127.0.0.1", port);
			return () -> client.abort();
		}, async);
	}

	/** Dialling: port 0 is nowhere to connect to. **/
	public function testAUriToDialOnPortZeroIsStillRefused():Void {
		var refused:Bool = false;
		try {
			new NetConnection("tcp://127.0.0.1:0");
		} catch (_:String) {
			refused = true;
		}
		Assert.isTrue(refused, "a connection to port 0 was attempted");
	}

	/**
		Makes a listening host from `uri`, waits for it to have a port (Node
		claims one a turn after `listen()`), dials it with `dial`, and checks
		the host accepted the connection on the port it reported. `dial`
		answers with how to close what it opened.
	**/
	private static function __acceptOne(uri:String, dial:(Int, String->Void)->(Void->Void), async:Async):Void {
		var host:NetHost = null;
		var accepted:INetConnection = null;
		var failure:String = null;

		try {
			host = new NetHost(uri, connection -> accepted = connection, null, null, true);
		} catch (e:Dynamic) {
			Assert.fail(uri + " was refused: " + Std.string(e));
			async.done();
			return;
		}

		NetPump.until(() -> host.localPort != 0, DEADLINE, function(bound:Bool) {
			if (!bound) {
				Assert.fail(uri + " gave a host with no port");
				__quietly(() -> host.close());
				async.done();
				return;
			}

			var port:Int = host.localPort;
			Assert.isTrue(port > 0 && port <= 65535, uri + " reported port " + port);

			var closeClient = dial(port, text -> failure = text);

			NetPump.until(() -> accepted != null || failure != null, DEADLINE, function(_) {
				Assert.isNull(failure, "a client could not reach the host on the port it reported: " + failure);
				Assert.notNull(accepted, "the host on port " + port + " accepted nothing");
				// The host's end first. A client closed first with an answer unread
				// resets the connection, and the interpreter dies of a send that meets
				// a reset (the WebSocket session's close frame) where every other
				// target reports it.
				if (accepted != null) {
					__quietly(accepted.close);
				}
				__quietly(closeClient);
				__quietly(() -> host.close());
				async.done();
			});
		});
	}

	private static function __quietly(close:Void->Void):Void {
		try {
			close();
		} catch (_:Dynamic) {}
	}
}
