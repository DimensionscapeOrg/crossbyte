package crossbyte.http;

import crossbyte._internal.http.RewriteEngine;
import crossbyte.http.config.RewriteConditionType;
import crossbyte.http.config.RewriteFlag;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.url.URLRequestHeader;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

class HTTPSupportTest extends utest.Test {
	public function testRateLimiterLimitsAtEleventhRequestAndRefills():Void {
		var now = 0.0;
		var limiter = new RateLimiter(10, 1.0, () -> now);

		for (_ in 0...10) {
			Assert.isFalse(limiter.isRateLimited("127.0.0.1"));
		}
		Assert.isTrue(limiter.isRateLimited("127.0.0.1"));

		now = 1.0;

		Assert.isFalse(limiter.isRateLimited("127.0.0.1"));
		Assert.isFalse(limiter.isRateLimited("192.168.0.2"));
	}

	public function testHTTPServerConfigProvidesIndependentDefaults():Void {
		var first = new HTTPServerConfig();
		var second = new HTTPServerConfig();

		Assert.notNull(first.rateLimiter);
		Assert.notNull(first.tryFiles);
		Assert.notNull(first.rewrites);
		Assert.equals(2, first.directoryIndex.length);
		Assert.equals(3, first.tryFiles.length);
		Assert.equals("$uri", first.tryFiles[0]);
		Assert.equals("/index.html", first.tryFiles[2]);
		Assert.equals(1, first.rewrites.length);
		Assert.equals("^/api/.*$", first.rewrites[0].pattern);
		Assert.isTrue(first.rootDirectory != null);
		// Keep-alive defaults on: it is what HTTP/1.1 specifies and what
		// removes the per-request handshake without client changes.
		Assert.isTrue(first.keepAlive);
		Assert.equals(5.0, first.keepAliveTimeout);
		Assert.equals(100, first.keepAliveMaxRequests);

		first.directoryIndex.push("fallback.htm");
		first.customHeaders.push(new URLRequestHeader("X-Test", "one"));
		first.middleware.push((_, ?next) -> if (next != null) next());
		first.tryFiles.push("/app.html");
		first.rewrites.push({
			pattern: "^/docs/(.*)$",
			target: "/docs/$1",
			flags: [RewriteFlag.L],
			conditions: []
		});

		Assert.equals(3, first.directoryIndex.length);
		Assert.equals(2, second.directoryIndex.length);
		Assert.equals(0, second.customHeaders.length);
		Assert.equals(0, second.middleware.length);
		Assert.equals(3, second.tryFiles.length);
		Assert.equals(1, second.rewrites.length);
	}

	public function testRewriteEngineSupportsStaticPhpAndPassThroughDecisions():Void {
		var root = File.createTempDirectory();
		try {
			root.resolvePath("asset.txt").save(ByteArray.fromBytes(Bytes.ofString("asset")));
			root.resolvePath("index.html").save(ByteArray.fromBytes(Bytes.ofString("home")));
			root.resolvePath("about.html").save(ByteArray.fromBytes(Bytes.ofString("about")));
			root.resolvePath("index.php").save(ByteArray.fromBytes(Bytes.ofString("<?php")));

			var cfg = new HTTPServerConfig(
				"127.0.0.1",
				8080,
				root,
				null,
				["index.html"],
				null,
				null,
				null,
				null,
				null,
				false,
				null,
				null,
				null,
				600,
				false,
				256,
				0,
				false,
				"127.0.0.1",
				8080,
				"php-cgi",
				"php.ini",
				1,
				["$uri", "$uri/", "/index.html"],
				[
					{
						pattern: "^/blog$",
						target: "/about.html",
						flags: [RewriteFlag.PT, RewriteFlag.L],
						conditions: []
					},
					{
						pattern: "^/api/(.*)$",
						target: "/index.php?path=$1",
						flags: [RewriteFlag.PHP, RewriteFlag.QSA, RewriteFlag.L, RewriteFlag.NC],
						conditions: [{
							type: RewriteConditionType.Method,
							key: "",
							pattern: "^GET$",
							negate: false
						}]
					}
				]
			);

			var staticDecision = RewriteEngine.decide(cfg, "/asset.txt", "", "GET", new StringMap<String>());
			Assert.notNull(staticDecision);
			Assert.equals("/asset.txt", staticDecision.finalPath);
			Assert.isTrue(staticDecision.isStatic);
			Assert.isFalse(staticDecision.toPHP);

			var dirDecision = RewriteEngine.decide(cfg, "/", "", "GET", new StringMap<String>());
			Assert.notNull(dirDecision);
			Assert.equals("/index.html", dirDecision.finalPath);
			Assert.isTrue(dirDecision.isStatic);

			var passThrough = RewriteEngine.decide(cfg, "/blog", "", "GET", new StringMap<String>());
			Assert.notNull(passThrough);
			Assert.equals("/about.html", passThrough.finalPath);
			Assert.isTrue(passThrough.isStatic);
			Assert.isFalse(passThrough.toPHP);

			var headers = new StringMap<String>();
			var phpDecision = RewriteEngine.decide(cfg, "/API/users", "page=2", "GET", headers);
			Assert.notNull(phpDecision);
			Assert.equals("/index.php", phpDecision.finalPath);
			Assert.isTrue(phpDecision.toPHP);
			Assert.equals("page=2&path=users", phpDecision.query);
			Assert.isTrue(phpDecision.preserveURI);

			var blockedByMethod = RewriteEngine.decide(cfg, "/api/users", "page=2", "POST", headers);
			Assert.notNull(blockedByMethod);
			Assert.equals("/index.html", blockedByMethod.finalPath);
			Assert.isTrue(blockedByMethod.isStatic);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testRewriteEngineNormalizesAndRejectsTraversal():Void {
		Assert.equals("/api/v1", RewriteEngine.normalize("api//v1"));
		Assert.equals("/", RewriteEngine.normalize(""));

		// The handler already percent-decoded the path once; normalize
		// must not decode again, or the `+` and `%` a single decode
		// legitimately leaves behind name a different file.
		Assert.equals("/a+b.html", RewriteEngine.normalize("/a+b.html"));
		Assert.equals("/100%.html", RewriteEngine.normalize("/100%.html"));

		var threw = false;
		try {
			RewriteEngine.normalize("/../../secret");
		} catch (e:Dynamic) {
			threw = Std.string(e) == "403";
		}

		Assert.isTrue(threw);
	}

	public function testRewriteEngineSupportsHeaderConditionsAndBackrefs():Void {
		var root = File.createTempDirectory();
		try {
			root.resolvePath("mobile.html").save(ByteArray.fromBytes(Bytes.ofString("mobile")));
			var cfg = new HTTPServerConfig(
				"127.0.0.1",
				8080,
				root,
				null,
				["index.html"],
				null,
				null,
				null,
				null,
				null,
				false,
				null,
				null,
				null,
				600,
				false,
				256,
				0,
				false,
				"127.0.0.1",
				8080,
				"php-cgi",
				"php.ini",
				1,
				["$uri", "$uri/", "/index.html"],
				[{
					pattern: "^/content/(.*)$",
					target: "/$1.html",
					flags: [RewriteFlag.PT, RewriteFlag.L],
					conditions: [{
						type: RewriteConditionType.Header,
						key: "User-Agent",
						pattern: "Mobile",
						negate: false
					}]
				}]
			);

			var headers = new StringMap<String>();
			headers.set("User-Agent", "Mobile Safari");
			var allowed = RewriteEngine.decide(cfg, "/content/mobile", "", "GET", headers);
			Assert.notNull(allowed);
			Assert.equals("/mobile.html", allowed.finalPath);

			headers.set("User-Agent", "Desktop");
			var fallback = RewriteEngine.decide(cfg, "/content/mobile", "", "GET", headers);
			Assert.isNull(fallback);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testBackrefExpansionDoesNotReprocessCapturedText():Void {
		// Expansion used to run one String.replace per group, so a group whose
		// captured value itself contained "$2" had that "$2" rewritten by the
		// next pass: the request, not the rule author, decided part of the
		// target. Here group 1 captures the literal text "$2".
		Assert.equals("$2|Q", RewriteEngine.backrefs("^/(.+)/(.+)$", "/$2/Q", "$1|$2", false));

		Assert.equals("/user?name=a$2b&id=ZZZ",
			RewriteEngine.backrefs("^/u/(.+)/(.+)$", "/u/a$2b/ZZZ", "/user?name=$1&id=$2", false));
	}

	public function testBackrefExpansionFollowsModRewriteGroupNumbering():Void {
		// mod_rewrite has $0-$9 only, so "$10" reads as group 1 followed by a
		// literal zero rather than a tenth group.
		Assert.equals("xa0y", RewriteEngine.backrefs("^/(a)(b)$", "/ab", "x$10y", false));

		// $0 is not a group here, and a trailing "$" stays literal.
		Assert.equals("$0", RewriteEngine.backrefs("^/(a)$", "/a", "$0", false));
		Assert.equals("a$", RewriteEngine.backrefs("^/(a)$", "/a", "$1$", false));

		// A group the pattern never captured is left as written.
		Assert.equals("a-$5", RewriteEngine.backrefs("^/(a)$", "/a", "$1-$5", false));

		// A pattern that does not match leaves the target untouched.
		Assert.equals("$1", RewriteEngine.backrefs("^/(a)$", "/b", "$1", false));
	}

	public function testCompiledPatternsAreCachedPerCaseSensitivity():Void {
		// Patterns are compiled once and reused across requests, so one source
		// pattern held both with and without NC must not collapse into a
		// single cached expression.
		Assert.isTrue(RewriteEngine.reMatch("^/API$", "/API", false));
		Assert.isFalse(RewriteEngine.reMatch("^/API$", "/api", false));
		Assert.isTrue(RewriteEngine.reMatch("^/API$", "/api", true));
		Assert.isFalse(RewriteEngine.reMatch("^/API$", "/api", false));

		// Nor may a reused expression carry captures over from a prior call.
		Assert.equals("/x/users", RewriteEngine.backrefs("^/API/(.+)$", "/api/users", "/x/$1", true));
		Assert.equals("/x/posts", RewriteEngine.backrefs("^/API/(.+)$", "/api/posts", "/x/$1", true));
		Assert.equals("/x/users", RewriteEngine.backrefs("^/API/(.+)$", "/api/users", "/x/$1", true));
	}

	public function testTryFilesFallsBackToLiteralEntries():Void {
		var root = File.createTempDirectory();
		try {
			root.resolvePath("app.html").save(ByteArray.fromBytes(Bytes.ofString("app")));

			var cfg = new HTTPServerConfig("127.0.0.1", 8080, root, null, ["index.html"], null, null, null, null, null, false, null, null, null, 600,
				false, 256, 0, false, "127.0.0.1", 8080, "php-cgi", "php.ini", 1, ["$uri", "$uri/", "/app.html"], []);

			// Neither the path nor a directory index resolves, so the literal
			// entry is what serves the request. The "$uri" entries ahead of it
			// are inert: decide() tests both before the loop is reached.
			var decision = RewriteEngine.decide(cfg, "/deep/link", "", "GET", new StringMap<String>());
			Assert.notNull(decision);
			Assert.equals("/app.html", decision.finalPath);
			Assert.isTrue(decision.isStatic);

			// A real file still wins over the literal fallback.
			var direct = RewriteEngine.decide(cfg, "/app.html", "", "GET", new StringMap<String>());
			Assert.notNull(direct);
			Assert.equals("/app.html", direct.finalPath);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}
}
