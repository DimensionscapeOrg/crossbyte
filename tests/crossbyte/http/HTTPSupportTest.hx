package crossbyte.http;

import crossbyte.net.RateLimiter;
import crossbyte._internal.http.HttpSyntax;
import crossbyte._internal.http.RewriteEngine;
import crossbyte.http.config.RewriteConditionType;
import crossbyte.http.config.RewriteFlag;
import crossbyte.io.ByteArray;
import crossbyte.io.File;
import crossbyte.url.URLRequestHeader;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

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
		// Two, not three. The third used to be "/index.html", which made a
		// path matching neither of the first two answer 200 with the root
		// index instead of 404 -- an SPA fallback every server carried
		// whether or not it served an application.
		Assert.equals(2, first.tryFiles.length);
		Assert.equals("$uri", first.tryFiles[0]);
		Assert.equals("$uri/", first.tryFiles[1]);
		// No rewrites by default. The defaults used to carry one sending every
		// /api path to /index.php with the PHP flag while phpEnabled defaults
		// to false, so a stock server crashed on a path many services use.
		Assert.equals(0, first.rewrites.length);
		// No root by default, and so no static files. The default was the
		// account's home directory, served on every interface.
		Assert.isNull(first.rootDirectory);
		Assert.equals("127.0.0.1", first.address);
		// Keep-alive defaults on: it is what HTTP/1.1 specifies and what
		// removes the per-request handshake without client changes.
		Assert.isTrue(first.keepAlive);
		Assert.equals(5.0, first.keepAliveTimeout);
		// A thousand responses a connection, as nginx: at a hundred, HTTPS
		// spent two thirds of its time on the handshakes of reconnecting.
		Assert.equals(1000, first.keepAliveMaxRequests);
		// Ten thousand connections: 256 refused the 257th, which a few dozen
		// browser users reach at six connections each.
		Assert.equals(10000, first.maxConnections);

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
		// first got an entry pushed onto it just above; second keeps the
		// default two, which is the independence being checked.
		Assert.equals(3, first.tryFiles.length);
		Assert.equals(2, second.tryFiles.length);
		// The point of the pair: pushing onto one config's array must not be
		// visible through another's.
		Assert.equals(1, first.rewrites.length);
		Assert.equals(0, second.rewrites.length);
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
			Require.notNull(staticDecision);
			Assert.equals("/asset.txt", staticDecision.finalPath);
			Assert.isTrue(staticDecision.isStatic);
			Assert.isFalse(staticDecision.toPHP);

			var dirDecision = RewriteEngine.decide(cfg, "/", "", "GET", new StringMap<String>());
			Require.notNull(dirDecision);
			Assert.equals("/index.html", dirDecision.finalPath);
			Assert.isTrue(dirDecision.isStatic);

			var passThrough = RewriteEngine.decide(cfg, "/blog", "", "GET", new StringMap<String>());
			Require.notNull(passThrough);
			Assert.equals("/about.html", passThrough.finalPath);
			Assert.isTrue(passThrough.isStatic);
			Assert.isFalse(passThrough.toPHP);

			var headers = new StringMap<String>();
			var phpDecision = RewriteEngine.decide(cfg, "/API/users", "page=2", "GET", headers);
			Require.notNull(phpDecision);
			Assert.equals("/index.php", phpDecision.finalPath);
			Assert.isTrue(phpDecision.toPHP);
			Assert.equals("page=2&path=users", phpDecision.query);
			Assert.isTrue(phpDecision.preserveURI);

			var blockedByMethod = RewriteEngine.decide(cfg, "/api/users", "page=2", "POST", headers);
			Require.notNull(blockedByMethod);
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

		// Climbing above the root is refused by answering null: it used to
		// throw "403", which reached the client as a 500.
		Assert.isNull(RewriteEngine.normalize("/../../secret"));
		Assert.isNull(RewriteEngine.normalize("/a/../../secret"));
		// A ".." inside a name is not a step, and used to be refused too.
		Assert.equals("/compare/v1.2..v1.3", RewriteEngine.normalize("/compare/v1.2..v1.3"));
		Assert.equals("/secret", RewriteEngine.normalize("/a/../secret"));
	}

	public function testPathNormalizationSettlesEverySpelling():Void {
		for (spelling in ["/private/report.txt", "//private/report.txt", "/./private/report.txt", "/private//report.txt", "/x/../private/report.txt",
			"/private/./report.txt", "\\private\\report.txt", "private/report.txt"]) {
			Assert.equals("/private/report.txt", HttpSyntax.normalizePath(spelling), spelling);
		}

		Assert.equals("/", HttpSyntax.normalizePath(""));
		Assert.equals("/", HttpSyntax.normalizePath("/"));
		Assert.equals("/", HttpSyntax.normalizePath("//"));
		Assert.equals("/", HttpSyntax.normalizePath("/a/.."));
		Assert.equals("/a/", HttpSyntax.normalizePath("/a/"));
		Assert.equals("/a/", HttpSyntax.normalizePath("/a/."));
		Assert.equals("/a/", HttpSyntax.normalizePath("/a//"));
		Assert.equals("/a/", HttpSyntax.normalizePath("/a/b/.."));
		Assert.equals("/...", HttpSyntax.normalizePath("/..."));
		Assert.equals("/.env", HttpSyntax.normalizePath("/.env"));
		Assert.equals("*", HttpSyntax.normalizePath("*"));
		Assert.isNull(HttpSyntax.normalizePath("/.."));
		Assert.isNull(HttpSyntax.normalizePath("/../a"));
		Assert.isNull(HttpSyntax.normalizePath("\\..\\a"));

		// A settled path comes back as the very same string: the common case
		// allocates nothing.
		var clean:String = "/api/users/42";
		Assert.isTrue(HttpSyntax.normalizePath(clean) == clean);
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

			// Lowercase, as both parsers store a request's fields. This case
			// stored "User-Agent" as written, which no request ever has, and so
			// passed while the condition matched nothing a client sent.
			var headers = new StringMap<String>();
			headers.set("user-agent", "Mobile Safari");
			var allowed = RewriteEngine.decide(cfg, "/content/mobile", "", "GET", headers);
			Require.notNull(allowed);
			Assert.equals("/mobile.html", allowed.finalPath);

			headers.set("user-agent", "Desktop");
			var fallback = RewriteEngine.decide(cfg, "/content/mobile", "", "GET", headers);
			Assert.isNull(fallback);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testAHeaderConditionMatchesWhateverCaseItsKeyIsWrittenIn():Void {
		// A field's name has no case (RFC 9110 5.1), and both parsers store a
		// request's fields lowercase. The condition looked its key up as
		// written, so "X-Test" -- how a header is written, and how the doc's
		// example would be -- matched nothing a client could send.
		var root = File.createTempDirectory();
		try {
			root.resolvePath("a.txt").save(ByteArray.fromBytes(Bytes.ofString("A")));
			var cfg = new HTTPServerConfig("127.0.0.1", 0, root);
			cfg.rewrites = [{
				pattern: "^/x$",
				target: "/a.txt",
				conditions: [{type: RewriteConditionType.Header, key: "X-Test", pattern: "^yes$", negate: false}]
			}];

			var headers = new StringMap<String>();
			headers.set("x-test", "yes");
			var matched = RewriteEngine.decide(cfg, "/x", "", "GET", headers);
			Require.notNull(matched, "a Header condition keyed X-Test did not see x-test");
			Assert.equals("/a.txt", matched.finalPath);

			headers.set("x-test", "no");
			Assert.isNull(RewriteEngine.decide(cfg, "/x", "", "GET", headers));
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testARuleThatAsksAboutFilesCanWinOverAnExistingFile():Void {
		// tryFiles' doc said a rule given a FileExists condition runs before
		// the file is looked for, which is how a rewrite wins over a file that
		// exists. Every rule ran only once the request had been found to name
		// no file at all, so none could.
		var root = File.createTempDirectory();
		try {
			root.resolvePath("a.txt").save(ByteArray.fromBytes(Bytes.ofString("A")));
			root.resolvePath("b.txt").save(ByteArray.fromBytes(Bytes.ofString("B")));
			var cfg = new HTTPServerConfig("127.0.0.1", 0, root);
			var none = new StringMap<String>();

			// Asks, and the file exists: the rewrite wins.
			cfg.rewrites = [{pattern: "^/a\\.txt$", target: "/b.txt", conditions: [{type: RewriteConditionType.FileExists, key: null, pattern: null, negate: false}]}];
			var overridden = RewriteEngine.decide(cfg, "/a.txt", "", "GET", none);
			Require.notNull(overridden);
			Assert.equals("/b.txt", overridden.finalPath, "a rule asking for an existing file did not win over it");

			// Asks for the file not to exist: it does, so the file is served.
			cfg.rewrites[0].conditions[0].negate = true;
			Assert.equals("/a.txt", RewriteEngine.decide(cfg, "/a.txt", "", "GET", none).finalPath);

			// Does not ask: an existing file wins, as it always has.
			cfg.rewrites[0].conditions = null;
			Assert.equals("/a.txt", RewriteEngine.decide(cfg, "/a.txt", "", "GET", none).finalPath);

			// And a rule for a path that is not a file runs as it always has.
			cfg.rewrites = [{pattern: "^/gone$", target: "/b.txt"}];
			Assert.equals("/b.txt", RewriteEngine.decide(cfg, "/gone", "", "GET", none).finalPath);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}

	public function testATryFilesEntryCanNameTheRequestPath():Void {
		// "$uri.html" -- the request path with .html added, as clean URLs are
		// served -- was looked for as a file named "$uri.html". The entries
		// after the first two name files, and $uri in them is the path.
		var root = File.createTempDirectory();
		try {
			root.resolvePath("about.html").save(ByteArray.fromBytes(Bytes.ofString("about")));
			var cfg = new HTTPServerConfig("127.0.0.1", 0, root);
			cfg.tryFiles = ["$uri", "$uri/", "$uri.html"];
			cfg.validate();

			var decision = RewriteEngine.decide(cfg, "/about", "", "GET", new StringMap<String>());
			Require.notNull(decision, "$uri.html was not tried as the request path");
			Assert.equals("/about.html", decision.finalPath);
			Assert.isNull(RewriteEngine.decide(cfg, "/missing", "", "GET", new StringMap<String>()));
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

	#if target.threaded
	/**
		A thread's compiled patterns and directory listings are its own, on
		every target with threads. They were held per thread on cpp, neko, hl
		and the jvm, and shared on eval, which has threads too: runtimes on two
		threads used one map, and one `EReg`, which carries its last match, so
		one could read the other's captures.
	**/
	public function testTheCachesAreHeldPerThread():Void {
		var listings = crossbyte._internal.http.DirectoryListings.current();
		var pattern:EReg = @:privateAccess RewriteEngine.__compile("^/per-thread/(.+)$", false);
		var theirListings:Dynamic = null;
		var theirPattern:Dynamic = null;
		var done = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			theirListings = crossbyte._internal.http.DirectoryListings.current();
			theirPattern = @:privateAccess RewriteEngine.__compile("^/per-thread/(.+)$", false);
			done.release();
		});
		Assert.isTrue(done.wait(10.0), "the other thread never finished");
		Assert.isTrue(listings == crossbyte._internal.http.DirectoryListings.current(), "a thread's listings were not kept for it");
		Assert.isTrue(pattern == @:privateAccess RewriteEngine.__compile("^/per-thread/(.+)$", false), "a thread's pattern was not kept for it");
		Assert.isFalse(theirListings == listings, "two threads shared one set of directory listings");
		Assert.isFalse(theirPattern == pattern, "two threads shared one compiled pattern");
	}
	#end

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
			Require.notNull(decision);
			Assert.equals("/app.html", decision.finalPath);
			Assert.isTrue(decision.isStatic);

			// A real file still wins over the literal fallback.
			var direct = RewriteEngine.decide(cfg, "/app.html", "", "GET", new StringMap<String>());
			Require.notNull(direct);
			Assert.equals("/app.html", direct.finalPath);
		} catch (e:Dynamic) {
			Assert.fail(Std.string(e));
		}

		try root.deleteDirectory(true) catch (_:Dynamic) {}
	}
}
