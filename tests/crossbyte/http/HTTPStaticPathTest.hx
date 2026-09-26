package crossbyte.http;

import crossbyte.http.HTTPTestSupport.HTTPTestResponse;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import utest.Assert;
import utest.Async;

/**
 * Which files a request path may reach, and what the path looks like to the
 * code that decides.
 *
 * A server with a document root answers from the filesystem whatever no
 * middleware answered, so the rules here are the whole of what stands between
 * a request and a file: which names are kept back, and whether the path a
 * middleware guard inspects is the path that is then served.
 */
@:timeout(20000)
class HTTPStaticPathTest extends utest.Test {
	private var __roots:Array<File> = [];

	public function teardown():Void {
		for (root in __roots) {
			try {
				root.deleteDirectory(true);
			} catch (_:Dynamic) {}
		}

		__roots = [];
	}

	/**
		A document root that is a checkout holds `.env` and `.git/` without
		anyone having decided to publish them. They answer as though absent.
	**/
	public function testDotfilesAreNotServed(async:Async):Void {
		var server:HTTPServer = __serve(null);

		HTTPTestSupport.exchangeEach(server, [
			"GET /.env HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /.git/config HTTP/1.1\r\nHost: x\r\n\r\n",
			// Backslash separates segments on the filesystem Windows reads from.
			"GET /sub%5C.env HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /public.txt HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(404, responses[0].status, "/.env was served");
			Assert.isTrue(responses[0].raw.indexOf("SECRET") < 0, "the .env contents reached the client");
			Assert.equals(404, responses[1].status, "/.git/config was served");
			Assert.isTrue(responses[1].raw.indexOf("repositoryformatversion") < 0, "the git config reached the client");
			Assert.equals(404, responses[2].status, "a dotfile named through a backslash was served");
			Assert.isTrue(responses[2].raw.indexOf("NESTED") < 0, "the nested .env reached the client");
			Assert.equals(200, responses[3].status, "an ordinary file stopped being served");
			async.done();
		});
	}

	/** RFC 8615's directory is for files a site means to publish. **/
	public function testWellKnownIsServed(async:Async):Void {
		var server:HTTPServer = __serve(null);

		HTTPTestSupport.exchangeEach(server, ["GET /.well-known/acme-challenge/token123 HTTP/1.1\r\nHost: x\r\n\r\n"], function(responses):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(200, responses[0].status, "an ACME challenge was refused");
			Assert.equals("acme-proof", responses[0].body);
			async.done();
		});
	}

	/** The switch puts dotfiles back for a server that means to serve them. **/
	public function testServeDotFilesServesThem(async:Async):Void {
		var server:HTTPServer = __serve(config -> config.serveDotFiles = true);

		HTTPTestSupport.exchangeEach(server, ["GET /.env HTTP/1.1\r\nHost: x\r\n\r\n"], function(responses):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(200, responses[0].status);
			Assert.equals("SECRET=1", responses[0].body);
			async.done();
		});
	}

	/** Routes see every path; the rule is about files. **/
	public function testMiddlewareStillSeesDotPaths(async:Async):Void {
		var router:Router = new Router();
		router.get("/.well-known/openid-configuration", ctx -> ctx.handler.respond(200, "application/json", '{"issuer":"x"}'));
		router.get("/.hidden/route", ctx -> ctx.handler.respond(200, "text/plain", "routed"));

		var server:HTTPServer = __serve(config -> config.middleware.push(router.middleware()));

		HTTPTestSupport.exchangeEach(server, [
			"GET /.well-known/openid-configuration HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /.hidden/route HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(200, responses[0].status);
			Assert.equals(200, responses[1].status);
			Assert.equals("routed", responses[1].body);
			async.done();
		});
	}

	private function __serve(configure:Null<HTTPServerConfig->Void>):HTTPServer {
		var root:File = File.createTempDirectory();
		__roots.push(root);

		__write(root, "public.txt", "public");
		__write(root, ".env", "SECRET=1");
		root.resolvePath(".git").createDirectory();
		__write(root, ".git/config", "[core]\n\trepositoryformatversion = 0\n");
		root.resolvePath("sub").createDirectory();
		__write(root, "sub/.env", "NESTED=1");
		root.resolvePath(".well-known").createDirectory();
		root.resolvePath(".well-known/acme-challenge").createDirectory();
		__write(root, ".well-known/acme-challenge/token123", "acme-proof");

		var config:HTTPServerConfig = new HTTPServerConfig("127.0.0.1", 0, root, null, ["index.html"]);
		if (configure != null) {
			configure(config);
		}
		return new HTTPServer(config);
	}

	private static function __write(root:File, relative:String, text:String):Void {
		var data:ByteArray = new ByteArray();
		data.writeUTFBytes(text);
		root.resolvePath(relative).save(data);
	}
}
