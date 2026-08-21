package crossbyte.http;

import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket;
import utest.Assert;

/**
 * The server serving PHP, end to end, against a backend held open on purpose.
 *
 * Proposal 0021 names four things an asynchronous bridge has to survive. Two
 * are covered where the bridge itself is tested -- a backend that never
 * answers, and a record torn across two reads. The other two are not properties
 * of the bridge at all but of the handler wrapped around it, and they only
 * appear once a response can arrive after the request that asked for it has
 * stopped being the current one:
 *
 * - a second request pipelined onto the same connection while PHP is thinking
 * - a client that hangs up mid-exchange
 *
 * The backend here is a socket that speaks FastCGI and answers when this test
 * says so, not when a timer says so. Holding the answer is the entire point:
 * both hazards live in the window between the request going out and the
 * response coming back, and a backend that replies promptly closes that window
 * before anything can be observed inside it.
 */
class HTTPPhpTest extends utest.Test {
	#if (cpp || neko || hl)
	public function testAPipelinedRequestWaitsForThePhpResponse():Void {
		var backend = new FakeFastCGI();
		var world = new PhpWorld(backend);

		world.send("GET /index.php HTTP/1.1\r\nHost: localhost\r\n\r\n");

		// Sent separately, and only once PHP is genuinely outstanding. Both
		// requests in one write would prove nothing: they arrive in one read,
		// the parse loop takes one request per pass and does not go round again
		// unless asked, so the second would wait however the guard behaved.
		// Arriving as its own segment is what puts a fresh parse in front of an
		// unanswered request, which is the case the guard is there for.
		world.sendMore("GET /static.html HTTP/1.1\r\nHost: localhost\r\n\r\n");

		// The static file needs no backend and would be answered at once by a
		// handler that kept parsing while PHP was outstanding. That is the
		// failure this exists for: the second response overtaking the first
		// puts the wrong body against the wrong request, and both clients get
		// an answer to a question they did not ask.
		HTTPTestSupport.pumpUntil(() -> world.responseCount() > 0, 0.5);
		Assert.equals(0, world.responseCount(), "a response arrived while PHP was still thinking");

		backend.answer(201, "text/plain", "from php");
		HTTPTestSupport.pumpUntil(() -> world.responseCount() >= 2, 3.0);

		Assert.equals(2, world.responseCount());
		Assert.isTrue(world.raw.indexOf("from php") < world.raw.indexOf("static fallback"), "the pipelined response overtook the PHP one");

		world.close();
	}

	public function testAClientThatHangsUpMidExchangeDoesNotTakeTheServerDown():Void {
		var backend = new FakeFastCGI();
		var world = new PhpWorld(backend);

		world.send("GET /index.php HTTP/1.1\r\nHost: localhost\r\n\r\n");

		Assert.isTrue(backend.received, "the bridge never reached the backend");

		// Gone before the backend says anything. The response is now owed to a
		// socket that no longer exists, and the callback has to discover that
		// rather than write into it.
		world.hangUp();
		HTTPTestSupport.pumpMore(10);

		backend.answer(200, "text/plain", "nobody is listening");
		HTTPTestSupport.pumpMore(30);

		// The claim is not "it did not throw" -- an exception swallowed
		// somewhere would pass that too. It is that the server is still a
		// server afterwards, which only a second client can establish.
		//
		// Worth being exact about what this pins, because it is less than it
		// looks: with the handler's staleness guard removed this still passes,
		// since writing into a socket that is already gone is absorbed rather
		// than fatal. So it covers the survival property and not the guard.
		// The pipelined case above is the one that fails when its guard goes,
		// and it was rewritten once because the first version did not.
		var second = world.freshClient("GET /static.html HTTP/1.1\r\nHost: localhost\r\n\r\n");
		HTTPTestSupport.pumpUntil(() -> HTTPTestSupport.isResponseComplete(second.text()), 3.0);

		var response = HTTPTestSupport.parseResponse(second.text());
		Assert.equals(200, response.status, "the server stopped answering after a client abandoned a PHP request");
		Assert.equals("static fallback", response.body);

		world.close();
	}
	#end
}

#if (cpp || neko || hl)
/**
 * A backend that speaks FastCGI and answers on command.
 */
private class FakeFastCGI {
	public var received(default, null):Bool = false;
	public var localPort(get, never):Int;

	private var listener:ServerSocket;
	private var peer:Socket;

	public function new() {
		listener = new ServerSocket();

		listener.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			// Held in a field: an accepted socket referenced only by a local is
			// collectable the moment this returns, and a collected peer closes
			// the connection -- which is a different scenario than either of
			// these two.
			peer = e.socket;

			peer.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				if (peer.bytesAvailable > 0) {
					peer.readUTFBytes(peer.bytesAvailable);
					received = true;
				}
			});
		});

		listener.bind(0, "127.0.0.1");
		listener.listen();
		HTTPTestSupport.pumpUntil(() -> listener.localPort != 0, 2.0);
	}

	public function answer(status:Int, contentType:String, body:String):Void {
		if (peer == null) {
			return;
		}

		var cgi = "Status: " + status + "\r\nContent-Type: " + contentType + "\r\n\r\n" + body;
		var out = new ByteArray();
		__record(out, 6, ByteArray.fromBytes(haxe.io.Bytes.ofString(cgi)));

		var end = new ByteArray();
		for (_ in 0...8) {
			end.writeByte(0);
		}
		__record(out, 3, end);

		peer.writeBytes(out, 0, out.length);
		peer.flush();
	}

	public function close():Void {
		try {
			listener.close();
		} catch (_:Dynamic) {}
	}

	private function __record(into:ByteArray, type:Int, content:ByteArray):Void {
		into.writeByte(1);
		into.writeByte(type);
		into.writeByte(0);
		into.writeByte(1);
		into.writeByte((content.length >> 8) & 0xFF);
		into.writeByte(content.length & 0xFF);
		into.writeByte(0);
		into.writeByte(0);
		into.writeBytes(content, 0, content.length);
	}

	private function get_localPort():Int {
		return listener.localPort;
	}
}

/**
 * A PHP-enabled server, its document root, and one client.
 */
private class PhpWorld {
	public var raw(default, null):String = "";

	private var backend:FakeFastCGI;
	private var root:File;
	private var server:HTTPServer;
	private var client:Socket;
	private var extras:Array<ClientView> = [];

	public function new(backend:FakeFastCGI) {
		this.backend = backend;
		root = File.createTempDirectory();
		__write("index.php", "<?php echo 1; ?>");
		__write("static.html", "static fallback");

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.php", "index.html"]);
		config.phpEnabled = true;
		// 0 is Connect: talk to a backend already listening rather than launch
		// php-cgi. There is no PHP in CI and this test does not want one --
		// what is under test is the handler, not the interpreter.
		config.phpMode = 0;
		config.phpAddress = "127.0.0.1";
		config.phpPort = backend.localPort;
		config.phpTimeout = 10;
		config.validate();

		server = new HTTPServer(config);
		client = new Socket();
		client.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (client.bytesAvailable > 0) {
				raw += client.readUTFBytes(client.bytesAvailable);
			}
		});
	}

	public function send(text:String):Void {
		client.addEventListener(Event.CONNECT, function(_):Void {
			client.writeUTFBytes(text);
			client.flush();
		});
		client.connect("127.0.0.1", server.localPort);
		HTTPTestSupport.pumpUntil(() -> backend.received, 3.0);
	}

	public function sendMore(text:String):Void {
		client.writeUTFBytes(text);
		client.flush();
		HTTPTestSupport.pumpMore(10);
	}

	public function hangUp():Void {
		try {
			client.close();
		} catch (_:Dynamic) {}
	}

	public function responseCount():Int {
		return HTTPTestSupport.countResponses(raw);
	}

	public function freshClient(text:String):ClientView {
		var view = new ClientView(server.localPort, text);
		extras.push(view);
		return view;
	}

	public function close():Void {
		hangUp();

		for (view in extras) {
			view.close();
		}

		try {
			server.close();
		} catch (_:Dynamic) {}
		try {
			backend.close();
		} catch (_:Dynamic) {}
		try {
			root.deleteDirectory(true);
		} catch (_:Dynamic) {}
	}

	private function __write(name:String, contents:String):Void {
		var bytes = new ByteArray();
		bytes.writeUTFBytes(contents);
		root.resolvePath(name).save(bytes);
	}
}

private class ClientView {
	private var socket:Socket;
	private var raw:String = "";

	public function new(port:Int, request:String) {
		socket = new Socket();
		socket.addEventListener(Event.CONNECT, function(_):Void {
			socket.writeUTFBytes(request);
			socket.flush();
		});
		socket.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
			if (socket.bytesAvailable > 0) {
				raw += socket.readUTFBytes(socket.bytesAvailable);
			}
		});
		socket.connect("127.0.0.1", port);
	}

	public function text():String {
		return raw;
	}

	public function close():Void {
		try {
			socket.close();
		} catch (_:Dynamic) {}
	}
}
#end
