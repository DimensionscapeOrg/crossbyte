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
	#if (cpp || neko || hl || java || jvm)
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

	public function testEveryCookieAScriptSetsReachesTheClient():Void {
		var backend = new FakeFastCGI();
		var world = new PhpWorld(backend);

		world.send("GET /index.php HTTP/1.1\r\nHost: localhost\r\n\r\n");

		// PHP sends one Set-Cookie line per cookie, and the bridge stored its
		// headers by name, so each line overwrote the one before and only the
		// last cookie reached the browser. The comma in the Expires date is
		// deliberate: joining cookies with ", " would put one in the middle of
		// a value, and nothing downstream could split them apart again.
		backend.answer(200, "text/plain", "from php", [
			"Set-Cookie: session=abc; Path=/; HttpOnly",
			"Set-Cookie: theme=dark; Expires=Wed, 21 Oct 2037 07:28:00 GMT"
		]);
		HTTPTestSupport.pumpUntil(() -> world.responseCount() > 0, 3.0);

		var response = HTTPTestSupport.parseResponse(world.raw);
		Assert.equals(200, response.status, "not the PHP response: " + world.raw);
		Assert.equals("from php", response.body);

		var cookies:Array<String> = setCookies(world.raw);
		Assert.equals(2, cookies.length, "expected two Set-Cookie headers, got " + cookies);
		Assert.equals("session=abc; Path=/; HttpOnly", cookies[0]);
		Assert.equals("theme=dark; Expires=Wed, 21 Oct 2037 07:28:00 GMT", cookies[1]);

		world.close();
	}

	public function testAScriptSeesTheRequestsHeadersAndTheClientTheScripts():Void {
		// The bridge passed a script eight request headers and gave the client
		// four of the script's back, so CORS, named downloads, HTTP auth,
		// conditional requests and CSRF checks broke behind it.
		var backend = new FakeFastCGI();
		var world = new PhpWorld(backend);

		world.send("GET /index.php HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example\r\nX-Requested-With: XMLHttpRequest\r\n"
			+ "If-None-Match: \"v1\"\r\nRange: bytes=0-1\r\nX-CSRF-Token: t0k\r\nX-Forwarded-Proto: https\r\n"
			// Not passed on: httpoxy's Proxy, a name only an underscore tells
			// apart from X-Forwarded-For, and the connection's own fields.
			+ "Proxy: http://evil.example\r\nX_Forwarded_For: 6.6.6.6\r\nConnection: keep-alive, X-Hop\r\nX-Hop: secret\r\n\r\n");
		HTTPTestSupport.pumpMore(10);

		// FastCGI writes a parameter's name straight before its value.
		for (pair in [
			"HTTP_ORIGINhttps://app.example",
			"HTTP_X_REQUESTED_WITHXMLHttpRequest",
			"HTTP_IF_NONE_MATCH\"v1\"",
			"HTTP_RANGEbytes=0-1",
			"HTTP_X_CSRF_TOKENt0k",
			"HTTP_X_FORWARDED_PROTOhttps",
			"HTTP_HOSTlocalhost"
		]) {
			Assert.isTrue(backend.request.indexOf(pair) >= 0, "the script was not given " + pair);
		}
		for (name in ["HTTP_PROXY", "HTTP_X_FORWARDED_FOR", "HTTP_CONNECTION", "HTTP_X_HOP"]) {
			Assert.equals(-1, backend.request.indexOf(name), "the script was given " + name);
		}

		backend.answer(200, "application/pdf", "pdf!", [
			"ETag: \"v2\"",
			"Content-Disposition: attachment; filename=\"a.pdf\"",
			"WWW-Authenticate: Basic realm=\"x\"",
			"Vary: Accept-Language",
			"X-Custom: yes",
			"Access-Control-Allow-Origin: https://app.example",
			// The server's to write, whatever the script says.
			"Content-Length: 999",
			"Connection: close",
			"Server: PHP"
		]);
		HTTPTestSupport.pumpUntil(() -> world.responseCount() > 0, 3.0);

		var response = HTTPTestSupport.parseResponse(world.raw);
		Assert.equals(200, response.status, "not the PHP response: " + world.raw);
		Assert.equals("pdf!", response.body);
		Assert.equals("\"v2\"", response.headers.get("etag"));
		Assert.equals("attachment; filename=\"a.pdf\"", response.headers.get("content-disposition"));
		Assert.equals("Basic realm=\"x\"", response.headers.get("www-authenticate"));
		Assert.equals("Accept-Language", response.headers.get("vary"));
		Assert.equals("yes", response.headers.get("x-custom"));
		Assert.equals("https://app.example", response.headers.get("access-control-allow-origin"));
		Assert.equals("4", response.headers.get("content-length"));
		Assert.equals("CrossByte", response.headers.get("server"));
		Assert.equals(-1, world.raw.indexOf("Status:"), "the CGI Status field reached the client");
		Assert.equals(1, world.raw.split("\r\nServer:").length - 1, "two Server fields");

		world.close();
	}

	public function testWhatAScriptEncodedIsNotEncodedAgain():Void {
		// A script under zlib.output_compression names its own coding. Passing
		// that field back means the server must not compress the body on top.
		var backend = new FakeFastCGI();
		var world = new PhpWorld(backend);
		var body:String = StringTools.rpad("", "a", 2000);

		world.send("GET /index.php HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n");
		backend.answer(200, "text/plain", body, ["Content-Encoding: br"]);
		HTTPTestSupport.pumpUntil(() -> world.responseCount() > 0, 3.0);

		var response = HTTPTestSupport.parseResponse(world.raw);
		Assert.equals(200, response.status);
		Assert.equals("br", response.headers.get("content-encoding"));
		Assert.equals(1, world.raw.split("\r\nContent-Encoding:").length - 1, "the body was encoded twice");
		Assert.equals(body, response.body);

		world.close();
	}

	public function testABlacklistedScriptIsRefusedHoweverItIsReached():Void {
		// The lists were checked where a file is served and nowhere else, so a
		// GET for a blacklisted script was refused while a POST to it, and a
		// rewrite carrying the PHP flag onto it, ran it.
		var backend = new FakeFastCGI();
		var world = new PhpWorld(backend, (config, root) -> {
			config.blacklist = [root.resolvePath("admin.php").nativePath];
			config.rewrites = [{pattern: "^/panel$", target: "/admin.php", flags: [crossbyte.http.config.RewriteFlag.PHP]}];
		}, ["admin.php" => "<?php echo 'secret'; ?>"]);

		var asked:Array<String> = [
			"GET /admin.php HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"POST /admin.php HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\na=1",
			"GET /panel HTTP/1.1\r\nHost: localhost\r\n\r\n",
			"POST /panel HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\na=1"
		];
		var statuses:Array<Int> = world.answersTo(asked);

		Assert.same([403, 403, 403, 403], statuses, "GET, POST, and a PHP rewrite of each, onto a blacklisted script");
		Assert.isFalse(backend.received, "a blacklisted script reached the PHP backend");
		world.close();
	}

	public function testAWhitelistHoldsForEveryMethodAndEveryRewrite():Void {
		var backend = new FakeFastCGI();
		var world = new PhpWorld(backend, (config, root) -> {
			config.whitelist = [root.resolvePath("index.php").nativePath, root.resolvePath("static.html").nativePath];
			config.rewrites = [{pattern: "^/panel$", target: "/admin.php", flags: [crossbyte.http.config.RewriteFlag.PHP]}];
		}, ["admin.php" => "<?php echo 'secret'; ?>"]);

		var statuses:Array<Int> = world.answersTo([
			"POST /admin.php HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\na=1",
			"GET /panel HTTP/1.1\r\nHost: localhost\r\n\r\n",
			// Listed, and not a script: refused as a POST to a static file is.
			"POST /static.html HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\na=1",
			"GET /static.html HTTP/1.1\r\nHost: localhost\r\n\r\n"
		]);

		Assert.same([403, 403, 405, 200], statuses);
		Assert.isFalse(backend.received, "a script off the whitelist reached the PHP backend");
		world.close();
	}

	/**
	 * Every Set-Cookie value in the first response, in order.
	 *
	 * Read off the raw header block rather than through
	 * `HTTPTestSupport.parseResponse`, whose map keeps one value per name --
	 * the same collapse this is checking for.
	 */
	private function setCookies(raw:String):Array<String> {
		var cookies:Array<String> = [];
		var headerEnd:Int = raw.indexOf("\r\n\r\n");

		if (headerEnd < 0) {
			return cookies;
		}

		for (line in raw.substr(0, headerEnd).split("\r\n")) {
			var colon:Int = line.indexOf(":");

			if (colon > 0 && StringTools.trim(line.substr(0, colon)).toLowerCase() == "set-cookie") {
				cookies.push(StringTools.trim(line.substr(colon + 1)));
			}
		}

		return cookies;
	}
	#end
}

#if (cpp || neko || hl || java || jvm)
/**
 * A backend that speaks FastCGI and answers on command.
 */
private class FakeFastCGI {
	public var received(default, null):Bool = false;
	public var localPort(get, never):Int;

	/** Every byte the bridge sent, one character each. */
	public var request(default, null):String = "";

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
					var chunk = new ByteArray();
					peer.readBytes(chunk, 0, peer.bytesAvailable);
					for (i in 0...chunk.length) {
						request += String.fromCharCode(chunk[i]);
					}
					received = true;
				}
			});
		});

		listener.bind(0, "127.0.0.1");
		listener.listen();
		HTTPTestSupport.pumpUntil(() -> listener.localPort != 0, 2.0);
	}

	public function answer(status:Int, contentType:String, body:String, ?headers:Array<String>):Void {
		if (peer == null) {
			return;
		}

		var cgi = "Status: " + status + "\r\nContent-Type: " + contentType + "\r\n";
		if (headers != null) {
			for (header in headers) {
				cgi += header + "\r\n";
			}
		}
		cgi += "\r\n" + body;
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

	/**
	 * @param configure Applied to the configuration last, with the document
	 *        root, which holds `files` as well as the two every case has.
	 */
	public function new(backend:FakeFastCGI, ?configure:(HTTPServerConfig, File) -> Void, ?files:Map<String, String>) {
		this.backend = backend;
		root = File.createTempDirectory();
		__write("index.php", "<?php echo 1; ?>");
		__write("static.html", "static fallback");
		if (files != null) {
			for (name => contents in files) {
				__write(name, contents);
			}
		}

		var config = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.php", "index.html"]);
		config.phpEnabled = true;
		// 0 is Connect: talk to a backend already listening rather than launch
		// php-cgi. There is no PHP in CI and this test does not want one --
		// what is under test is the handler, not the interpreter.
		config.phpMode = 0;
		config.phpAddress = "127.0.0.1";
		config.phpPort = backend.localPort;
		config.phpTimeout = 10;
		if (configure != null) {
			configure(config, root);
		}
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

	/**
	 * Sends each of `requests` on a connection of its own, all at once, and
	 * answers each one's status, or 0 for one not answered in time.
	 */
	public function answersTo(requests:Array<String>):Array<Int> {
		var views:Array<ClientView> = [for (request in requests) freshClient(request)];
		HTTPTestSupport.pumpUntil(() -> Lambda.foreach(views, view -> HTTPTestSupport.isResponseComplete(view.text())), 5.0);
		return [for (view in views) HTTPTestSupport.parseResponse(view.text()).status];
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
