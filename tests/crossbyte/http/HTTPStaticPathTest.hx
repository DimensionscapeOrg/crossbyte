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

	/**
		A file created a moment after its directory was listed is served.

		On Windows and macOS the resolver checks a path's spelling against its
		directory's listing, and keeps listings for a second. A name missing
		from a kept listing must send the resolver back to the directory, not
		to a 404, or every newly deployed file would be refused for a second.
	**/
	public function testAFileCreatedAfterAListingIsServed(async:Async):Void {
		var server:HTTPServer = __serve(null);
		var root:File = __roots[__roots.length - 1];

		HTTPTestSupport.exchangeEach(server, ["GET /public.txt HTTP/1.1\r\nHost: x\r\n\r\n"], function(first):Void {
			__write(root, "fresh.txt", "just deployed");

			HTTPTestSupport.exchangeEach(server, ["GET /fresh.txt HTTP/1.1\r\nHost: x\r\n\r\n"], function(second):Void {
				try server.close() catch (_:Dynamic) {}

				Assert.equals(200, first[0].status);
				Assert.equals(200, second[0].status, "a file created after its directory was listed was refused");
				Assert.equals("just deployed", second[0].body);
				async.done();
			});
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

	/**
		A guard on `/private/` sees every spelling that would be served from
		`private/`.

		The path was only percent-decoded for middleware, while the resolver
		collapsed slashes and applied dot steps on its own, so the auditor's
		guard let `//private/report.txt` and `/./private/report.txt` through
		and the resolver served the file for both. On Windows and macOS
		`/PRIVATE/report.txt` went the same way, since the filesystem answers
		to any case: now a file is served only under its own spelling there,
		as on Linux.
	**/
	public function testAGuardSeesThePathThatIsServed(async:Async):Void {
		var server:HTTPServer = __serve(config -> config.middleware.push(__guard));

		var guarded:Array<String> = [
			"/private/report.txt", "//private/report.txt", "/./private/report.txt", "/x/../private/report.txt", "/private//report.txt",
			"/private/./report.txt", "/private%2freport.txt", "/%2Fprivate/report.txt", "/private%5Creport.txt", "/private/REPORT.TXT",
			"/private/report.txt.", "/private/report.txt::$DATA"
		];
		// Spellings the guard does not match, which must then find nothing:
		// other cases, a trailing dot or space, and Windows short names,
		// including the ones Windows gives dotfiles, which have no dot.
		var unguarded:Array<String> = [
			"/PRIVATE/report.txt", "/Private/report.txt", "/private./report.txt", "/private%20/report.txt", "/PRIVAT~1/report.txt",
			"/ENV~1", "/GIT~1/config"
		];

		var requests:Array<String> = [for (path in guarded.concat(unguarded)) "GET " + path + " HTTP/1.1\r\nHost: x\r\n\r\n"];
		HTTPTestSupport.exchangeEach(server, requests, function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}

			for (i in 0...guarded.length) {
				Assert.equals(401, responses[i].status, guarded[i] + " was not seen by the guard");
			}
			for (i in 0...unguarded.length) {
				var response:HTTPTestResponse = responses[guarded.length + i];
				Assert.equals(404, response.status, unguarded[i] + " was served past the guard");
			}
			for (response in responses) {
				Assert.isTrue(response.raw.indexOf("TOP-SECRET") < 0, "the guarded file was served: " + response.raw.substr(0, 60));
				Assert.isTrue(response.raw.indexOf("SECRET=1") < 0, "a dotfile was served by its short name");
				Assert.isTrue(response.raw.indexOf("repositoryformatversion") < 0, "the git config was served by its short name");
			}
			async.done();
		});
	}

	/**
		A path naming an environment variable is a name like any other.

		On Windows a `File` reads `%NAME%` in its path from the environment,
		and the server made one from the request path after the checks a path
		is held to, dotfiles, the root, had been made on the path as it was
		written. `/%25X%25` was checked as `/%X%` and served as whatever `X`
		held: a dotfile, or a file outside the root.
	**/
	public function testAPathNamingAnEnvironmentVariableIsNotExpanded(async:Async):Void {
		var server:HTTPServer = __serve(null);
		var root:File = __roots[__roots.length - 1];
		// Beside the root, where no path under it should reach.
		var outsideName:String = "cb-outside-" + Std.random(1000000) + ".txt";
		var outside:File = root.parent.resolvePath(outsideName);
		__write(root.parent, outsideName, "OUTSIDE-THE-ROOT");

		// The jvm cannot set one (Haxe throws there), and Linux and macOS do
		// not expand one, so there the requests only name files that are not
		// there; the case means something on Windows, natively and on Node.
		// Not a warning: utest counts one against the run, and the jvm would
		// fail every time.
		try {
			Sys.putEnv("CB_HTTP_PROBE_DOTFILE", ".env");
			Sys.putEnv("CB_HTTP_PROBE_ESCAPE", ".." + (crossbyte.sys.System.isWindows ? "\\" : "/") + outsideName);
		} catch (_:Dynamic) {}

		HTTPTestSupport.exchangeEach(server, [
			"GET /%25CB_HTTP_PROBE_DOTFILE%25 HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /%25CB_HTTP_PROBE_ESCAPE%25 HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses:Array<HTTPTestResponse>):Void {
			try server.close() catch (_:Dynamic) {}
			try outside.deleteFile() catch (_:Dynamic) {}

			Assert.equals(404, responses[0].status, "a path naming a variable that held a dotfile's name was served");
			Assert.isTrue(responses[0].raw.indexOf("SECRET") < 0, "the .env contents reached the client");
			Assert.equals(404, responses[1].status, "a path naming a variable that climbed out of the root was served");
			Assert.isTrue(responses[1].raw.indexOf("OUTSIDE-THE-ROOT") < 0, "a file outside the root reached the client");
			async.done();
		});
	}

	/**
		A `..` inside a segment is part of a name. Any `..` anywhere used to
		throw out of the resolver, which ran before the router, so a route
		whose parameter held one answered 500.
	**/
	public function testDotsInsideANameReachTheRouter(async:Async):Void {
		var router:Router = new Router();
		router.get("/api/compare/:range", ctx -> ctx.handler.respond(200, "text/plain", ctx.params.get("range")));
		var server:HTTPServer = __serve(config -> config.middleware.push(router.middleware()));

		HTTPTestSupport.exchangeEach(server, [
			"GET /api/compare/v1.2..v1.3 HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /api/compare/backup..old HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /api/compare/... HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses):Void {
			try server.close() catch (_:Dynamic) {}

			Assert.equals(200, responses[0].status);
			Assert.equals("v1.2..v1.3", responses[0].body);
			Assert.equals(200, responses[1].status);
			Assert.equals("backup..old", responses[1].body);
			Assert.equals(200, responses[2].status);
			Assert.equals("...", responses[2].body);
			async.done();
		});
	}

	/** Climbing above the root is refused as malformed, before middleware sees it. **/
	public function testAPathClimbingAboveTheRootIsRefused(async:Async):Void {
		var seen:Array<String> = [];
		var server:HTTPServer = __serve(config -> config.middleware.push(function(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
			seen.push(handler.requestPath);
			next();
		}));

		HTTPTestSupport.exchangeEach(server, [
			"GET /../public.txt HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /sub/../../public.txt HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /%2e%2e/public.txt HTTP/1.1\r\nHost: x\r\n\r\n",
			"GET /..%5Cpublic.txt HTTP/1.1\r\nHost: x\r\n\r\n",
			// Steps that stay inside are applied, not refused.
			"GET /sub/../public.txt HTTP/1.1\r\nHost: x\r\n\r\n"
		], function(responses):Void {
			try server.close() catch (_:Dynamic) {}

			for (i in 0...4) {
				Assert.equals(400, responses[i].status, "escape " + i + " was not refused");
			}
			Assert.equals(200, responses[4].status);
			Assert.equals("public", responses[4].body);
			Assert.equals(1, seen.length, "middleware saw an escaping path: " + seen.join(", "));
			Assert.equals("/public.txt", seen[0]);
			async.done();
		});
	}

	#if nodejs
	/**
		A request a route answers never reaches the filesystem.

		The resolver ran before middleware, so every routed request paid for
		three lookups, the auditor counted 297 for 99 requests, on the
		runtime's own thread. Counted here by wrapping Node's `fs`, which is
		the one target where the calls can be seen from inside.
	**/
	public function testARoutedRequestDoesNotTouchTheFilesystem(async:Async):Void {
		var router:Router = new Router();
		router.get("/api/users/:id", ctx -> ctx.handler.respond(200, "application/json", '{"id":"' + ctx.params.get("id") + '"}'));
		var server:HTTPServer = __serve(config -> config.middleware.push(router.middleware()));

		js.Syntax.code("var fs = require('fs'); globalThis.__cbFsCalls = 0; globalThis.__cbFsOriginal = {}; for (const k of ['existsSync', 'statSync', 'lstatSync', 'accessSync', 'readdirSync', 'openSync']) { const orig = fs[k]; globalThis.__cbFsOriginal[k] = orig; fs[k] = function() { globalThis.__cbFsCalls++; return orig.apply(fs, arguments); }; }");

		var calls:Int = -1;
		HTTPTestSupport.exchangeEach(server, [for (i in 0...20) "GET /api/users/" + i + " HTTP/1.1\r\nHost: x\r\n\r\n"], function(responses):Void {
			calls = js.Syntax.code("globalThis.__cbFsCalls");
			js.Syntax.code("var fs = require('fs'); for (const k in globalThis.__cbFsOriginal) { fs[k] = globalThis.__cbFsOriginal[k]; }");
			try server.close() catch (_:Dynamic) {}

			for (response in responses) {
				Assert.equals(200, response.status);
			}
			Assert.equals(0, calls, "routed requests reached the filesystem " + calls + " times");
			async.done();
		});
	}
	#end

	private static function __guard(handler:HTTPRequestHandler, next:?Dynamic->Void):Void {
		if (StringTools.startsWith(handler.requestPath, "/private/") && handler.getHeader("authorization") != "Bearer letmein") {
			handler.respond(401, "application/json", '{"error":"unauthorized"}');
			return;
		}
		next();
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
		root.resolvePath("private").createDirectory();
		__write(root, "private/report.txt", "TOP-SECRET-REPORT");

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
