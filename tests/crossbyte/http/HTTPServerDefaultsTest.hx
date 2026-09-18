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
