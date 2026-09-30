package crossbyte.http;

import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.net.Socket;
import utest.Assert;
import utest.Async;

/**
 * What a server built with `new HTTPServerConfig(...)` and nothing else does.
 *
 * Both of these were found by measurement rather than by reading, and both
 * were defaults nobody had argued for in writing. A limiter of ten requests a
 * minute refused two assets of an ordinary twelve-request page, and an output
 * bound of zero meant a client that stopped reading held its whole response in
 * memory for as long as it liked.
 *
 * Neither number is sacred. The point of the two cases below is that changing
 * one says so out loud: a default that breaks an ordinary page load, or that
 * bounds nothing, should fail a test rather than a deployment.
 */
@:timeout(60000)
class HTTPServerDefaultsTest extends utest.Test {
	/** A document and eleven assets: what one visit to one page costs. **/
	private static inline var PAGE_REQUESTS:Int = 12;

	private var __roots:Array<File> = [];

	public function teardown():Void {
		for (root in __roots) {
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}
		}

		__roots = [];
	}

	public function testAnOrdinaryPageLoadIsServedInFull(async:Async):Void {
		var server:HTTPServer = __makeServer();
		var paths:Array<String> = ["/index.html"];
		for (i in 0...PAGE_REQUESTS - 1) {
			paths.push("/a" + i + ".css");
		}

		var served:Int = 0;
		var refused:Int = 0;

		function fetch(index:Int):Void {
			if (index >= paths.length) {
				Assert.equals(0, refused,
					"the default rate limiter refused " + refused + " of " + PAGE_REQUESTS + " requests in one page load");
				Assert.equals(PAGE_REQUESTS, served, "not every request in the page load was served");

				try server.close() catch (_:Dynamic) {}
				async.done();
				return;
			}

			var client:Socket = new Socket();
			var raw:String = "";
			client.addEventListener(ProgressEvent.SOCKET_DATA, function(_):Void {
				try {
					raw += client.readUTFBytes(client.bytesAvailable);
				} catch (_:Dynamic) {}
			});

			HTTPTestSupport.connectThen(client, server, function():Void {
				client.writeUTFBytes("GET " + paths[index] + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
				client.flush();

				HTTPTestSupport.pumpUntilAsync(() -> HTTPTestSupport.isResponseComplete(raw), 3.0, function(_):Void {
					if (raw.indexOf("429") > 0) {
						refused++;
					} else if (raw.indexOf("200") > 0) {
						served++;
					}

					try client.close() catch (_:Dynamic) {}
					fetch(index + 1);
				});
			});
		}

		fetch(0);
	}

	public function testAnAcceptedConnectionCarriesAnOutputBound(async:Async):Void {
		// The config's value has to reach the socket to bound anything, and
		// an application cannot reach an accepted socket to set it itself --
		// which is the whole reason the server applies it. A default that is
		// never applied looks exactly like one that is.
		var server:HTTPServer = __makeServer();
		var accepted:Int = -1;

		Assert.isTrue(HTTPServerConfig.DEFAULT_MAX_OUTPUT_BUFFER > 0, "the default config left the output buffer unbounded");

		server.addEventListener(ServerSocketConnectEvent.CONNECT, function(e:ServerSocketConnectEvent):Void {
			if (accepted < 0) {
				accepted = e.socket.maxOutputBufferSize;
			}
		});

		var client:Socket = new Socket();

		HTTPTestSupport.connectThen(client, server, function():Void {
			HTTPTestSupport.pumpUntilAsync(() -> accepted >= 0, 3.0, function(seen:Bool):Void {
				Assert.isTrue(seen, "no connection was accepted");
				Assert.equals(HTTPServerConfig.DEFAULT_MAX_OUTPUT_BUFFER, accepted,
					"an accepted socket did not carry the configured output bound");

				try client.close() catch (_:Dynamic) {}
				try server.close() catch (_:Dynamic) {}
				async.done();
			});
		});
	}

	/**
		A server that never set `rootDirectory` serves no files at all.

		The default root used to be `File.applicationStorageDirectory` -- the
		account's home on Linux and macOS, `%APPDATA%` on Windows -- so a
		server with only routes answered every other path from there. This is
		the auditor's case: a session the application saved through `Store`,
		which keeps its files under that same directory, was one guessable
		path away. The canary is written where `Store` writes, which is where
		the store tests already write, and removed afterwards.
	**/
	public function testAServerWithNoRootServesNoFiles(async:Async):Void {
		var name:String = "http-root-canary-" + Std.random(0x3FFFFFFF);
		var canary:String = "session-token-" + Std.random(0x3FFFFFFF);
		var store:crossbyte.io.Store = null;
		var failed:String = null;

		crossbyte.io.Store.open(name).then(function(opened:crossbyte.io.Store):Void {
			opened.putString("user:admin", canary).then(function(_):Void {
				store = opened;
			}, error -> failed = error);
		}, error -> failed = error);

		HTTPTestSupport.pumpUntilAsync(() -> store != null || failed != null, 5.0, function(_):Void {
			if (store == null) {
				Assert.fail("the canary could not be stored: " + failed);
				async.done();
				return;
			}

			var router:Router = new Router();
			router.get("/api/health", ctx -> ctx.handler.respond(200, "application/json", '{"ok":true}'));

			// Deliberately no root: this is what the plain constructor gives.
			var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
			config.middleware.push(router.middleware());
			var server:HTTPServer = new HTTPServer(config);

			var hex:String = haxe.io.Bytes.ofString("user:admin").toHex();
			HTTPTestSupport.exchangeEach(server, [
				"GET /api/health HTTP/1.1\r\nHost: x\r\n\r\n",
				'GET /stores/$name/$hex.value HTTP/1.1\r\nHost: x\r\n\r\n',
				"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
			], function(responses):Void {
				try server.close() catch (_:Dynamic) {}
				__removeStore(store, name);

				Assert.equals(200, responses[0].status, "the route itself was not answered");
				Assert.equals(404, responses[1].status, "a file under the storage directory was served by a server with no root");
				Assert.isTrue(responses[1].raw.indexOf(canary) < 0, "the stored session reached the client");
				Assert.equals(404, responses[2].status, "a server with no root answered / with something other than 404");
				async.done();
			});
		});
	}

	/** An unconfigured listener is reachable from this machine only. **/
	public function testTheDefaultAddressIsLoopback():Void {
		Assert.equals("127.0.0.1", new HTTPServerConfig().address);
		Assert.isNull(new HTTPServerConfig().rootDirectory);
		Assert.isFalse(new HTTPServerConfig().serveDotFiles);
	}

	/**
		What resolves files under the root is refused without one, rather than
		quietly doing nothing.
	**/
	public function testWhatNeedsARootIsRefusedWithoutOne():Void {
		var php:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		php.phpEnabled = true;
		Assert.raises(() -> php.validate(), crossbyte.errors.ArgumentError);

		var rewrites:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		rewrites.rewrites.push({pattern: "^/app$", target: "/app.html"});
		Assert.raises(() -> rewrites.validate(), crossbyte.errors.ArgumentError);

		var fallback:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		fallback.tryFiles.push("/index.html");
		Assert.raises(() -> fallback.validate(), crossbyte.errors.ArgumentError);

		// The routes-only server itself is fine.
		var plain:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0);
		plain.validate();
		Assert.pass();
	}

	/**
		Closes the canary's store and removes its directory.

		The directory is removed here, by name, rather than through an
		asynchronous `clear()` that the `close()` beside it could overtake.
		And more than once if need be: every full native run on Windows left
		one canary behind, its value file still in place -- a file just written
		is often held a moment by something else there, the virus scanner
		first among them, and a delete that meets it fails.
	**/
	private static function __removeStore(store:crossbyte.io.Store, name:String):Void {
		try {
			store.close();
		} catch (_:Dynamic) {}

		var directory:String = haxe.io.Path.join([File.applicationStorageDirectory.nativePath, "stores", name]);
		for (_ in 0...40) {
			try {
				if (!sys.FileSystem.exists(directory)) {
					return;
				}
				for (entry in sys.FileSystem.readDirectory(directory)) {
					sys.FileSystem.deleteFile(haxe.io.Path.join([directory, entry]));
				}
				sys.FileSystem.deleteDirectory(directory);
				return;
			} catch (_:Dynamic) {}
			crossbyte.sys.System.sleep(0.05);
		}
	}

	private function __makeServer():HTTPServer {
		var root:File = File.createTempDirectory();
		__roots.push(root);

		var page:ByteArray = new ByteArray();
		page.writeUTFBytes("index");
		root.resolvePath("index.html").save(page);

		for (i in 0...PAGE_REQUESTS - 1) {
			var asset:ByteArray = new ByteArray();
			asset.writeUTFBytes("asset " + i);
			root.resolvePath("a" + i + ".css").save(asset);
		}

		// Deliberately the plain constructor: this file is about what that
		// gives you, so passing a limiter or a bound here would test nothing.
		return new HTTPServer(new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]));
	}
}
