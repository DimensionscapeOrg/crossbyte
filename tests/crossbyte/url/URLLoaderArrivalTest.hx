package crossbyte.url;

import crossbyte.events.DatagramSocketDataEvent;
import crossbyte.events.Event;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.net.DatagramSocket;
import crossbyte.net.NetPump;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
	"Copy it to keep it", from the side that is handed the payload: a
	datagram forwarded, from inside its `DATA` listener, as the body of an
	HTTP request (a bridge from a game's UDP to a web backend).

	`DatagramSocketDataEvent.data` says sending it on from the listener is
	safe, every send copying what it is given before it returns, and
	`URLLoader` has to keep that promise too. Natively and on the jvm `load`
	keeps the `URLRequest`, and its body is read on a pool thread later
	(`LoaderRun.execute`), after the listener has returned and the socket
	has emptied the payload. On Node the body goes to Node's request
	(`JsHttpClient`), which Node writes once it has connected: a view of the
	payload's storage (`Buffer.from(body.getData(), 0, length)`) would by
	then hold the next datagram.

	Asynchronous, so Node runs it too.
**/
class URLLoaderArrivalTest extends utest.Test {
	@:timeout(20000)
	public function testABodyForwardedFromADatagramIsWhatArrived(async:Async):Void {
		if (!DatagramSocket.isSupported || !ServerSocket.isSupported) {
			Assert.pass();
			async.done();
			return;
		}

		var first:String = "the first datagram, forwarded as an HTTP body";
		var http = new BodyServer();
		var server = new DatagramSocket();
		var client = new DatagramSocket();
		server.bind(0, "127.0.0.1");
		client.bind(0, "127.0.0.1");
		server.receive();

		var loader = new URLLoader();
		var settled:Bool = false;
		var failure:String = null;
		loader.addEventListener(Event.COMPLETE, _ -> settled = true);
		loader.addEventListener(IOErrorEvent.IO_ERROR, (e:IOErrorEvent) -> {
			settled = true;
			failure = e.text;
		});

		var arrived:Int = 0;
		var during:String = null;
		server.addEventListener(DatagramSocketDataEvent.DATA, function(e:DatagramSocketDataEvent):Void {
			arrived++;
			if (arrived == 1) {
				during = e.data.toString();
				var request = new URLRequest('http://127.0.0.1:${http.port}/forward');
				request.method = URLRequestMethod.POST;
				request.contentType = "application/octet-stream";
				request.data = e.data;
				request.idleTimeout = 3000;
				loader.load(request);
			}
		});

		NetPump.until(() -> http.port > 0 && server.localPort > 0 && client.localPort > 0, 5.0, function(_) {
			client.send(bytesOf(first), 0, 0, "127.0.0.1", server.localPort);
			client.send(bytesOf("SECOND"), 0, 0, "127.0.0.1", server.localPort);

			NetPump.until(() -> arrived >= 2 && settled && http.body != null, 10.0, function(_) {
				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				http.close();

				Assert.equals(first, during, "the datagram was not itself in its own call");
				Assert.notNull(http.body, "the HTTP request never reached the server: " + failure);
				Assert.equals(first, http.body, 'the body that went out was not the datagram the listener forwarded, but "${printable(http.body)}"');
				NetPump.wait(0.1, () -> async.done());
			});
		});
	}

	/** `text` with anything but printable ASCII shown as `?`: a killed payload reads 0xDB. **/
	private static function printable(text:Null<String>):String {
		if (text == null) {
			return "null";
		}
		var out = new StringBuf();
		for (i in 0...text.length) {
			var code:Int = StringTools.fastCodeAt(text, i);
			out.addChar(code >= 0x20 && code < 0x7F ? code : "?".code);
		}
		return out.toString();
	}

	private static function bytesOf(text:String):ByteArray {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(text);
		bytes.position = 0;
		return bytes;
	}
}

/** Takes one HTTP request on the runtime, keeps its body, and answers 200. **/
private class BodyServer {
	public var port(get, never):Int;
	public var body:Null<String> = null;

	private var __listener:ServerSocket;
	private var __peers:Array<Socket> = [];

	public function new() {
		__listener = new ServerSocket();
		__listener.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			var peer:Socket = e.socket;
			__peers.push(peer);
			var received = new ByteArray();
			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				peer.readBytes(received, received.length, peer.bytesAvailable);
				var text:String = received.toString();
				var end:Int = text.indexOf("\r\n\r\n");
				if (end < 0 || body != null) {
					return;
				}
				var length:Int = 0;
				for (line in text.substring(0, end).split("\r\n")) {
					var colon:Int = line.indexOf(":");
					if (colon > 0 && StringTools.trim(line.substr(0, colon)).toLowerCase() == "content-length") {
						length = Std.parseInt(StringTools.trim(line.substr(colon + 1)));
					}
				}
				// Bytes, not characters: the head is ASCII.
				if (received.length < end + 4 + length) {
					return;
				}
				var content = new ByteArray();
				if (length > 0) {
					content.writeBytes(received, end + 4, length);
				}
				body = content.toString();
				peer.writeUTFBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
				peer.flush();
			});
		});
		__listener.bind(0, "127.0.0.1");
		__listener.listen();
	}

	private function get_port():Int {
		return __listener.localPort;
	}

	public function close():Void {
		for (peer in __peers) {
			try peer.close() catch (_:Dynamic) {}
		}
		try __listener.close() catch (_:Dynamic) {}
	}
}
